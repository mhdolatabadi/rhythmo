package httpapi

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"time"

	"github.com/mhdolatabadi/rhythmo/server/internal/auth"
	"github.com/mhdolatabadi/rhythmo/server/internal/discover"
	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

// ForYouSignals reads what «برای تو» is built from: the user's own ready
// tracks and their plays of them.
type ForYouSignals interface {
	ListForOwner(ctx context.Context, ownerID string) ([]store.Track, error)
	OwnPlays(ctx context.Context, userID string) ([]store.PlayRecord, error)
}

// ForYouHandlers serve #226: smart playlists, daily mixes and radio, all
// computed on the server from the user's own library and listening only.
type ForYouHandlers struct {
	signals ForYouSignals
	tokens  *auth.Tokens
	rate    *RateLimiter
	now     func() time.Time
}

func NewForYouHandlers(signals ForYouSignals, tokens *auth.Tokens, rate *RateLimiter) *ForYouHandlers {
	return &ForYouHandlers{signals: signals, tokens: tokens, rate: rate, now: time.Now}
}

func (h *ForYouHandlers) register(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/v1/for-you", h.handleForYou)
	mux.HandleFunc("POST /api/v1/radio", h.handleRadio)
}

type forYouList struct {
	Key    string          `json:"key"`
	Title  string          `json:"title"`
	Tracks []trackResponse `json:"tracks"`
}

type forYouResponse struct {
	// Smart lists update themselves and are read-only.
	Smart []forYouList `json:"smart"`
	// Mixes are the day's mixes; Day says which day they are for.
	Mixes []forYouList `json:"mixes"`
	Day   string       `json:"day"`
}

func toForYouLists(lists []discover.List) []forYouList {
	out := make([]forYouList, 0, len(lists))
	for _, l := range lists {
		tracks := make([]trackResponse, 0, len(l.Tracks))
		for _, t := range l.Tracks {
			tracks = append(tracks, toTrackResponse(t))
		}
		out = append(out, forYouList{Key: l.Key, Title: l.Title, Tracks: tracks})
	}
	return out
}

func (h *ForYouHandlers) load(w http.ResponseWriter, r *http.Request) (string, discover.Signals, bool) {
	userID, ok := authenticate(h.tokens, w, r)
	if !ok || !enforceRateLimit(w, h.rate, userID) {
		return "", discover.Signals{}, false
	}
	tracks, err := h.signals.ListForOwner(r.Context(), userID)
	if err != nil {
		internalError(w, "load library for you", err)
		return "", discover.Signals{}, false
	}
	plays, err := h.signals.OwnPlays(r.Context(), userID)
	if err != nil {
		internalError(w, "load plays for you", err)
		return "", discover.Signals{}, false
	}
	signals := discover.Signals{Tracks: tracks, Plays: make([]discover.Play, len(plays))}
	for i, p := range plays {
		signals.Plays[i] = discover.Play{TrackID: p.TrackID, PlayedAt: p.PlayedAt}
	}
	return userID, signals, true
}

func (h *ForYouHandlers) handleForYou(w http.ResponseWriter, r *http.Request) {
	userID, signals, ok := h.load(w, r)
	if !ok {
		return
	}
	now := h.now().UTC()
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, forYouResponse{
		Smart: toForYouLists(discover.Smart(signals, now)),
		Mixes: toForYouLists(discover.DailyMixes(userID, signals, now)),
		Day:   now.Format("2006-01-02"),
	})
}

// maxRadioIDs caps the seeds and queued tracks a radio request names.
const maxRadioIDs = 500

func (h *ForYouHandlers) handleRadio(w http.ResponseWriter, r *http.Request) {
	var input struct {
		Seeds   []string `json:"seeds"`
		Exclude []string `json:"exclude"`
	}
	d := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10))
	d.DisallowUnknownFields()
	if err := d.Decode(&input); err != nil || d.Decode(&struct{}{}) != io.EOF ||
		len(input.Seeds) == 0 || len(input.Seeds) > 20 || len(input.Exclude) > maxRadioIDs {
		// Authenticate first, so a visitor learns nothing from the body.
		if _, ok := authenticate(h.tokens, w, r); ok {
			writeError(w, http.StatusBadRequest, "invalid_radio")
		}
		return
	}
	_, signals, ok := h.load(w, r)
	if !ok {
		return
	}
	exclude := make(map[string]bool, len(input.Exclude))
	for _, id := range input.Exclude {
		exclude[id] = true
	}
	tracks := discover.Radio(signals, input.Seeds, exclude, discover.RadioLimit, h.now().UTC())
	response := make([]trackResponse, 0, len(tracks))
	for _, t := range tracks {
		response = append(response, toTrackResponse(t))
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]any{"tracks": response})
}
