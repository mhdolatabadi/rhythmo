package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"

	"github.com/mhdolatabadi/rhythmo/server/internal/balearchive"
	"github.com/mhdolatabadi/rhythmo/server/internal/linkimport"
	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

type BaleArchive interface {
	Preview(context.Context, int64) (balearchive.Page, error)
	Submit(context.Context, string, string, int64, string, int) (store.BotImport, error)
	Recent(context.Context, string) ([]store.BaleArchiveImport, error)
}

func (h *AdminHandlers) WithBaleArchive(archive BaleArchive, rate *RateLimiter) *AdminHandlers {
	h.baleArchive = archive
	h.archiveRate = rate
	return h
}
func (h *AdminHandlers) registerBaleArchive(mux *http.ServeMux) {
	if h.baleArchive == nil {
		return
	}
	mux.HandleFunc("GET /api/v1/admin/bale-archive/preview", h.previewBale)
	mux.HandleFunc("POST /api/v1/admin/bale-archive/import", h.importBale)
	mux.HandleFunc("GET /api/v1/admin/bale-archive/imports", h.recentBale)
}
func (h *AdminHandlers) previewBale(w http.ResponseWriter, r *http.Request) {
	userID, ok := h.authorize(w, r)
	if !ok {
		return
	}
	if h.archiveRate != nil && !enforceRateLimit(w, h.archiveRate, userID) {
		return
	}
	var before int64
	if raw := r.URL.Query().Get("before"); raw != "" {
		n, err := strconv.ParseInt(raw, 10, 64)
		if err != nil || n <= 0 || n >= 9007199254740991 {
			writeError(w, http.StatusBadRequest, "invalid_cursor")
			return
		}
		before = n
	}
	ctx, cancel := linkImportContext(w, r)
	defer cancel()
	page, err := h.baleArchive.Preview(ctx, before)
	if err != nil {
		writeError(w, http.StatusBadGateway, "archive_unavailable")
		return
	}
	writeJSON(w, http.StatusOK, page)
}
func (h *AdminHandlers) importBale(w http.ResponseWriter, r *http.Request) {
	userID, ok := h.authorize(w, r)
	if !ok {
		return
	}
	if h.archiveRate != nil && !enforceRateLimit(w, h.archiveRate, userID) {
		return
	}
	var input struct {
		ID      string `json:"id"`
		Date    int64  `json:"date"`
		Topic   string `json:"topic"`
		Session int    `json:"session"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8<<10))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&input) != nil || decoder.Decode(new(any)) != io.EOF || input.Date <= 0 || input.Date >= 9007199254740991 || input.Session < 0 || input.Session > 10000 || len([]rune(input.Topic)) > 180 {
		writeError(w, http.StatusBadRequest, "invalid_json")
		return
	}
	if _, err := strconv.ParseInt(input.ID, 10, 64); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_post")
		return
	}
	ctx, cancel := linkImportContext(w, r)
	defer cancel()
	job, err := h.baleArchive.Submit(ctx, userID, input.ID, input.Date, input.Topic, input.Session)
	switch {
	case errors.Is(err, balearchive.ErrTopic):
		writeError(w, http.StatusUnprocessableEntity, "topic_required")
	case errors.Is(err, balearchive.ErrSession):
		writeError(w, http.StatusUnprocessableEntity, "session_required")
	case errors.Is(err, store.ErrArchiveBusy):
		writeError(w, http.StatusTooManyRequests, "too_many_imports")
	case writeLinkImportError(w, err):
	case errors.Is(err, linkimport.ErrBalePage):
		writeError(w, http.StatusBadGateway, "archive_unavailable")
	case err != nil:
		internalError(w, "queue bale archive", err)
	default:
		writeJSON(w, http.StatusAccepted, map[string]any{"id": job.ID, "state": job.State, "fileName": job.FileName, "trackId": job.TrackID, "playlistId": job.PlaylistID, "error": job.Error})
	}
}
func (h *AdminHandlers) recentBale(w http.ResponseWriter, r *http.Request) {
	userID, ok := h.authorize(w, r)
	if !ok {
		return
	}
	jobs, err := h.baleArchive.Recent(r.Context(), userID)
	if err != nil {
		internalError(w, "list bale archive", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"imports": jobs})
}
