package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

type AdminStore interface {
	ListAccounts(context.Context, string, int, int) ([]store.User, bool, error)
	SetVerification(context.Context, string, string, bool) (store.User, error)
}

// AdminPlaylistStore takes public playlists out of the popular list, or
// deletes them.
type AdminPlaylistStore interface {
	SetPopularHidden(ctx context.Context, shareToken, actorID string, hidden bool) error
	DeleteShared(ctx context.Context, shareToken, actorID string) error
}

// AdminPublicationStore is admin review of what unverified owners publish
// (#322); *store.Publications implements it.
type AdminPublicationStore interface {
	Pending(ctx context.Context, limit int) ([]store.PendingPublication, error)
	PendingTrack(ctx context.Context, trackID string) (store.Track, error)
	ReviewPlaylist(ctx context.Context, playlistID, actorID string, approve bool) error
	ReviewTrack(ctx context.Context, trackID, actorID string, approve bool) error
}

// maxPendingPublications caps one page of the review queue.
const maxPendingPublications = 200

type AdminHandlers struct {
	auth         *AuthHandlers
	users        AdminStore
	playlists    AdminPlaylistStore
	publications AdminPublicationStore
	streams      StreamPresigner
}

func NewAdminHandlers(auth *AuthHandlers, users AdminStore) *AdminHandlers {
	return &AdminHandlers{auth: auth, users: users}
}

// WithPlaylists lets admins take playlists out of the popular list.
func (h *AdminHandlers) WithPlaylists(playlists AdminPlaylistStore) *AdminHandlers {
	h.playlists = playlists
	return h
}

// WithPublications lets admins review requests to list playlists publicly
// and publish tracks, and listen to a pending track first.
func (h *AdminHandlers) WithPublications(publications AdminPublicationStore, streams StreamPresigner) *AdminHandlers {
	h.publications, h.streams = publications, streams
	return h
}

func (h *AdminHandlers) register(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/v1/admin/accounts", h.list)
	mux.HandleFunc("PATCH /api/v1/admin/accounts/{id}/verification", h.verify)
	if h.playlists != nil {
		mux.HandleFunc("PATCH /api/v1/admin/public-playlists/{token}", h.hidePlaylist)
		mux.HandleFunc("DELETE /api/v1/admin/public-playlists/{token}", h.deletePlaylist)
	}
	if h.publications != nil {
		mux.HandleFunc("GET /api/v1/admin/publications", h.listPublications)
		mux.HandleFunc("PATCH /api/v1/admin/publications/playlists/{id}", h.reviewPublication(store.PublicationPlaylist))
		mux.HandleFunc("PATCH /api/v1/admin/publications/tracks/{id}", h.reviewPublication(store.PublicationTrack))
		mux.HandleFunc("GET /api/v1/admin/publications/tracks/{id}/stream", h.streamPendingTrack)
	}
}

// Authorize against a fresh database lookup on every request, not token claims.
func (h *AdminHandlers) authorize(w http.ResponseWriter, r *http.Request) (string, bool) {
	w.Header().Set("Cache-Control", "no-store")
	id, ok := authenticate(h.auth.tokens, w, r)
	if !ok {
		return "", false
	}
	user, err := h.auth.users.ByID(r.Context(), id)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return "", false
	}
	if err != nil {
		internalError(w, "authorize admin", err)
		return "", false
	}
	if !h.auth.isAdmin(user) {
		writeError(w, http.StatusForbidden, "admin_required")
		return "", false
	}
	return id, true
}

type adminAccountResponse struct {
	userResponse
	CreatedAt  time.Time  `json:"createdAt"`
	VerifiedAt *time.Time `json:"verifiedAt,omitempty"`
}

func (h *AdminHandlers) account(user store.User) adminAccountResponse {
	return adminAccountResponse{
		userResponse: h.auth.userResponse(user),
		CreatedAt:    user.CreatedAt, VerifiedAt: user.VerifiedAt,
	}
}

func (h *AdminHandlers) list(w http.ResponseWriter, r *http.Request) {
	if _, ok := h.authorize(w, r); !ok {
		return
	}
	query := strings.TrimSpace(r.URL.Query().Get("q"))
	offset := 0
	if raw := r.URL.Query().Get("offset"); raw != "" {
		value, err := strconv.Atoi(raw)
		if err != nil || value < 0 || value > 100000 {
			writeError(w, http.StatusBadRequest, "invalid_offset")
			return
		}
		offset = value
	}
	if len(query) > 254 {
		writeError(w, http.StatusBadRequest, "invalid_query")
		return
	}
	users, more, err := h.users.ListAccounts(r.Context(), query, offset, 50)
	if err != nil {
		internalError(w, "list admin accounts", err)
		return
	}
	accounts := make([]adminAccountResponse, 0, len(users))
	for _, user := range users {
		accounts = append(accounts, h.account(user))
	}
	writeJSON(w, http.StatusOK, struct {
		Accounts []adminAccountResponse `json:"accounts"`
		HasMore  bool                   `json:"hasMore"`
	}{accounts, more})
}

