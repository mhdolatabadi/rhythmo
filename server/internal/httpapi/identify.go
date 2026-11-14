package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/mhdolatabadi/rhythmo/server/internal/auth"
	"github.com/mhdolatabadi/rhythmo/server/internal/fingerprint"
	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

const (
	// maxSnippetBytes fits 12 s of uncompressed 48 kHz stereo audio.
	maxSnippetBytes = 3 << 20
	// minSnippet is the least audio worth matching.
	minSnippet = 4 * time.Second
	// maxSnippet is how much of a snippet is fingerprinted.
	maxSnippet   = 15 * time.Second
	maxSaveBytes = 1 << 10
)

// SnippetFingerprinter fingerprints a recorded file; fingerprint.Calculator
// implements it.
type SnippetFingerprinter interface {
	File(ctx context.Context, path string) (fingerprint.Fingerprint, error)
}

// PlaylistTrackFinder finds a track someone may play through a playlist;
// *store.Playlists implements it.
type PlaylistTrackFinder interface {
	PlaylistTrack(ctx context.Context, userID, playlistID, trackID string) (store.Track, error)
	SharedTrack(ctx context.Context, token, trackID string, publicOnly bool) (store.Track, error)
}

// TrackCopier copies someone else's track into a user's library;
// *store.Fingerprints implements it.
type TrackCopier interface {
	SaveTrackCopy(ctx context.Context, userID string, original store.Track, maxOwnerBytes int64, objects store.ObjectCopier) (store.Track, error)
}

// IdentifyConfig is what song identification needs.
type IdentifyConfig struct {
	Fingerprinter SnippetFingerprinter
	Matches       fingerprint.MatchStore
	Playlists     PlaylistTrackFinder
	Copier        TrackCopier
	// Save is the quota and uploads switch a copied track must respect.
	Save SavePolicy
	// TempDir holds a snippet while fpcalc reads it.
	TempDir string
	Rate    *RateLimiter
	// Store, when set, lets visitors without an account match snippets
	// against the public store, within AnonymousRate per IP.
	Store         fingerprint.MatchStore
	AnonymousRate *RateLimiter
	// Concurrent caps how many snippets are fingerprinted at once.
	Concurrent int
}

// IdentifyHandlers serve «این آهنگ چیه؟»: a recorded snippet is matched
// against the tracks the listener may play, and a match from someone
// else's playlist can be added to their library. Without an account, a
// snippet is matched against the public store only.
type IdentifyHandlers struct {
	config IdentifyConfig
	tokens *auth.Tokens
	slots  chan struct{}
}

func NewIdentifyHandlers(config IdentifyConfig, tokens *auth.Tokens) *IdentifyHandlers {
	if config.Concurrent <= 0 {
		config.Concurrent = 2
	}
	return &IdentifyHandlers{config: config, tokens: tokens, slots: make(chan struct{}, config.Concurrent)}
}

func (h *IdentifyHandlers) register(mux *http.ServeMux) {
	mux.HandleFunc("POST /api/v1/identify", h.handleIdentify)
	mux.HandleFunc("POST /api/v1/identify/save", h.handleSave)
}

type identifyResponse struct {
	// Status is found or not_found.
	Status     string  `json:"status"`
	Confidence float64 `json:"confidence,omitempty"`
	// OffsetMS is where in the track the snippet was heard.
	OffsetMS int64                  `json:"offsetMs,omitempty"`
	Track    *playlistTrackResponse `json:"track,omitempty"`
	// Source is library, playlist (a collaborative playlist the listener
	// belongs to, PlaylistID), public (a public playlist, ShareToken) or,
	// for listeners without an account, store (StoreTrack).
	Source     string  `json:"source,omitempty"`
	PlaylistID *string `json:"playlistId,omitempty"`
	ShareToken *string `json:"shareToken,omitempty"`
	// StoreTrack is the matched store song; it never says whose copy it is.
	StoreTrack *storeTrackResponse `json:"storeTrack,omitempty"`
}

type saveIdentifiedRequest struct {
	TrackID    string  `json:"trackId"`
	PlaylistID *string `json:"playlistId"`
	ShareToken *string `json:"shareToken"`
}

