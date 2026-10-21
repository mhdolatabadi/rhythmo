package httpapi

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/mhdolatabadi/rhythmo/server/internal/auth"
	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

// CatalogStore is the public store's catalog; *store.Catalog implements it.
type CatalogStore interface {
	StoreArtistCounts(ctx context.Context, artist string) (tracks, albums int, err error)
	StoreEntries(ctx context.Context, query store.StoreQuery) ([]store.StoreEntry, bool, error)
	StoreEntryByID(ctx context.Context, entryID string, includeHidden bool) (store.StoreEntry, error)
	StoreArtists(ctx context.Context, search string, limit, offset int) ([]store.StoreArtist, bool, error)
	StoreAlbums(ctx context.Context, search, artist string, limit, offset int) ([]store.StoreAlbum, bool, error)
	OwnsCopy(ctx context.Context, entryID, userID string) (bool, error)
	ReportEntry(ctx context.Context, entryID, reporterID, reason string, details *string) error
	OpenReports(ctx context.Context, limit int) ([]store.StoreReport, error)
	SetHidden(ctx context.Context, entryID, adminID string, hidden bool) error
	RecordStorePlay(ctx context.Context, entryID, listener string) error
	StoreRanked(ctx context.Context, ranking store.StoreRanking, limit, offset int) ([]store.StoreEntry, bool, error)
	StoreEntriesForTracks(ctx context.Context, trackIDs []string) (map[string]store.StoreEntry, error)
}

const (
	defaultStorePage = 50
	maxStorePage     = 100
	maxStoreOffset   = 10_000
	maxStoreSearch   = 100
	maxReportBytes   = 4 << 10
	maxReportDetails = 1000
)

// reportReasons are the kinds of «گزارش تخلف» the app offers.
var reportReasons = map[string]bool{"copyright": true, "offensive": true, "wrong_info": true, "other": true}

// CatalogHandlers serve the public store (#243): every song in a public
// playlist, listed once, browsable and playable without an account within
// the anonymous limits. Owners are never shown; entries are addressed by
// their own ID, never a track's.
type CatalogHandlers struct {
	catalog   CatalogStore
	tokens    *auth.Tokens
	streams   StreamPresigner
	anonymous AnonymousLimits
	save      SavePolicy
	copier    TrackCopier
	// reports caps how often one account may report.
	reports *RateLimiter
	admin   *AdminHandlers
	// likes, when set, adds like counts and the viewer's likes.
	likes LikeStore
	// playSalt keys the visitor hashes listenerKey counts plays by.
	playSalt []byte
}

// WithLikes adds each song's like count and whether the viewer likes it.
func (h *CatalogHandlers) WithLikes(likes LikeStore) *CatalogHandlers {
	h.likes = likes
	return h
}

// withLikes fills in the like state of responses for viewerID.
func (h *CatalogHandlers) withLikes(ctx context.Context, viewerID string, responses []storeTrackResponse) error {
	if h.likes == nil || len(responses) == 0 {
		return nil
	}
	ids := make([]string, len(responses))
	for i, response := range responses {
		ids[i] = response.ID
	}
	states, err := h.likes.EntryStates(ctx, viewerID, ids)
	if err != nil {
		return err
	}
	for i := range responses {
		state := states[responses[i].ID]
		responses[i].LikeCount, responses[i].Liked = state.Count, state.Liked
	}
	return nil
}

func NewCatalogHandlers(catalog CatalogStore, tokens *auth.Tokens, streams StreamPresigner, anonymous AnonymousLimits) *CatalogHandlers {
	salt := make([]byte, 32)
	if _, err := rand.Read(salt); err != nil {
		panic(err)
	}
	return &CatalogHandlers{catalog: catalog, tokens: tokens, streams: streams, anonymous: anonymous, playSalt: salt}
}

// WithSave lets signed-in listeners add a store song to their own library,
// within their quota.
func (h *CatalogHandlers) WithSave(copier TrackCopier, save SavePolicy) *CatalogHandlers {
	h.copier, h.save = copier, save
	return h
}

