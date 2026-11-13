package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"time"

	"github.com/mhdolatabadi/rhythmo/server/internal/auth"
	"github.com/mhdolatabadi/rhythmo/server/internal/bot"
	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

const (
	// maxHistoryEntries is how many plays are kept per user: enough for
	// «برای تو» to see a month of listening (#226).
	maxHistoryEntries = 1000
	// defaultHistoryLimit is how many recent tracks are listed when the
	// request doesn't say.
	defaultHistoryLimit = 50
	maxHistoryBodyBytes = 1 << 10
)

// HistoryStore keeps each user's recently played tracks; *store.History
// implements it.
type HistoryStore interface {
	Record(ctx context.Context, userID, trackID string, playlistID *string, keep int) error
	Recent(ctx context.Context, userID string, limit int) ([]store.HistoryEntry, error)
	Clear(ctx context.Context, userID string) error
}

// HistoryHandlers serve the recently played list, the same on every
// device signed in to the account.
type HistoryHandlers struct {
	history HistoryStore
	tokens  *auth.Tokens
	// rate limits how often each user records a play.
	rate *RateLimiter
}

func NewHistoryHandlers(history HistoryStore, tokens *auth.Tokens, rate *RateLimiter) *HistoryHandlers {
	return &HistoryHandlers{history: history, tokens: tokens, rate: rate}
}

func (h *HistoryHandlers) register(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/v1/history", h.handleList)
	mux.HandleFunc("POST /api/v1/history", h.handleRecord)
	mux.HandleFunc("DELETE /api/v1/history", h.handleClear)
}

type historyEntryResponse struct {
	PlayedAt time.Time `json:"playedAt"`
	// PlaylistID is set for someone else's track, which is played through
	// that collaborative playlist.
	PlaylistID *string               `json:"playlistId,omitempty"`
	Track      playlistTrackResponse `json:"track"`
}

type historyResponse struct {
	Entries []historyEntryResponse `json:"entries"`
}

type recordPlayRequest struct {
	TrackID    string  `json:"trackId"`
	PlaylistID *string `json:"playlistId"`
}

func (h *HistoryHandlers) handleList(w http.ResponseWriter, r *http.Request) {
	userID, ok := authenticate(h.tokens, w, r)
	if !ok {
		return
	}
	limit := defaultHistoryLimit
	if raw := r.URL.Query().Get("limit"); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil || parsed < 1 {
			writeError(w, http.StatusBadRequest, "invalid_limit")
			return
		}
		limit = min(parsed, maxHistoryEntries)
	}
	entries, err := h.history.Recent(r.Context(), userID, limit)
	if err != nil {
		internalError(w, "list history", err)
		return
	}
	response := historyResponse{Entries: make([]historyEntryResponse, 0, len(entries))}
	for _, e := range entries {
		track := playlistTrackResponse{trackResponse: toTrackResponse(e.Track)}
		if e.Track.OwnerID != userID {
			// Only the masked address, as a collaborative playlist shows it.
			addedBy := bot.MaskEmail(e.OwnerEmail)
			track.AddedBy = &addedBy
		}
		response.Entries = append(response.Entries, historyEntryResponse{
			PlayedAt: e.PlayedAt.UTC(), PlaylistID: e.PlaylistID, Track: track,
		})
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, response)
}

// handleRecord adds a play the app counted as a meaningful listen.
func (h *HistoryHandlers) handleRecord(w http.ResponseWriter, r *http.Request) {
	userID, ok := authenticate(h.tokens, w, r)
	if !ok {
		return
	}
	if !enforceRateLimit(w, h.rate, userID) {
		return
	}
	var input recordPlayRequest
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxHistoryBodyBytes))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil || input.TrackID == "" {
		writeError(w, http.StatusBadRequest, "invalid_json")
		return
	}
	err := h.history.Record(r.Context(), userID, input.TrackID, input.PlaylistID, maxHistoryEntries)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	if err != nil {
		internalError(w, "record play", err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *HistoryHandlers) handleClear(w http.ResponseWriter, r *http.Request) {
	userID, ok := authenticate(h.tokens, w, r)
	if !ok {
		return
	}
	if err := h.history.Clear(r.Context(), userID); err != nil {
		internalError(w, "clear history", err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
