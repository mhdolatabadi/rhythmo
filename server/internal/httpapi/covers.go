package httpapi

import (
	"context"
	"errors"
	"io"
	"net/http"
	"sync/atomic"

	"github.com/mhdolatabadi/rhythmo/server/internal/store"
	"github.com/mhdolatabadi/rhythmo/server/internal/tags"
)

// maxCoverUploadBytes bounds a chosen cover before it is decoded; the stored
// copy is re-encoded to at most 512 px.
const maxCoverUploadBytes = 10 << 20

// TrackCoverStore keeps covers owners choose (#225); *store.Tracks
// implements it.
type TrackCoverStore interface {
	SetTrackCover(ctx context.Context, ownerID, trackID string, expectedVersion int64, image []byte, tagStatus store.TagStatus) (store.Track, error)
	TrackCover(ctx context.Context, trackID string) ([]byte, error)
}

// chosenCovers is where every artwork endpoint looks first, so a chosen
// cover shows wherever the track's artwork does.
var chosenCovers atomic.Pointer[TrackCoverStore]

func chosenCover(ctx context.Context, trackID string) ([]byte, error) {
	covers := chosenCovers.Load()
	if covers == nil {
		return nil, nil
	}
	return (*covers).TrackCover(ctx, trackID)
}

// handleSetCover sets or replaces a track's cover from an uploaded JPEG, PNG
// or GIF. Like a metadata edit it needs the current version (If-Match),
// bumps it, and has the tag writer embed the cover so downloads carry it.
func (h *TrackHandlers) handleSetCover(w http.ResponseWriter, r *http.Request) {
	covers, ok := h.tracks.(TrackCoverStore)
	if !ok {
		writeError(w, http.StatusNotImplemented, "covers_unavailable")
		return
	}
	track, ok := h.readyTrack(w, r)
	if !ok {
		return
	}
	version, ok := requestVersion(r, nil)
	if !ok {
		writeError(w, http.StatusPreconditionRequired, "version_required")
		return
	}
	data, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxCoverUploadBytes))
	var tooLarge *http.MaxBytesError
	if errors.As(err, &tooLarge) {
		writeError(w, http.StatusRequestEntityTooLarge, "cover_too_large")
		return
	}
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_image")
		return
	}
	image := artworkThumbnail(data)
	if image == nil {
		writeError(w, http.StatusBadRequest, "invalid_image")
		return
	}
	status := store.TagUnsupported
	if tags.Supported(track.FileName) {
		status = store.TagPending
	}
	updated, err := covers.SetTrackCover(r.Context(), track.OwnerID, track.ID, version, image, status)
	switch {
	case errors.Is(err, store.ErrVersionConflict):
		h.writeConflict(w, r, track)
		return
	case errors.Is(err, store.ErrNotFound):
		writeError(w, http.StatusNotFound, "not_found")
		return
	case err != nil:
		internalError(w, "set track cover", err)
		return
	}
	if h.retags != nil && updated.TagStatus == store.TagPending {
		h.retags.Notify()
	}
	writeJSON(w, http.StatusOK, toTrackResponse(updated))
}
