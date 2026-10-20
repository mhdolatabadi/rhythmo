package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/mhdolatabadi/rhythmo/server/internal/auth"
	"github.com/mhdolatabadi/rhythmo/server/internal/bot"
	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

const (
	maxPlaylistBodyBytes = 64 << 10
	maxPlaylistNameRunes = 200
	maxPlaylistTracks    = 1000
)

type PlaylistStore interface {
	ListForUser(ctx context.Context, userID string) ([]store.Playlist, error)
	ForUser(ctx context.Context, userID, playlistID string) (store.Playlist, error)
	Create(ctx context.Context, ownerID, name string) (store.Playlist, error)
	Rename(ctx context.Context, ownerID, playlistID, name string) (store.Playlist, error)
	ReplaceTracks(ctx context.Context, userID, playlistID string, trackIDs []string) error
	Delete(ctx context.Context, ownerID, playlistID string) error
	SetCollabToken(ctx context.Context, ownerID, playlistID string, token *string) (store.Playlist, error)
	Join(ctx context.Context, userID, token string) (store.Playlist, error)
	RemoveMember(ctx context.Context, actorID, playlistID, memberID string) error
	PlaylistTrack(ctx context.Context, userID, playlistID, trackID string) (store.Track, error)
}

type PlaylistHandlers struct {
	playlists PlaylistStore
	tokens    *auth.Tokens
	shared    SharedPlaylistStore
	streams   StreamPresigner
	save      SavePolicy
	// anonymous is set when visitors without an account may browse public
	// playlists.
	anonymous *AnonymousLimits
	// emailGate keeps unverified accounts from listing playlists publicly
	// and from saving copies into their storage; nil allows everyone.
	emailGate *EmailGate
	// publishGate sends public listing by unverified owners to an admin
	// first (#322); nil lists directly.
	publishGate *PublishGate
}

// WithPublishGate makes listing a playlist publicly need an admin's
// approval unless the owner is verified or an admin.
func (h *PlaylistHandlers) WithPublishGate(gate *PublishGate) *PlaylistHandlers {
	h.publishGate = gate
	return h
}

// WithEmailGate keeps accounts with an unverified email out of what costs
// storage or reaches other people.
func (h *PlaylistHandlers) WithEmailGate(gate *EmailGate) *PlaylistHandlers {
	h.emailGate = gate
	return h
}

func NewPlaylistHandlers(playlists PlaylistStore, tokens *auth.Tokens) *PlaylistHandlers {
	return &PlaylistHandlers{playlists: playlists, tokens: tokens}
}

func (h *PlaylistHandlers) register(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/v1/playlists", h.handleList)
	mux.HandleFunc("POST /api/v1/playlists", h.handleCreate)
	mux.HandleFunc("GET /api/v1/playlists/{id}", h.handleGet)
	mux.HandleFunc("PUT /api/v1/playlists/{id}", h.handleRename)
	mux.HandleFunc("DELETE /api/v1/playlists/{id}", h.handleDelete)
	mux.HandleFunc("PUT /api/v1/playlists/{id}/tracks", h.handleReplaceTracks)
	h.registerCollaboration(mux)
	if h.shared != nil {
		h.registerSharing(mux)
	}
}

type playlistResponse struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	TrackCount int    `json:"trackCount"`
	// IsOwner is false for a playlist the user joined as a member.
	IsOwner bool `json:"isOwner"`
	// ShareToken is set while the playlist is shared; only its owner sees it.
	ShareToken *string `json:"shareToken,omitempty"`
	// Public is whether a shared playlist is listed for everyone.
	Public bool `json:"public"`
	// PublicReview is "pending" while a request to list it waits for an
	// admin and "rejected" after one turned it down; only its owner sees it.
	PublicReview *string `json:"publicReview,omitempty"`
	// CollabToken is set while people can join; only its owner sees it.
	CollabToken *string `json:"collabToken,omitempty"`
	// Owner and Members are loaded with the tracks.
	Owner     string                   `json:"owner,omitempty"`
	Members   []playlistMemberResponse `json:"members,omitempty"`
	Tracks    []playlistTrackResponse  `json:"tracks,omitempty"`
	CreatedAt time.Time                `json:"createdAt"`
	UpdatedAt time.Time                `json:"updatedAt"`
}

type playlistMemberResponse struct {
	ID       string    `json:"id"`
	Name     string    `json:"name"`
	JoinedAt time.Time `json:"joinedAt"`
}

// playlistTrackResponse is a track as a playlist lists it. AddedBy names
// whoever added a track that isn't the viewer's own.
type playlistTrackResponse struct {
	trackResponse
	AddedBy *string `json:"addedBy,omitempty"`
}

