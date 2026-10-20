package httpapi

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"time"

	"github.com/mhdolatabadi/rhythmo/server/internal/bot"
	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

// shareTokenBytes of randomness make a link nobody can guess.
const shareTokenBytes = 16

// SharedPlaylistStore is what sharing needs from playlists.
type SharedPlaylistStore interface {
	Share(ctx context.Context, ownerID, playlistID, token string, public *bool, direct bool) (store.Playlist, error)
	Unshare(ctx context.Context, ownerID, playlistID string) error
	ForShareToken(ctx context.Context, token string) (store.SharedPlaylist, error)
	SharedTrack(ctx context.Context, token, trackID string, publicOnly bool) (store.Track, error)
	SaveShared(ctx context.Context, userID, token string, maxOwnerBytes int64, objects store.ObjectCopier) (store.Playlist, error)
	LikesFor(ctx context.Context, playlistID, userID string) (store.Likes, error)
	SetLike(ctx context.Context, userID, token string, liked bool) (store.Likes, error)
	Popular(ctx context.Context, userID string, limit int) ([]store.PublicPlaylist, error)
}

const (
	defaultPublicPlaylists = 50
	maxPublicPlaylists     = 100
)

// SavePolicy is what saving a shared playlist into an account must respect:
// the same quota and uploads switch as uploading the tracks would.
type SavePolicy struct {
	Objects       store.ObjectCopier
	MaxOwnerBytes int64
	Enabled       bool
}

// AnonymousLimits caps what one IP address may do without an account:
// browsing public playlists and streaming their tracks.
type AnonymousLimits struct {
	View   *RateLimiter
	Stream *RateLimiter
}

// WithAnonymous lets visitors without an account browse and play public
// playlists, within limits. Link-only and private playlists still need an
// account.
func (h *PlaylistHandlers) WithAnonymous(limits AnonymousLimits) *PlaylistHandlers {
	h.anonymous = &limits
	return h
}

// viewer is the signed-in user, or "" for an allowed anonymous visitor
// within the given limit. It writes the error itself when it says no.
func (h *PlaylistHandlers) viewer(w http.ResponseWriter, r *http.Request, limit func(AnonymousLimits) *RateLimiter) (string, bool) {
	if h.anonymous == nil {
		return authenticate(h.tokens, w, r)
	}
	userID, ok := optionalUser(h.tokens, w, r)
	if !ok || userID != "" {
		return userID, ok
	}
	return "", enforceRateLimit(w, limit(*h.anonymous), clientIP(r))
}

// StreamPresigner hands out short-lived playback URLs.
type StreamPresigner interface {
	PresignGet(ctx context.Context, key string) (string, time.Time, error)
}

// WithSharing serves playlist sharing: owners turn a playlist's link on and
// off, and anyone signed in who has the link can view it and play its tracks.
func (h *PlaylistHandlers) WithSharing(shared SharedPlaylistStore, streams StreamPresigner, save SavePolicy) *PlaylistHandlers {
	h.shared, h.streams, h.save = shared, streams, save
	return h
}

func (h *PlaylistHandlers) registerSharing(mux *http.ServeMux) {
	mux.HandleFunc("POST /api/v1/playlists/{id}/share", h.handleShare)
	mux.HandleFunc("DELETE /api/v1/playlists/{id}/share", h.handleUnshare)
	mux.HandleFunc("GET /api/v1/shared-playlists/{token}", h.handleShared)
	mux.HandleFunc("GET /api/v1/shared-playlists/{token}/tracks/{trackId}/stream", h.handleSharedStream)
	mux.HandleFunc("POST /api/v1/shared-playlists/{token}/save", h.handleSaveShared)
	mux.HandleFunc("PUT /api/v1/shared-playlists/{token}/like", h.handleLike(true))
	mux.HandleFunc("DELETE /api/v1/shared-playlists/{token}/like", h.handleLike(false))
	mux.HandleFunc("GET /api/v1/public-playlists", h.handlePublic)
}

// handleSaveShared copies a shared playlist and its tracks into the caller's
// account, so they keep it whatever the owner does later.
func (h *PlaylistHandlers) handleSaveShared(w http.ResponseWriter, r *http.Request) {
	userID, ok := authenticate(h.tokens, w, r)
	if !ok {
		return
	}
	token := r.PathValue("token")
	if !validShareToken(token) {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	if !h.save.Enabled || h.save.Objects == nil {
		writeError(w, http.StatusServiceUnavailable, "uploads_disabled")
		return
	}
	if !h.emailGate.allow(w, r, userID) {
		return
	}
	saved, err := h.shared.SaveShared(r.Context(), userID, token, h.save.MaxOwnerBytes, h.save.Objects)
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeError(w, http.StatusNotFound, "not_found")
	case errors.Is(err, store.ErrOwnPlaylist):
		writeError(w, http.StatusConflict, "own_playlist")
	case errors.Is(err, store.ErrQuotaExceeded):
		writeError(w, http.StatusRequestEntityTooLarge, "quota_exceeded")
	case err != nil:
		internalError(w, "save shared playlist", err)
	default:
		writeJSON(w, http.StatusCreated, toPlaylistResponse(saved, userID, true))
	}
}