// WithReports accepts «گزارش تخلف» from signed-in listeners, rate limited
// per account.
func (h *CatalogHandlers) WithReports(rate *RateLimiter) *CatalogHandlers {
	h.reports = rate
	return h
}

// WithAdmin lets admins review reports and hide entries.
func (h *CatalogHandlers) WithAdmin(admin *AdminHandlers) *CatalogHandlers {
	h.admin = admin
	return h
}

func (h *CatalogHandlers) register(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/v1/store/tracks", h.handleTracks)
	mux.HandleFunc("GET /api/v1/store/tracks/{id}", h.handleTrack)
	mux.HandleFunc("GET /api/v1/store/tracks/{id}/stream", h.handleStream)
	mux.HandleFunc("GET /api/v1/store/tracks/{id}/artwork", h.handleStreamArtwork)
	mux.HandleFunc("GET /api/v1/store/artists", h.handleArtists)
	mux.HandleFunc("GET /api/v1/store/albums", h.handleAlbums)
	mux.HandleFunc("GET /api/v1/store/popular", h.handleRanked(store.RankPopular))
	mux.HandleFunc("GET /api/v1/store/trending", h.handleRanked(store.RankTrending))
	if h.copier != nil {
		mux.HandleFunc("POST /api/v1/store/tracks/{id}/save", h.handleSave)
	}
	if h.reports != nil {
		mux.HandleFunc("POST /api/v1/store/tracks/{id}/report", h.handleReport)
	}
	if h.admin != nil {
		mux.HandleFunc("GET /api/v1/admin/store/reports", h.handleReports)
		mux.HandleFunc("PUT /api/v1/admin/store/tracks/{id}/hidden", h.handleHide(true))
		mux.HandleFunc("DELETE /api/v1/admin/store/tracks/{id}/hidden", h.handleHide(false))
	}
}

// viewer is the signed-in user, or "" for an anonymous visitor within the
// given per-IP limit. It writes the error itself when it says no.
func (h *CatalogHandlers) viewer(w http.ResponseWriter, r *http.Request, limit *RateLimiter) (string, bool) {
	userID, ok := optionalUser(h.tokens, w, r)
	if !ok || userID != "" {
		return userID, ok
	}
	return "", enforceRateLimit(w, limit, clientIP(r))
}

// storeTrackResponse is a store entry as anyone sees it: the playing copy's
// song metadata, without its owner, file name, comment or upload details.
type storeTrackResponse struct {
	ID          string              `json:"id"`
	Title       string              `json:"title"`
	Artist      *string             `json:"artist"`
	Album       *string             `json:"album"`
	AlbumArtist *string             `json:"albumArtist"`
	Composer    *string             `json:"composer"`
	Genre       *string             `json:"genre"`
	Year        *int32              `json:"year"`
	TrackNumber *int32              `json:"trackNumber"`
	DiscNumber  *int32              `json:"discNumber"`
	DurationMS  *int32              `json:"durationMs"`
	ContentType string              `json:"contentType"`
	SizeBytes   int64               `json:"sizeBytes"`
	ReplayGain  *replayGainResponse `json:"replayGain"`
	// Hidden is only ever true in admin views.
	Hidden bool `json:"hidden,omitempty"`
	// LikeCount is how many listeners like the song; Liked whether the
	// viewer does (#284).
	LikeCount int  `json:"likeCount"`
	Liked     bool `json:"liked"`
}

func toStoreTrackResponse(entry store.StoreEntry) storeTrackResponse {
	t := entry.Track
	return storeTrackResponse{
		ID: entry.ID, Title: t.Title, Artist: t.Artist, Album: t.Album, AlbumArtist: t.AlbumArtist,
		Composer: t.Composer, Genre: t.Genre, Year: t.Year, TrackNumber: t.TrackNumber,
		DiscNumber: t.DiscNumber, DurationMS: t.DurationMS, ContentType: t.ContentType,
		SizeBytes: t.SizeBytes, ReplayGain: toReplayGain(t.Loudness), Hidden: entry.Hidden,
	}
}