// toPlaylistResponse shows the playlist to viewerID. Emails are masked:
// members see who else is in the playlist, not their full address.
func toPlaylistResponse(playlist store.Playlist, viewerID string, includeTracks bool) playlistResponse {
	isOwner := playlist.OwnerID == viewerID
	trackCount := playlist.TrackCount
	if len(playlist.Tracks) > trackCount {
		trackCount = len(playlist.Tracks)
	}
	response := playlistResponse{
		ID: playlist.ID, Name: playlist.Name, TrackCount: trackCount, IsOwner: isOwner,
		Public: playlist.IsPublic, CreatedAt: playlist.CreatedAt.UTC(), UpdatedAt: playlist.UpdatedAt.UTC(),
	}
	if isOwner {
		response.ShareToken, response.CollabToken = playlist.ShareToken, playlist.CollabToken
		response.PublicReview = playlist.PublicReview
	}
	if !includeTracks {
		return response
	}
	names := map[string]string{playlist.OwnerID: bot.MaskEmail(playlist.OwnerEmail)}
	response.Owner = names[playlist.OwnerID]
	response.Members = make([]playlistMemberResponse, 0, len(playlist.Members))
	for _, m := range playlist.Members {
		names[m.UserID] = bot.MaskEmail(m.Email)
		response.Members = append(response.Members, playlistMemberResponse{ID: m.UserID, Name: names[m.UserID], JoinedAt: m.JoinedAt.UTC()})
	}
	response.Tracks = make([]playlistTrackResponse, 0, len(playlist.Tracks))
	for _, track := range playlist.Tracks {
		item := playlistTrackResponse{trackResponse: toTrackResponse(track)}
		if track.OwnerID != viewerID {
			name := names[track.OwnerID]
			item.AddedBy = &name
		}
		response.Tracks = append(response.Tracks, item)
	}
	return response
}

func (h *PlaylistHandlers) handleList(w http.ResponseWriter, r *http.Request) {
	userID, ok := authenticate(h.tokens, w, r)
	if !ok {
		return
	}
	playlists, err := h.playlists.ListForUser(r.Context(), userID)
	if err != nil {
		internalError(w, "list playlists", err)
		return
	}
	response := make([]playlistResponse, 0, len(playlists))
	for _, playlist := range playlists {
		response = append(response, toPlaylistResponse(playlist, userID, false))
	}
	writeJSON(w, http.StatusOK, map[string]any{"playlists": response})
}

func (h *PlaylistHandlers) handleGet(w http.ResponseWriter, r *http.Request) {
	userID, ok := authenticate(h.tokens, w, r)
	if !ok {
		return
	}
	playlist, err := h.playlists.ForUser(r.Context(), userID, r.PathValue("id"))
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	if err != nil {
		internalError(w, "get playlist", err)
		return
	}
	writeJSON(w, http.StatusOK, toPlaylistResponse(playlist, userID, true))
}

type playlistNameRequest struct {
	Name string `json:"name"`
}

func (h *PlaylistHandlers) handleCreate(w http.ResponseWriter, r *http.Request) {
	userID, ok := authenticate(h.tokens, w, r)
	if !ok {
		return
	}
	name, ok := decodePlaylistName(w, r)
	if !ok {
		return
	}
	playlist, err := h.playlists.Create(r.Context(), userID, name)
	if err != nil {
		internalError(w, "create playlist", err)
		return
	}
	writeJSON(w, http.StatusCreated, toPlaylistResponse(playlist, userID, false))
}

func (h *PlaylistHandlers) handleRename(w http.ResponseWriter, r *http.Request) {
	userID, ok := authenticate(h.tokens, w, r)
	if !ok {
		return
	}
	name, ok := decodePlaylistName(w, r)
	if !ok {
		return
	}
	playlist, err := h.playlists.Rename(r.Context(), userID, r.PathValue("id"), name)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	if err != nil {
		internalError(w, "rename playlist", err)
		return
	}
	writeJSON(w, http.StatusOK, toPlaylistResponse(playlist, userID, false))
}

type replacePlaylistTracksRequest struct {
	TrackIDs []string `json:"trackIds"`
}

func (h *PlaylistHandlers) handleReplaceTracks(w http.ResponseWriter, r *http.Request) {
	userID, ok := authenticate(h.tokens, w, r)
	if !ok {
		return
	}
	var input replacePlaylistTracksRequest
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxPlaylistBodyBytes))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil || input.TrackIDs == nil || len(input.TrackIDs) > maxPlaylistTracks {
		writeError(w, http.StatusBadRequest, "invalid_playlist_tracks")
		return
	}
	seen := make(map[string]struct{}, len(input.TrackIDs))
	for _, id := range input.TrackIDs {
		if strings.TrimSpace(id) == "" {
			writeError(w, http.StatusBadRequest, "invalid_playlist_tracks")
			return
		}
		if _, duplicate := seen[id]; duplicate {
			writeError(w, http.StatusBadRequest, "duplicate_track")
			return
		}
		seen[id] = struct{}{}
	}
	if err := h.playlists.ReplaceTracks(r.Context(), userID, r.PathValue("id"), input.TrackIDs); errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "not_found")
		return
	} else if errors.Is(err, store.ErrForbidden) {
		// A member tried to take out a track someone else added.
		writeError(w, http.StatusForbidden, "forbidden")
		return
	} else if err != nil {
		internalError(w, "replace playlist tracks", err)
		return
	}
	playlist, err := h.playlists.ForUser(r.Context(), userID, r.PathValue("id"))
	if err != nil {
		internalError(w, "reload playlist", err)
		return
	}
	writeJSON(w, http.StatusOK, toPlaylistResponse(playlist, userID, true))
}

func (h *PlaylistHandlers) handleDelete(w http.ResponseWriter, r *http.Request) {
	userID, ok := authenticate(h.tokens, w, r)
	if !ok {
		return
	}
	if err := h.playlists.Delete(r.Context(), userID, r.PathValue("id")); errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "not_found")
		return
	} else if err != nil {
		internalError(w, "delete playlist", err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func decodePlaylistName(w http.ResponseWriter, r *http.Request) (string, bool) {
	var input playlistNameRequest
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxPlaylistBodyBytes))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_json")
		return "", false
	}
	name := strings.TrimSpace(input.Name)
	if name == "" || utf8.RuneCountInString(name) > maxPlaylistNameRunes {
		writeError(w, http.StatusBadRequest, "invalid_playlist_name")
		return "", false
	}
	return name, true
}
