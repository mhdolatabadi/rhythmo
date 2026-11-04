package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"time"

	"github.com/mhdolatabadi/rhythmo/server/internal/bot"
	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

// SubscriptionStore is what subscribing to public playlists needs (#414).
type SubscriptionStore interface {
	SubscriptionFor(ctx context.Context, playlistID, userID string) (store.Subscription, error)
	SetSubscription(ctx context.Context, userID, token string, subscribed bool) (store.Subscription, error)
	SetMuted(ctx context.Context, userID, token string, muted bool) (store.Subscription, error)
	Subscribed(ctx context.Context, userID string) ([]store.SubscribedPlaylist, error)
}

// NotificationStore is a user's inbox of playlist notices.
type NotificationStore interface {
	List(ctx context.Context, userID string, limit int) ([]store.Notification, int, error)
	UnreadCount(ctx context.Context, userID string) (int, error)
	MarkRead(ctx context.Context, userID string, ids []string, shareToken string) error
}

const (
	defaultNotifications = 50
	maxNotifications     = 100
	maxMarkReadIDs       = 200
	maxMarkReadBodyBytes = 16 << 10
	notificationIDLength = 36
)

// WithSubscriptions lets people subscribe to public playlists like
// channels and read the notices of tracks added to them. It needs sharing.
func (h *PlaylistHandlers) WithSubscriptions(subscriptions SubscriptionStore, notifications NotificationStore) *PlaylistHandlers {
	h.subscriptions, h.notifications = subscriptions, notifications
	return h
}

func (h *PlaylistHandlers) registerSubscriptions(mux *http.ServeMux) {
	mux.HandleFunc("PUT /api/v1/shared-playlists/{token}/subscription", h.handleSubscribe(true))
	mux.HandleFunc("DELETE /api/v1/shared-playlists/{token}/subscription", h.handleSubscribe(false))
	mux.HandleFunc("PUT /api/v1/shared-playlists/{token}/subscription/mute", h.handleMute(true))
	mux.HandleFunc("DELETE /api/v1/shared-playlists/{token}/subscription/mute", h.handleMute(false))
	mux.HandleFunc("GET /api/v1/subscriptions", h.handleSubscribed)
	mux.HandleFunc("GET /api/v1/notifications", h.handleNotifications)
	mux.HandleFunc("GET /api/v1/notifications/unread-count", h.handleUnreadCount)
	mux.HandleFunc("POST /api/v1/notifications/read", h.handleMarkRead)
}

type subscriptionResponse struct {
	Subscribed      bool `json:"subscribed"`
	SubscriberCount int  `json:"subscriberCount"`
	Muted           bool `json:"muted"`
}

// handleSubscribe subscribes (PUT) to or unsubscribes (DELETE) from the
// public playlist shared at {token}. Both are idempotent.
func (h *PlaylistHandlers) handleSubscribe(subscribed bool) http.HandlerFunc {
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
		s, err := h.subscriptions.SetSubscription(r.Context(), userID, token, subscribed)
		switch {
		case errors.Is(err, store.ErrNotFound):
			writeError(w, http.StatusNotFound, "not_found")
		case errors.Is(err, store.ErrOwnPlaylist):
			writeError(w, http.StatusConflict, "own_playlist")
		case err != nil:
			internalError(w, "subscribe to playlist", err)
		default:
			writeJSON(w, http.StatusOK, subscriptionResponse{Subscribed: s.Subscribed, Muted: s.Muted, SubscriberCount: s.Count})
		}
	}
}

// handleMute mutes (PUT) or unmutes (DELETE) the caller's subscription to
// the playlist shared at {token} (#428). Both are idempotent; it is 404
// unless the caller is subscribed.
func (h *PlaylistHandlers) handleMute(muted bool) http.HandlerFunc {
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
		s, err := h.subscriptions.SetMuted(r.Context(), userID, token, muted)
		switch {
		case errors.Is(err, store.ErrNotFound):
			writeError(w, http.StatusNotFound, "not_found")
		case err != nil:
			internalError(w, "mute playlist subscription", err)
		default:
			writeJSON(w, http.StatusOK, subscriptionResponse{Subscribed: s.Subscribed, Muted: s.Muted, SubscriberCount: s.Count})
		}
	}
}

type subscribedPlaylistResponse struct {
	ShareToken   string    `json:"shareToken"`
	Name         string    `json:"name"`
	Owner        string    `json:"owner"`
	TrackCount   int       `json:"trackCount"`
	UnreadCount  int       `json:"unreadCount"`
	Muted        bool      `json:"muted"`
	SubscribedAt time.Time `json:"subscribedAt"`
	UpdatedAt    time.Time `json:"updatedAt"`
}