func (h *AdminHandlers) verify(w http.ResponseWriter, r *http.Request) {
	actor, ok := h.authorize(w, r)
	if !ok {
		return
	}
	var input struct {
		Verified *bool `json:"verified"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxAuthBodyBytes))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil || input.Verified == nil {
		writeError(w, http.StatusBadRequest, "invalid_json")
		return
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		writeError(w, http.StatusBadRequest, "invalid_json")
		return
	}
	user, err := h.users.SetVerification(r.Context(), r.PathValue("id"), actor, *input.Verified)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "account_not_found")
		return
	}
	if err != nil {
		internalError(w, "set account verification", err)
		return
	}
	writeJSON(w, http.StatusOK, h.account(user))
}

// hidePlaylist takes a public playlist out of the popular list with
// {"hidden":true}, or puts it back with {"hidden":false}. The playlist and
// its link are left as they are.
func (h *AdminHandlers) hidePlaylist(w http.ResponseWriter, r *http.Request) {
	actor, ok := h.authorize(w, r)
	if !ok {
		return
	}
	var input struct {
		Hidden *bool `json:"hidden"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxAuthBodyBytes))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil || input.Hidden == nil {
		writeError(w, http.StatusBadRequest, "invalid_json")
		return
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		writeError(w, http.StatusBadRequest, "invalid_json")
		return
	}
	token := r.PathValue("token")
	if !validShareToken(token) {
		writeError(w, http.StatusNotFound, "playlist_not_found")
		return
	}
	err := h.playlists.SetPopularHidden(r.Context(), token, actor, *input.Hidden)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "playlist_not_found")
		return
	}
	if err != nil {
		internalError(w, "hide popular playlist", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"hidden": *input.Hidden})
}

// deletePlaylist deletes a shared playlist, whoever owns it. The tracks stay
// in their owners' libraries.
func (h *AdminHandlers) deletePlaylist(w http.ResponseWriter, r *http.Request) {
	actor, ok := h.authorize(w, r)
	if !ok {
		return
	}
	token := r.PathValue("token")
	if !validShareToken(token) {
		writeError(w, http.StatusNotFound, "playlist_not_found")
		return
	}
	err := h.playlists.DeleteShared(r.Context(), token, actor)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "playlist_not_found")
		return
	}
	if err != nil {
		internalError(w, "delete public playlist", err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

type pendingPublicationResponse struct {
	Kind        string    `json:"kind"`
	ID          string    `json:"id"`
	Title       string    `json:"title"`
	Artist      string    `json:"artist,omitempty"`
	ShareToken  *string   `json:"shareToken,omitempty"`
	TrackCount  int       `json:"trackCount,omitempty"`
	OwnerID     string    `json:"ownerId"`
	OwnerEmail  string    `json:"ownerEmail"`
	RequestedAt time.Time `json:"requestedAt"`
}

// listPublications is the review queue (#322): playlists and tracks whose
// unverified owners asked to publish them, oldest request first.
func (h *AdminHandlers) listPublications(w http.ResponseWriter, r *http.Request) {
	if _, ok := h.authorize(w, r); !ok {
		return
	}
	pending, err := h.publications.Pending(r.Context(), maxPendingPublications)
	if err != nil {
		internalError(w, "list pending publications", err)
		return
	}
	items := make([]pendingPublicationResponse, 0, len(pending))
	for _, p := range pending {
		items = append(items, pendingPublicationResponse{
			Kind: p.Kind, ID: p.ID, Title: p.Title, Artist: p.Artist, ShareToken: p.ShareToken,
			TrackCount: p.TrackCount, OwnerID: p.OwnerID, OwnerEmail: p.OwnerEmail,
			RequestedAt: p.RequestedAt.UTC(),
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"publications": items})
}

// reviewPublication approves ({"approved":true}) or rejects
// ({"approved":false}) a pending request. Deciding a request that is no
// longer pending is 409 not_pending, so two admins can't both decide it.
func (h *AdminHandlers) reviewPublication(kind string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		actor, ok := h.authorize(w, r)
		if !ok {
			return
		}
		var input struct {
			Approved *bool `json:"approved"`
		}
		decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxAuthBodyBytes))
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&input); err != nil || input.Approved == nil {
			writeError(w, http.StatusBadRequest, "invalid_json")
			return
		}
		if err := decoder.Decode(new(any)); err != io.EOF {
			writeError(w, http.StatusBadRequest, "invalid_json")
			return
		}
		review := h.publications.ReviewTrack
		if kind == store.PublicationPlaylist {
			review = h.publications.ReviewPlaylist
		}
		err := review(r.Context(), r.PathValue("id"), actor, *input.Approved)
		if errors.Is(err, store.ErrNotPending) {
			writeError(w, http.StatusConflict, "not_pending")
			return
		}
		if err != nil {
			internalError(w, "review publication", err)
			return
		}
		writeJSON(w, http.StatusOK, map[string]bool{"approved": *input.Approved})
	}
}

// streamPendingTrack lets an admin listen to a track before deciding.
func (h *AdminHandlers) streamPendingTrack(w http.ResponseWriter, r *http.Request) {
	if _, ok := h.authorize(w, r); !ok {
		return
	}
	if h.streams == nil {
		writeError(w, http.StatusServiceUnavailable, "streaming_unavailable")
		return
	}
	track, err := h.publications.PendingTrack(r.Context(), r.PathValue("id"))
	if errors.Is(err, store.ErrNotPending) {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	if err != nil {
		internalError(w, "load pending track", err)
		return
	}
	url, expiresAt, err := h.streams.PresignGet(r.Context(), track.StorageKey)
	if err != nil {
		internalError(w, "presign pending track", err)
		return
	}
	writeJSON(w, http.StatusOK, streamResponse{URL: url, ExpiresAt: expiresAt.UTC()})
}
