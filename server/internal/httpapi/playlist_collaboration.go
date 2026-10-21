package httpapi

import (
	"errors"
	"net/http"

	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

// registerCollaboration serves collaborative playlists: the owner turns a
// collaboration link on and off and manages members; anyone signed in who
// opens the link joins and can add tracks from their own library.
func (h *PlaylistHandlers) registerCollaboration(mux *http.ServeMux) {
	mux.HandleFunc("POST /api/v1/playlists/{id}/collab", h.handleCollabLink)
	mux.HandleFunc("DELETE /api/v1/playlists/{id}/collab", h.handleRevokeCollab)
	mux.HandleFunc("POST /api/v1/collab/{token}/join", h.handleJoin)
	mux.HandleFunc("DELETE /api/v1/playlists/{id}/members/{userId}", h.handleRemoveMember)
	mux.HandleFunc("DELETE /api/v1/playlists/{id}/membership", h.handleLeave)
	mux.HandleFunc("GET /api/v1/playlists/{id}/tracks/{trackId}/stream", h.handlePlaylistStream)
	mux.HandleFunc("GET /api/v1/playlists/{id}/tracks/{trackId}/artwork", h.handlePlaylistStreamArtwork)
}

type collabResponse struct {
	CollabToken string `json:"collabToken"`
}

// handleCollabLink makes a new collaboration link. Each call draws a new
// token, so an old link stops working.
func (h *PlaylistHandlers) handleCollabLink(w http.ResponseWriter, r *http.Request) {
	userID, ok := authenticate(h.tokens, w, r)
	if !ok {
		return
	}
	for range 3 {
		token, err := newShareToken()
		if err != nil {
			internalError(w, "draw collaboration token", err)
			return
		}
		playlist, err := h.playlists.SetCollabToken(r.Context(), userID, r.PathValue("id"), &token)
		switch {
		case errors.Is(err, store.ErrShareTokenTaken):
			continue
		case errors.Is(err, store.ErrNotFound):
			writeError(w, http.StatusNotFound, "not_found")
		case err != nil:
			internalError(w, "make collaboration link", err)
		default:
			writeJSON(w, http.StatusOK, collabResponse{CollabToken: *playlist.CollabToken})
		}
		return
	}
	internalError(w, "make collaboration link", errors.New("could not draw an unused token"))
}

func (h *PlaylistHandlers) handleRevokeCollab(w http.ResponseWriter, r *http.Request) {
	userID, ok := authenticate(h.tokens, w, r)
	if !ok {
		return
	}
	_, err := h.playlists.SetCollabToken(r.Context(), userID, r.PathValue("id"), nil)
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeError(w, http.StatusNotFound, "not_found")
	case err != nil:
		internalError(w, "revoke collaboration link", err)
	default:
		w.WriteHeader(http.StatusNoContent)
	}
}

func (h *PlaylistHandlers) handleJoin(w http.ResponseWriter, r *http.Request) {
	userID, ok := authenticate(h.tokens, w, r)
	if !ok {
		return
	}
	token := r.PathValue("token")
	if !validShareToken(token) {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	playlist, err := h.playlists.Join(r.Context(), userID, token)
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeError(w, http.StatusNotFound, "not_found")
	case err != nil:
		internalError(w, "join playlist", err)
	default:
		writeJSON(w, http.StatusOK, toPlaylistResponse(playlist, userID, true))
	}
}

func (h *PlaylistHandlers) removeMember(w http.ResponseWriter, r *http.Request, actorID, memberID string) {
	err := h.playlists.RemoveMember(r.Context(), actorID, r.PathValue("id"), memberID)
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeError(w, http.StatusNotFound, "not_found")
	case errors.Is(err, store.ErrForbidden):
		writeError(w, http.StatusForbidden, "forbidden")
	case err != nil:
		internalError(w, "remove playlist member", err)
	default:
		w.WriteHeader(http.StatusNoContent)
	}
}

// handleRemoveMember is the owner taking someone out of the playlist.
func (h *PlaylistHandlers) handleRemoveMember(w http.ResponseWriter, r *http.Request) {
	userID, ok := authenticate(h.tokens, w, r)
	if !ok {
		return
	}
	h.removeMember(w, r, userID, r.PathValue("userId"))
}

// handleLeave is a member leaving, with the tracks they added.
func (h *PlaylistHandlers) handleLeave(w http.ResponseWriter, r *http.Request) {
	userID, ok := authenticate(h.tokens, w, r)
	if !ok {
		return
	}
	h.removeMember(w, r, userID, userID)
}

// handlePlaylistStream lets the owner and members play any track in the
// playlist, including ones another member added.
func (h *PlaylistHandlers) handlePlaylistStream(w http.ResponseWriter, r *http.Request) {
	userID, ok := authenticate(h.tokens, w, r)
	if !ok {
		return
	}
	if h.streams == nil {
		writeError(w, http.StatusServiceUnavailable, "streaming_disabled")
		return
	}
	track, err := h.playlists.PlaylistTrack(r.Context(), userID, r.PathValue("id"), r.PathValue("trackId"))
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	if err != nil {
		internalError(w, "load playlist track", err)
		return
	}
	url, expiresAt, err := h.streams.PresignGet(r.Context(), track.StorageKey)
	if err != nil {
		internalError(w, "presign playlist track", err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, streamResponse{URL: url, ExpiresAt: expiresAt.UTC()})
}

func (h *PlaylistHandlers) handlePlaylistStreamArtwork(w http.ResponseWriter, r *http.Request) {
	userID, ok := authenticate(h.tokens, w, r)
	if !ok {
		return
	}
	if h.streams == nil {
		writeError(w, http.StatusServiceUnavailable, "streaming_disabled")
		return
	}
	track, err := h.playlists.PlaylistTrack(r.Context(), userID, r.PathValue("id"), r.PathValue("trackId"))
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	if err != nil {
		internalError(w, "load playlist track", err)
		return
	}
	serveTrackArtwork(w, r, h.streams, track)
}
