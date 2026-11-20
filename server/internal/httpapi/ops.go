package httpapi

import (
	"context"
	"crypto/subtle"
	"net/http"
	"strings"

	"github.com/mhdolatabadi/rhythmo/server/internal/bot"
)

// BotHealthReporter reports each bot's webhook, import queue and counters.
type BotHealthReporter interface {
	Health(ctx context.Context) ([]bot.BotHealth, error)
}

// OpsHandlers serve operator-only status, behind a token separate from any
// user account.
type TranscriptionHealth struct {
	Healthy              bool  `json:"healthy"`
	ModelReady           bool  `json:"modelReady"`
	Queued               int64 `json:"queued"`
	Processing           int64 `json:"processing"`
	Failed               int64 `json:"failed"`
	OldestPendingSeconds int64 `json:"oldestPendingSeconds"`
}

type OpsHandlers struct {
	token         string
	bots          BotHealthReporter
	transcription func(context.Context) (TranscriptionHealth, error)
}

// WithTranscription makes model readiness and aggregate queue health visible
// to the operator only; the route is never exposed without OPS_TOKEN.
func (h *OpsHandlers) WithTranscription(probe func(context.Context) (TranscriptionHealth, error)) *OpsHandlers {
	h.transcription = probe
	return h
}

func NewOpsHandlers(token string, bots BotHealthReporter) *OpsHandlers {
	return &OpsHandlers{token: token, bots: bots}
}

func (h *OpsHandlers) register(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/v1/ops/bots", h.handleBots)
	if h.transcription != nil {
		mux.HandleFunc("GET /api/v1/ops/transcription", h.handleTranscription)
	}
}

func (h *OpsHandlers) authorized(r *http.Request) bool {
	token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	return ok && subtle.ConstantTimeCompare([]byte(token), []byte(h.token)) == 1
}

type botHealthResponse struct {
	Healthy bool            `json:"healthy"`
	Bots    []bot.BotHealth `json:"bots"`
}

func (h *OpsHandlers) handleBots(w http.ResponseWriter, r *http.Request) {
	if !h.authorized(r) {
		// Indistinguishable from a route that does not exist.
		http.NotFound(w, r)
		return
	}
	response := botHealthResponse{Healthy: true, Bots: []bot.BotHealth{}}
	if h.bots != nil {
		report, err := h.bots.Health(r.Context())
		if err != nil {
			internalError(w, "bot health", err)
			return
		}
		response.Bots = report
	}
	for _, b := range response.Bots {
		if len(b.Problems) > 0 {
			response.Healthy = false
		}
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, response)
}

func (h *OpsHandlers) handleTranscription(w http.ResponseWriter, r *http.Request) {
	if !h.authorized(r) {
		http.NotFound(w, r)
		return
	}
	status, err := h.transcription(r.Context())
	if err != nil {
		internalError(w, "transcription health", err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, status)
}