// handleIdentify matches the recorded audio in the request body. The
// snippet lives only in a private temporary file while fpcalc reads it,
// is deleted right after, and is never stored or logged.
func (h *IdentifyHandlers) handleIdentify(w http.ResponseWriter, r *http.Request) {
	userID, ok := h.listener(w, r)
	if !ok {
		return
	}
	mediaType, _, _ := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if !strings.HasPrefix(mediaType, "audio/") && mediaType != "application/octet-stream" {
		writeError(w, http.StatusUnsupportedMediaType, "unsupported_format")
		return
	}
	select {
	case h.slots <- struct{}{}:
		defer func() { <-h.slots }()
	default:
		w.Header().Set("Retry-After", "5")
		writeError(w, http.StatusServiceUnavailable, "identify_busy")
		return
	}
	snippet, status, code := h.fingerprintBody(w, r)
	if code != "" {
		writeError(w, status, code)
		return
	}
	matches := h.config.Matches
	if userID == "" {
		matches = h.config.Store
	}
	result, found, err := fingerprint.Identify(r.Context(), matches, userID, snippet.Points)
	if err != nil {
		internalError(w, "identify song", err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	if !found {
		writeJSON(w, http.StatusOK, identifyResponse{Status: "not_found"})
		return
	}
	match := result.Match
	if userID == "" {
		storeTrack := toStoreTrackResponse(store.StoreEntry{ID: *match.Source.StoreEntryID, Track: match.Track})
		writeJSON(w, http.StatusOK, identifyResponse{
			Status: "found", Confidence: result.Score.Confidence,
			OffsetMS: max(0, result.Score.Offset.Milliseconds()), Source: "store", StoreTrack: &storeTrack,
		})
		return
	}
	track := playlistTrackResponse{trackResponse: toTrackResponse(match.Track)}
	response := identifyResponse{
		Status: "found", Confidence: result.Score.Confidence,
		OffsetMS: max(0, result.Score.Offset.Milliseconds()), Track: &track, Source: "library",
	}
	if match.Track.OwnerID != userID {
		// Only the owner's public name, as shared playlists show it.
		addedBy := publicOwnerName(match.OwnerName)
		track.AddedBy = &addedBy
		response.PlaylistID, response.ShareToken = match.Source.PlaylistID, match.Source.ShareToken
		response.Source = "public"
		if match.Source.PlaylistID != nil {
			response.Source = "playlist"
		}
	}
	writeJSON(w, http.StatusOK, response)
}

// listener is the signed-in user within their identify limit, or "" for a
// visitor without an account within the per-IP limit when store matching
// is on. It writes the error itself when it says no.
func (h *IdentifyHandlers) listener(w http.ResponseWriter, r *http.Request) (string, bool) {
	if h.config.Store == nil || h.config.AnonymousRate == nil || r.Header.Get("Authorization") != "" {
		userID, ok := authenticate(h.tokens, w, r)
		return userID, ok && enforceRateLimit(w, h.config.Rate, userID)
	}
	return "", enforceRateLimit(w, h.config.AnonymousRate, clientIP(r))
}

// fingerprintBody copies the request body to a temporary file only this
// process can read, fingerprints it, and deletes it before returning.
func (h *IdentifyHandlers) fingerprintBody(w http.ResponseWriter, r *http.Request) (fingerprint.Fingerprint, int, string) {
	file, err := os.CreateTemp(h.config.TempDir, "rhythmo-snippet-*")
	if err != nil {
		internalError(w, "create snippet file", err)
		return fingerprint.Fingerprint{}, 0, ""
	}
	defer os.Remove(file.Name())
	written, err := io.Copy(file, http.MaxBytesReader(w, r.Body, maxSnippetBytes))
	closeErr := file.Close()
	var tooLarge *http.MaxBytesError
	switch {
	case errors.As(err, &tooLarge):
		return fingerprint.Fingerprint{}, http.StatusRequestEntityTooLarge, "snippet_too_large"
	case err != nil:
		return fingerprint.Fingerprint{}, http.StatusBadRequest, "invalid_snippet"
	case closeErr != nil:
		return fingerprint.Fingerprint{}, http.StatusInternalServerError, "internal_error"
	case written == 0:
		return fingerprint.Fingerprint{}, http.StatusBadRequest, "invalid_snippet"
	}
	snippet, err := h.config.Fingerprinter.File(r.Context(), file.Name())
	switch {
	case errors.Is(err, fingerprint.ErrNoAudio):
		return snippet, http.StatusUnprocessableEntity, "invalid_snippet"
	case err != nil:
		w.Header().Set("Retry-After", "30")
		return snippet, http.StatusServiceUnavailable, "identify_unavailable"
	case snippet.Duration < minSnippet || len(snippet.Points) == 0:
		return snippet, http.StatusUnprocessableEntity, "snippet_too_short"
	}
	return snippet, 0, ""
}

// handleSave copies a matched track from someone else's playlist into the
// caller's library, after checking they may still play it there.
func (h *IdentifyHandlers) handleSave(w http.ResponseWriter, r *http.Request) {
	userID, ok := authenticate(h.tokens, w, r)
	if !ok {
		return
	}
	var input saveIdentifiedRequest
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxSaveBytes))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil || input.TrackID == "" ||
		(input.PlaylistID == nil) == (input.ShareToken == nil) {
		writeError(w, http.StatusBadRequest, "invalid_json")
		return
	}
	if !h.config.Save.Enabled {
		writeError(w, http.StatusServiceUnavailable, "uploads_disabled")
		return
	}
	var original store.Track
	var err error
	if input.PlaylistID != nil {
		original, err = h.config.Playlists.PlaylistTrack(r.Context(), userID, *input.PlaylistID, input.TrackID)
	} else if validShareToken(*input.ShareToken) {
		original, err = h.config.Playlists.SharedTrack(r.Context(), *input.ShareToken, input.TrackID, false)
	} else {
		err = store.ErrNotFound
	}
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	if err != nil {
		internalError(w, "load track to save", err)
		return
	}
	copied, err := h.config.Copier.SaveTrackCopy(r.Context(), userID, original, h.config.Save.MaxOwnerBytes, h.config.Save.Objects)
	switch {
	case errors.Is(err, store.ErrOwnPlaylist):
		writeError(w, http.StatusConflict, "already_yours")
	case errors.Is(err, store.ErrQuotaExceeded):
		writeError(w, http.StatusRequestEntityTooLarge, "quota_exceeded")
	case err != nil:
		internalError(w, "save identified track", err)
	default:
		writeJSON(w, http.StatusCreated, toTrackResponse(copied))
	}
}
