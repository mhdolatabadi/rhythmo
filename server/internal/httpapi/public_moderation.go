package httpapi

import (
	"context"
	"errors"
	"net/http"

	"github.com/mhdolatabadi/rhythmo/server/internal/moderation"
	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

// publicReviewRequester sends a renamed public playlist back to review;
// *store.Playlists implements it.
type publicReviewRequester interface {
	RequestPublicReviewAgain(ctx context.Context, playlistID string) error
}

// allowedInPublic refuses, with 422 inappropriate_content, a playlist that
// is listed or about to be when its name, description or a track title
// holds a word the filter rejects (#207). name and description, when set,
// stand in for the stored ones, for a rename. A private playlist being
// renamed is not checked. It writes the error itself when it says no.
func (h *PlaylistHandlers) allowedInPublic(w http.ResponseWriter, r *http.Request, userID, playlistID string, name, description *string) bool {
	playlist, err := h.playlists.ForUser(r.Context(), userID, playlistID)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "not_found")
		return false
	}
	if err != nil {
		internalError(w, "load playlist for moderation", err)
		return false
	}
	renaming := name != nil
	listed := playlist.IsPublic || (playlist.PublicReview != nil && *playlist.PublicReview == store.ReviewPending)
	if renaming && !listed {
		return true
	}
	texts := []string{playlist.Name, playlist.Description}
	if renaming {
		texts = []string{*name}
		if description != nil {
			texts = append(texts, *description)
		}
	} else {
		for _, t := range playlist.Tracks {
			texts = append(texts, t.Title)
			if t.Artist != nil {
				texts = append(texts, *t.Artist)
			}
		}
	}
	if _, hit := moderation.Check(texts...); hit {
		writeError(w, http.StatusUnprocessableEntity, "inappropriate_content")
		return false
	}
	return true
}

// reviewRenamedPlaylist sends a public playlist whose owner is not verified
// back to admin review after a rename, so an approved name can't be swapped
// for another (#207). It returns the playlist as it now is.
func (h *PlaylistHandlers) reviewRenamedPlaylist(w http.ResponseWriter, r *http.Request, playlist store.Playlist) (store.Playlist, bool) {
	requester, ok := h.shared.(publicReviewRequester)
	if !ok || !playlist.IsPublic {
		return playlist, true
	}
	direct, ok := h.publishGate.direct(w, r, playlist.OwnerID)
	if !ok {
		return playlist, false
	}
	if direct {
		return playlist, true
	}
	if err := requester.RequestPublicReviewAgain(r.Context(), playlist.ID); err != nil {
		internalError(w, "send renamed playlist to review", err)
		return playlist, false
	}
	pending := store.ReviewPending
	playlist.IsPublic, playlist.PublicReview = false, &pending
	return playlist, true
}