// page reads ?limit= (default 50, at most 100) and ?offset= (at most
// 10000). It writes the error itself when they are invalid.
func page(w http.ResponseWriter, r *http.Request) (limit, offset int, ok bool) {
	limit = defaultStorePage
	if raw := r.URL.Query().Get("limit"); raw != "" {
		n, err := strconv.Atoi(raw)
		if err != nil || n < 1 {
			writeError(w, http.StatusBadRequest, "invalid_limit")
			return 0, 0, false
		}
		limit = min(n, maxStorePage)
	}
	if raw := r.URL.Query().Get("offset"); raw != "" {
		n, err := strconv.Atoi(raw)
		if err != nil || n < 0 || n > maxStoreOffset {
			writeError(w, http.StatusBadRequest, "invalid_offset")
			return 0, 0, false
		}
		offset = n
	}
	return limit, offset, true
}

// searchParam reads a short free-text query parameter.
func searchParam(w http.ResponseWriter, r *http.Request, name string) (string, bool) {
	value := strings.TrimSpace(r.URL.Query().Get(name))
	if !utf8.ValidString(value) || utf8.RuneCountInString(value) > maxStoreSearch {
		writeError(w, http.StatusBadRequest, "invalid_query")
		return "", false
	}
	return value, true
}

// handleTracks lists store songs by title. ?q= searches title, artist and
// album; ?artist= and ?album= pick one artist's or album's songs.
func (h *CatalogHandlers) handleTracks(w http.ResponseWriter, r *http.Request) {
	viewerID, ok := h.viewer(w, r, h.anonymous.View)
	if !ok {
		return
	}
	limit, offset, ok := page(w, r)
	if !ok {
		return
	}
	query := store.StoreQuery{Limit: limit, Offset: offset}
	for name, dest := range map[string]*string{"q": &query.Search, "artist": &query.Artist, "album": &query.Album} {
		if *dest, ok = searchParam(w, r, name); !ok {
			return
		}
	}
	entries, more, err := h.catalog.StoreEntries(r.Context(), query)
	if err != nil {
		internalError(w, "list store tracks", err)
		return
	}
	response := make([]storeTrackResponse, 0, len(entries))
	for _, entry := range entries {
		response = append(response, toStoreTrackResponse(entry))
	}
	if err := h.withLikes(r.Context(), viewerID, response); err != nil {
		internalError(w, "load store likes", err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]any{"tracks": response, "hasMore": more})
}

// entry loads the listed entry at {id}; unknown, hidden and emptied
// entries are the same 404.
func (h *CatalogHandlers) entry(w http.ResponseWriter, r *http.Request) (store.StoreEntry, bool) {
	entry, err := h.catalog.StoreEntryByID(r.Context(), r.PathValue("id"), false)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "not_found")
		return store.StoreEntry{}, false
	}
	if err != nil {
		internalError(w, "load store track", err)
		return store.StoreEntry{}, false
	}
	return entry, true
}