type shareRequest struct {
	// Public lists the playlist for everyone; absent keeps what it was.
	Public *bool `json:"public"`
}

type shareResponse struct {
	ShareToken string `json:"shareToken"`
	Public     bool   `json:"public"`
	// PublicReview is "pending" when listing it waits for an admin (#322).
	PublicReview *string `json:"publicReview,omitempty"`
}

func (h *PlaylistHandlers) handleShare(w http.ResponseWriter, r *http.Request) {
	userID, ok := authenticate(h.tokens, w, r)
	if !ok {
		return
	}
	var request shareRequest
	if r.ContentLength != 0 {
		r.Body = http.MaxBytesReader(w, r.Body, maxPlaylistBodyBytes)
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil && !errors.Is(err, io.EOF) {
			writeError(w, http.StatusBadRequest, "invalid_json")
			return
		}
	}
	// Link-only sharing stays open; listing for everyone needs a verified
	// email.
	if request.Public != nil && *request.Public && !h.emailGate.allow(w, r, userID) {
		return
	}
	// Owners who are not verified only ask to be listed (#322).
	direct := true
	if request.Public != nil && *request.Public {
		if direct, ok = h.publishGate.direct(w, r, userID); !ok {
			return
		}
	}
	for range 3 {
		token, err := newShareToken()
		if err != nil {
			internalError(w, "draw share token", err)
			return
		}
		playlist, err := h.shared.Share(r.Context(), userID, r.PathValue("id"), token, request.Public, direct)
		switch {
		case errors.Is(err, store.ErrShareTokenTaken):
			continue
		case errors.Is(err, store.ErrNotFound):
			writeError(w, http.StatusNotFound, "not_found")
		case err != nil:
			internalError(w, "share playlist", err)
		default:
			writeJSON(w, http.StatusOK, shareResponse{
				ShareToken: *playlist.ShareToken, Public: playlist.IsPublic, PublicReview: playlist.PublicReview,
			})
		}
		return
	}
	internalError(w, "share playlist", errors.New("could not draw an unused share token"))
}

func (h *PlaylistHandlers) handleUnshare(w http.ResponseWriter, r *http.Request) {
	userID, ok := authenticate(h.tokens, w, r)
	if !ok {
		return
	}
	err := h.shared.Unshare(r.Context(), userID, r.PathValue("id"))
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeError(w, http.StatusNotFound, "not_found")
	case err != nil:
		internalError(w, "unshare playlist", err)
	default:
		w.WriteHeader(http.StatusNoContent)
	}
}

type sharedPlaylistResponse struct {
	Name       string          `json:"name"`
	Owner      string          `json:"owner"`
	IsOwner    bool            `json:"isOwner"`
	Public     bool            `json:"public"`
	TrackCount int             `json:"trackCount"`
	LikeCount  int             `json:"likeCount"`
	Liked      bool            `json:"liked"`
	Tracks     []trackResponse `json:"tracks"`
	UpdatedAt  time.Time       `json:"updatedAt"`
}

// sharedPlaylist loads the playlist for the {token} link. Malformed,
// unknown and unshared links are all the same 404.
func (h *PlaylistHandlers) sharedPlaylist(w http.ResponseWriter, r *http.Request) (store.SharedPlaylist, bool) {
	token := r.PathValue("token")
	if !validShareToken(token) {
		writeError(w, http.StatusNotFound, "not_found")
		return store.SharedPlaylist{}, false
	}
	shared, err := h.shared.ForShareToken(r.Context(), token)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "not_found")
		return store.SharedPlaylist{}, false
	}
	if err != nil {
		internalError(w, "load shared playlist", err)
		return store.SharedPlaylist{}, false
	}
	return shared, true
}

