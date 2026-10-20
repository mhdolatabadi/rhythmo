package httpapi

import (
	"context"
	"errors"
	"net/http"
	"time"

	"github.com/mhdolatabadi/rhythmo/server/internal/auth"
	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

// LikeStore keeps likes on tracks and store songs; *store.TrackLikes
// implements it.
type LikeStore interface {
	SetOwnLike(ctx context.Context, userID, trackID string, liked bool) (store.LikeState, error)
	SetStoreLike(ctx context.Context, userID, entryID string, liked bool) (store.LikeState, error)
	EntryStates(ctx context.Context, viewerID string, entryIDs []string) (map[string]store.LikeState, error)
	OwnerStates(ctx context.Context, ownerID string) (map[string]store.LikeState, error)
	Liked(ctx context.Context, userID string, limit, offset int) ([]store.LikedSong, bool, error)
}

// Publisher publishes an owner's track on its own; *store.Tracks
// implements it.
type Publisher interface {
	SetPublished(ctx context.Context, ownerID, trackID string, published, direct bool) (store.Track, error)
}

// LikeHandlers serve #284: publishing one track to the store, liking
// tracks and store songs, and «پسندیده‌ها». Every change needs an account
// and is rate limited per account; there are no anonymous likes.
type LikeHandlers struct {
	likes     LikeStore
	publisher Publisher
	tokens    *auth.Tokens
	rate      *RateLimiter
	// publishGate sends publishing by unverified owners to an admin first
	// (#322); nil publishes directly.
	publishGate *PublishGate
}

// WithPublishGate makes publishing a track need an admin's approval unless
// the owner is verified or an admin.
func (h *LikeHandlers) WithPublishGate(gate *PublishGate) *LikeHandlers {
	h.publishGate = gate
	return h
}

func NewLikeHandlers(likes LikeStore, publisher Publisher, tokens *auth.Tokens, rate *RateLimiter) *LikeHandlers {
	return &LikeHandlers{likes: likes, publisher: publisher, tokens: tokens, rate: rate}
}

func (h *LikeHandlers) register(mux *http.ServeMux) {
	mux.HandleFunc("PUT /api/v1/tracks/{id}/published", h.handlePublish(true))
	mux.HandleFunc("DELETE /api/v1/tracks/{id}/published", h.handlePublish(false))
	mux.HandleFunc("PUT /api/v1/tracks/{id}/like", h.handleLike(false, true))
	mux.HandleFunc("DELETE /api/v1/tracks/{id}/like", h.handleLike(false, false))
	mux.HandleFunc("PUT /api/v1/store/tracks/{id}/like", h.handleLike(true, true))
	mux.HandleFunc("DELETE /api/v1/store/tracks/{id}/like", h.handleLike(true, false))
	mux.HandleFunc("GET /api/v1/likes", h.handleLiked)
}

type publishResponse struct {
	Published   bool       `json:"published"`
	PublishedAt *time.Time `json:"publishedAt"`
	// Review is "pending" while publishing waits for an admin (#322) and
	// "rejected" after one turned it down.
	Review *string `json:"review,omitempty"`
}

// handlePublish publishes (PUT) the caller's own track to the store or
// makes it private again (DELETE). Both are idempotent. An owner who is not
// verified only asks to publish; an admin decides (#322).
func (h *LikeHandlers) handlePublish(published bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		userID, ok := authenticate(h.tokens, w, r)
		if !ok || !enforceRateLimit(w, h.rate, userID) {
			return
		}
		direct := true
		if published {
			if direct, ok = h.publishGate.direct(w, r, userID); !ok {
				return
			}
		}
		track, err := h.publisher.SetPublished(r.Context(), userID, r.PathValue("id"), published, direct)
		switch {
		case errors.Is(err, store.ErrNotFound):
			writeError(w, http.StatusNotFound, "not_found")
		case err != nil:
			internalError(w, "publish track", err)
		default:
			response := publishResponse{Published: track.PublishedAt != nil, Review: track.PublishReview}
			if track.PublishedAt != nil {
				at := track.PublishedAt.UTC()
				response.PublishedAt = &at
			}
			writeJSON(w, http.StatusOK, response)
		}
	}
}

type trackLikeResponse struct {
	Liked     bool `json:"liked"`
	LikeCount int  `json:"likeCount"`
}

// handleLike likes (PUT) or unlikes (DELETE) one of the caller's own
// tracks, or a store song. Both are idempotent, so a retry changes nothing.
func (h *LikeHandlers) handleLike(fromStore, liked bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		userID, ok := authenticate(h.tokens, w, r)
		if !ok || !enforceRateLimit(w, h.rate, userID) {
			return
		}
		var state store.LikeState
		var err error
		if fromStore {
			state, err = h.likes.SetStoreLike(r.Context(), userID, r.PathValue("id"), liked)
		} else {
			state, err = h.likes.SetOwnLike(r.Context(), userID, r.PathValue("id"), liked)
		}
		switch {
		case errors.Is(err, store.ErrNotFound):
			writeError(w, http.StatusNotFound, "not_found")
		case err != nil:
			internalError(w, "like track", err)
		default:
			writeJSON(w, http.StatusOK, trackLikeResponse{Liked: state.Liked, LikeCount: state.Count})
		}
	}
}

// likedSongResponse is one of «پسندیده‌ها»: the listener's own track
// (source library, track) or a store song (source store, storeTrack).
type likedSongResponse struct {
	Source     string              `json:"source"`
	LikedAt    time.Time           `json:"likedAt"`
	Track      *trackResponse      `json:"track,omitempty"`
	StoreTrack *storeTrackResponse `json:"storeTrack,omitempty"`
}

// handleLiked lists «پسندیده‌ها», most recently liked first, a page at a
// time (?limit=, ?offset=).
func (h *LikeHandlers) handleLiked(w http.ResponseWriter, r *http.Request) {
	userID, ok := authenticate(h.tokens, w, r)
	if !ok {
		return
	}
	limit, offset, ok := page(w, r)
	if !ok {
		return
	}
	songs, more, err := h.likes.Liked(r.Context(), userID, limit, offset)
	if err != nil {
		internalError(w, "list liked songs", err)
		return
	}
	response := make([]likedSongResponse, 0, len(songs))
	for _, song := range songs {
		item := likedSongResponse{LikedAt: song.LikedAt.UTC()}
		if song.Entry != nil {
			track := toStoreTrackResponse(*song.Entry)
			track.Liked = true
			item.Source, item.StoreTrack = "store", &track
		} else {
			track := toOwnTrackResponse(song.Track, store.LikeState{Liked: true})
			item.Source, item.Track = "library", &track
		}
		response = append(response, item)
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]any{"songs": response, "hasMore": more})
}

// toOwnTrackResponse is a track as its owner sees it in their library:
// whether they published it, and how many listeners like the song.
func toOwnTrackResponse(t store.Track, likes store.LikeState) trackResponse {
	response := toTrackResponse(t)
	response.Published = t.PublishedAt != nil
	response.PublishReview = t.PublishReview
	response.LikeCount, response.Liked = likes.Count, likes.Liked
	return response
}