func (h *CatalogHandlers) handleTrack(w http.ResponseWriter, r *http.Request) {
	viewerID, ok := h.viewer(w, r, h.anonymous.View)
	if !ok {
		return
	}
	entry, ok := h.entry(w, r)
	if !ok {
		return
	}
	response := []storeTrackResponse{toStoreTrackResponse(entry)}
	if err := h.withLikes(r.Context(), viewerID, response); err != nil {
		internalError(w, "load store likes", err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, response[0])
}

// handleStream hands out a short-lived URL for the entry's best copy, the
// original file as uploaded.
func (h *CatalogHandlers) handleStream(w http.ResponseWriter, r *http.Request) {
	viewerID, ok := h.viewer(w, r, h.anonymous.Stream)
	if !ok {
		return
	}
	entry, ok := h.entry(w, r)
	if !ok {
		return
	}
	// A play counts toward popular and trending once per listener and day.
	if err := h.catalog.RecordStorePlay(r.Context(), entry.ID, h.listenerKey(viewerID, r)); err != nil {
		internalError(w, "record store play", err)
		return
	}
	url, expiresAt, err := h.streams.PresignGet(r.Context(), entry.Track.StorageKey)
	if err != nil {
		internalError(w, "presign store track", err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, streamResponse{URL: url, ExpiresAt: expiresAt.UTC()})
}

// listenerKey tells plays apart without storing who played: the account
// id for a listener, or for a visitor a keyed hash of their address that
// changes every day and with every server start.
func (h *CatalogHandlers) listenerKey(viewerID string, r *http.Request) string {
	if viewerID != "" {
		return "u:" + viewerID
	}
	mac := hmac.New(sha256.New, h.playSalt)
	mac.Write([]byte(time.Now().UTC().Format(time.DateOnly) + "|" + clientIP(r)))
	return "a:" + hex.EncodeToString(mac.Sum(nil))[:24]
}

// handleRanked lists popular or trending store songs, best first, from the
// cached scores; anyone may see them, within the visitor limits.
func (h *CatalogHandlers) handleRanked(ranking store.StoreRanking) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		viewerID, ok := h.viewer(w, r, h.anonymous.View)
		if !ok {
			return
		}
		limit, offset, ok := page(w, r)
		if !ok {
			return
		}
		entries, more, err := h.catalog.StoreRanked(r.Context(), ranking, limit, offset)
		if err != nil {
			internalError(w, "list ranked store tracks", err)
			return
		}
		response := make([]storeTrackResponse, 0, len(entries))
		for _, entry := range entries {
			response = append(response, toStoreTrackResponse(entry))
		}
		if err := h.withLikes(r.Context(), viewerID, response); err != nil {
			internalError(w, "load store likes", err)
			return
		}
		w.Header().Set("Cache-Control", "no-store")
		writeJSON(w, http.StatusOK, map[string]any{"tracks": response, "hasMore": more})
	}
}

type storeArtistResponse struct {
	Name       string `json:"name"`
	TrackCount int    `json:"trackCount"`
}

func (h *CatalogHandlers) handleArtists(w http.ResponseWriter, r *http.Request) {
	if _, ok := h.viewer(w, r, h.anonymous.View); !ok {
		return
	}
	limit, offset, ok := page(w, r)
	if !ok {
		return
	}
	search, ok := searchParam(w, r, "q")
	if !ok {
		return
	}
	artists, more, err := h.catalog.StoreArtists(r.Context(), search, limit, offset)
	if err != nil {
		internalError(w, "list store artists", err)
		return
	}
	response := make([]storeArtistResponse, 0, len(artists))
	for _, a := range artists {
		response = append(response, storeArtistResponse{Name: a.Name, TrackCount: a.TrackCount})
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]any{"artists": response, "hasMore": more})
}

type storeAlbumResponse struct {
	Name       string  `json:"name"`
	Artist     *string `json:"artist"`
	TrackCount int     `json:"trackCount"`
}

func (h *CatalogHandlers) handleAlbums(w http.ResponseWriter, r *http.Request) {
	if _, ok := h.viewer(w, r, h.anonymous.View); !ok {
		return
	}
	limit, offset, ok := page(w, r)
	if !ok {
		return
	}
	search, ok := searchParam(w, r, "q")
	if !ok {
		return
	}
	artist, ok := searchParam(w, r, "artist")
	if !ok {
		return
	}
	albums, more, err := h.catalog.StoreAlbums(r.Context(), search, artist, limit, offset)
	if err != nil {
		internalError(w, "list store albums", err)
		return
	}
	response := make([]storeAlbumResponse, 0, len(albums))
	for _, a := range albums {
		response = append(response, storeAlbumResponse{Name: a.Name, Artist: a.Artist, TrackCount: a.TrackCount})
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]any{"albums": response, "hasMore": more})
}