// handleSubscribed lists the public playlists the caller subscribed to,
// those with unread additions first.
func (h *PlaylistHandlers) handleSubscribed(w http.ResponseWriter, r *http.Request) {
	userID, ok := authenticate(h.tokens, w, r)
	if !ok {
		return
	}
	listed, err := h.subscriptions.Subscribed(r.Context(), userID)
	if err != nil {
		internalError(w, "list subscriptions", err)
		return
	}
	response := make([]subscribedPlaylistResponse, 0, len(listed))
	for _, p := range listed {
		response = append(response, subscribedPlaylistResponse{
			ShareToken: p.ShareToken, Name: p.Name, Owner: bot.MaskEmail(p.OwnerEmail), TrackCount: p.TrackCount,
			UnreadCount: p.Unread, Muted: p.Muted, SubscribedAt: p.SubscribedAt.UTC(), UpdatedAt: p.UpdatedAt.UTC(),
		})
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]any{"playlists": response})
}

type notificationResponse struct {
	ID           string    `json:"id"`
	Kind         string    `json:"kind"`
	ShareToken   string    `json:"shareToken"`
	PlaylistName string    `json:"playlistName"`
	TrackID      *string   `json:"trackId,omitempty"`
	TrackTitle   *string   `json:"trackTitle,omitempty"`
	TrackCount   int       `json:"trackCount"`
	Read         bool      `json:"read"`
	CreatedAt    time.Time `json:"createdAt"`
	UpdatedAt    time.Time `json:"updatedAt"`
}

// handleNotifications lists the caller's notices, newest first, with the
// unread count. ?limit= caps how many (default 50, at most 100).
func (h *PlaylistHandlers) handleNotifications(w http.ResponseWriter, r *http.Request) {
	userID, ok := authenticate(h.tokens, w, r)
	if !ok {
		return
	}
	limit := defaultNotifications
	if raw := r.URL.Query().Get("limit"); raw != "" {
		n, err := strconv.Atoi(raw)
		if err != nil || n < 1 {
			writeError(w, http.StatusBadRequest, "invalid_limit")
			return
		}
		limit = min(n, maxNotifications)
	}
	list, unread, err := h.notifications.List(r.Context(), userID, limit)
	if err != nil {
		internalError(w, "list notifications", err)
		return
	}
	response := make([]notificationResponse, 0, len(list))
	for _, n := range list {
		response = append(response, notificationResponse{
			ID: n.ID, Kind: "playlist_tracks_added", ShareToken: n.ShareToken, PlaylistName: n.PlaylistName,
			TrackID: n.TrackID, TrackTitle: n.TrackTitle, TrackCount: n.TrackCount, Read: n.ReadAt != nil,
			CreatedAt: n.CreatedAt.UTC(), UpdatedAt: n.UpdatedAt.UTC(),
		})
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]any{"notifications": response, "unreadCount": unread})
}

func (h *PlaylistHandlers) handleUnreadCount(w http.ResponseWriter, r *http.Request) {
	userID, ok := authenticate(h.tokens, w, r)
	if !ok {
		return
	}
	unread, err := h.notifications.UnreadCount(r.Context(), userID)
	if err != nil {
		internalError(w, "count notifications", err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]int{"unreadCount": unread})
}

type markReadRequest struct {
	// IDs are the notices to mark read; none marks them all.
	IDs []string `json:"ids"`
}

func (h *PlaylistHandlers) handleMarkRead(w http.ResponseWriter, r *http.Request) {
	userID, ok := authenticate(h.tokens, w, r)
	if !ok {
		return
	}
	var request markReadRequest
	if r.ContentLength != 0 {
		r.Body = http.MaxBytesReader(w, r.Body, maxMarkReadBodyBytes)
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil && !errors.Is(err, io.EOF) {
			writeError(w, http.StatusBadRequest, "invalid_json")
			return
		}
	}
	if len(request.IDs) > maxMarkReadIDs {
		writeError(w, http.StatusBadRequest, "invalid_ids")
		return
	}
	for _, id := range request.IDs {
		if len(id) != notificationIDLength {
			writeError(w, http.StatusBadRequest, "invalid_ids")
			return
		}
	}
	if err := h.notifications.MarkRead(r.Context(), userID, request.IDs, ""); err != nil {
		internalError(w, "mark notifications read", err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