func (h *PlaylistHandlers) handleShared(w http.ResponseWriter, r *http.Request) {
	userID, ok := h.viewer(w, r, func(l AnonymousLimits) *RateLimiter { return l.View })
	if !ok {
		return
	}
	shared, ok := h.sharedPlaylist(w, r)
	if !ok {
		return
	}
	if userID == "" && !shared.IsPublic {
		// Only public playlists are open to visitors without an account.
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	likes, err := h.shared.LikesFor(r.Context(), shared.ID, userID)
	if err != nil {
		internalError(w, "load playlist likes", err)
		return
	}
	response := sharedPlaylistResponse{
		Name: shared.Name, Owner: bot.MaskEmail(shared.OwnerEmail), IsOwner: shared.OwnerID == userID,
		Public: shared.IsPublic, TrackCount: len(shared.Tracks), LikeCount: likes.Count, Liked: likes.Liked,
		Tracks: make([]trackResponse, 0, len(shared.Tracks)), UpdatedAt: shared.UpdatedAt.UTC(),
	}
	for _, track := range shared.Tracks {
		response.Tracks = append(response.Tracks, toTrackResponse(track))
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, response)
}

func (h *PlaylistHandlers) handleSharedStream(w http.ResponseWriter, r *http.Request) {
	userID, ok := h.viewer(w, r, func(l AnonymousLimits) *RateLimiter { return l.Stream })
	if !ok {
		return
	}
	token := r.PathValue("token")
	if !validShareToken(token) {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	track, err := h.shared.SharedTrack(r.Context(), token, r.PathValue("trackId"), userID == "")
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	if err != nil {
		internalError(w, "load shared track", err)
		return
	}
	url, expiresAt, err := h.streams.PresignGet(r.Context(), track.StorageKey)
	if err != nil {
		internalError(w, "presign shared track", err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, streamResponse{URL: url, ExpiresAt: expiresAt.UTC()})
}

type likeResponse struct {
	Liked     bool `json:"liked"`
	LikeCount int  `json:"likeCount"`
}

// handleLike likes (PUT) or unlikes (DELETE) the playlist shared at
// {token}. Both are idempotent, so a retried request changes nothing.
func (h *PlaylistHandlers) handleLike(liked bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		userID, ok := authenticate(h.tokens, w, r)
		if !ok {
			return
		}
		token := r.PathValue("token")
		if !validShareToken(token) {
			writeError(w, http.StatusNotFound, "not_found")
			return
		}
		likes, err := h.shared.SetLike(r.Context(), userID, token, liked)
		switch {
		case errors.Is(err, store.ErrNotFound):
			writeError(w, http.StatusNotFound, "not_found")
		case err != nil:
			internalError(w, "like playlist", err)
		default:
			writeJSON(w, http.StatusOK, likeResponse{Liked: likes.Liked, LikeCount: likes.Count})
		}
	}
}

type publicPlaylistResponse struct {
	ShareToken string    `json:"shareToken"`
	Name       string    `json:"name"`
	Owner      string    `json:"owner"`
	IsOwner    bool      `json:"isOwner"`
	TrackCount int       `json:"trackCount"`
	LikeCount  int       `json:"likeCount"`
	Liked      bool      `json:"liked"`
	UpdatedAt  time.Time `json:"updatedAt"`
}

// handlePublic lists public playlists, most liked first. ?limit= caps how
// many (default 50, at most 100).
func (h *PlaylistHandlers) handlePublic(w http.ResponseWriter, r *http.Request) {
	userID, ok := h.viewer(w, r, func(l AnonymousLimits) *RateLimiter { return l.View })
	if !ok {
		return
	}
	limit := defaultPublicPlaylists
	if raw := r.URL.Query().Get("limit"); raw != "" {
		n, err := strconv.Atoi(raw)
		if err != nil || n < 1 {
			writeError(w, http.StatusBadRequest, "invalid_limit")
			return
		}
		limit = min(n, maxPublicPlaylists)
	}
	listed, err := h.shared.Popular(r.Context(), userID, limit)
	if err != nil {
		internalError(w, "list public playlists", err)
		return
	}
	response := make([]publicPlaylistResponse, 0, len(listed))
	for _, p := range listed {
		response = append(response, publicPlaylistResponse{
			ShareToken: p.ShareToken, Name: p.Name, Owner: bot.MaskEmail(p.OwnerEmail),
			IsOwner: p.OwnerID == userID, TrackCount: p.TrackCount,
			LikeCount: p.Likes.Count, Liked: p.Likes.Liked, UpdatedAt: p.UpdatedAt.UTC(),
		})
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]any{"playlists": response})
}

func newShareToken() (string, error) {
	b := make([]byte, shareTokenBytes)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

func validShareToken(token string) bool {
	b, err := base64.RawURLEncoding.DecodeString(token)
	return err == nil && len(b) == shareTokenBytes
}