// handleSave adds «افزودن به کتابخانه‌ی من»: a copy of the entry's best
// copy becomes the caller's own track, within their quota.
func (h *CatalogHandlers) handleSave(w http.ResponseWriter, r *http.Request) {
	userID, ok := authenticate(h.tokens, w, r)
	if !ok {
		return
	}
	if !h.save.Enabled || h.save.Objects == nil {
		writeError(w, http.StatusServiceUnavailable, "uploads_disabled")
		return
	}
	entry, ok := h.entry(w, r)
	if !ok {
		return
	}
	owns, err := h.catalog.OwnsCopy(r.Context(), entry.ID, userID)
	if err != nil {
		internalError(w, "check store track owner", err)
		return
	}
	if owns {
		writeError(w, http.StatusConflict, "already_yours")
		return
	}
	copied, err := h.copier.SaveTrackCopy(r.Context(), userID, entry.Track, h.save.MaxOwnerBytes, h.save.Objects)
	switch {
	case errors.Is(err, store.ErrOwnPlaylist):
		writeError(w, http.StatusConflict, "already_yours")
	case errors.Is(err, store.ErrQuotaExceeded):
		writeError(w, http.StatusRequestEntityTooLarge, "quota_exceeded")
	case err != nil:
		internalError(w, "save store track", err)
	default:
		writeJSON(w, http.StatusCreated, toTrackResponse(copied))
	}
}

type reportRequest struct {
	Reason  string  `json:"reason"`
	Details *string `json:"details"`
}

// handleReport records a «گزارش تخلف» about the entry for admins to
// review. Reporting again is accepted and changes nothing.
func (h *CatalogHandlers) handleReport(w http.ResponseWriter, r *http.Request) {
	userID, ok := authenticate(h.tokens, w, r)
	if !ok || !enforceRateLimit(w, h.reports, userID) {
		return
	}
	var input reportRequest
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxReportBytes))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil || !reportReasons[input.Reason] {
		writeError(w, http.StatusBadRequest, "invalid_report")
		return
	}
	if input.Details != nil {
		details := strings.TrimSpace(*input.Details)
		if utf8.RuneCountInString(details) > maxReportDetails {
			writeError(w, http.StatusBadRequest, "invalid_report")
			return
		}
		input.Details = &details
		if details == "" {
			input.Details = nil
		}
	}
	err := h.catalog.ReportEntry(r.Context(), r.PathValue("id"), userID, input.Reason, input.Details)
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeError(w, http.StatusNotFound, "not_found")
	case err != nil:
		internalError(w, "report store track", err)
	default:
		w.WriteHeader(http.StatusNoContent)
	}
}

type storeReportResponse struct {
	ID        int64              `json:"id"`
	Track     storeTrackResponse `json:"track"`
	Copies    int                `json:"copies"`
	Reason    string             `json:"reason"`
	Details   *string            `json:"details"`
	Reports   int                `json:"reports"`
	CreatedAt time.Time          `json:"createdAt"`
}

// handleReports lists entries with open reports, oldest first, for admins.
func (h *CatalogHandlers) handleReports(w http.ResponseWriter, r *http.Request) {
	if _, ok := h.admin.authorize(w, r); !ok {
		return
	}
	limit, _, ok := page(w, r)
	if !ok {
		return
	}
	reports, err := h.catalog.OpenReports(r.Context(), limit)
	if err != nil {
		internalError(w, "list store reports", err)
		return
	}
	response := make([]storeReportResponse, 0, len(reports))
	for _, report := range reports {
		response = append(response, storeReportResponse{
			ID: report.ID, Track: toStoreTrackResponse(report.Entry), Copies: report.Entry.Copies,
			Reason: report.Reason, Details: report.Details, Reports: report.Reports,
			CreatedAt: report.CreatedAt.UTC(),
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"reports": response})
}

// handleHide hides (PUT) an entry from the store or lists it again
// (DELETE); either resolves its open reports.
func (h *CatalogHandlers) handleHide(hidden bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		adminID, ok := h.admin.authorize(w, r)
		if !ok {
			return
		}
		err := h.catalog.SetHidden(r.Context(), r.PathValue("id"), adminID, hidden)
		switch {
		case errors.Is(err, store.ErrNotFound):
			writeError(w, http.StatusNotFound, "not_found")
		case err != nil:
			internalError(w, "hide store track", err)
		default:
			w.WriteHeader(http.StatusNoContent)
		}
	}
}

func (h *CatalogHandlers) handleStreamArtwork(w http.ResponseWriter, r *http.Request) {
	_, ok := h.viewer(w, r, h.anonymous.View)
	if !ok {
		return
	}
	entry, ok := h.entry(w, r)
	if !ok {
		return
	}
	serveTrackArtwork(w, r, h.streams, entry.Track)
}
