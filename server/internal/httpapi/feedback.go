package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/mhdolatabadi/rhythmo/server/internal/store"
	"io"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"
)

type FeedbackStore interface {
	CreateFeedback(context.Context, string, string, string, string) error
	OpenFeedback(context.Context) ([]store.Feedback, error)
	ResolveFeedback(context.Context, string, string) error
}

func (h *AdminHandlers) registerFeedback(mux *http.ServeMux) {
	if _, ok := h.users.(FeedbackStore); !ok {
		return
	}
	rate := NewRateLimiter(RateLimit{Requests: 10, Window: time.Hour}, 10000)
	mux.HandleFunc("POST /api/v1/feedback", func(w http.ResponseWriter, r *http.Request) {
		id, ok := authenticate(h.auth.tokens, w, r)
		if !ok {
			return
		}
		if _, err := h.auth.users.ByID(r.Context(), id); err != nil {
			if errors.Is(err, store.ErrNotFound) {
				writeError(w, 401, "unauthorized")
			} else {
				internalError(w, "load feedback sender", err)
			}
			return
		}
		if !enforceRateLimit(w, rate, id) {
			return
		}
		var input struct {
			Kind    string `json:"kind"`
			Subject string `json:"subject"`
			Body    string `json:"body"`
		}
		d := json.NewDecoder(http.MaxBytesReader(w, r.Body, 32768))
		d.DisallowUnknownFields()
		if err := d.Decode(&input); err != nil {
			writeError(w, 400, "invalid_feedback")
			return
		}
		input.Subject = strings.TrimSpace(input.Subject)
		input.Body = strings.TrimSpace(input.Body)
		if d.Decode(&struct{}{}) != io.EOF || (input.Kind != "bug" && input.Kind != "feature" && input.Kind != "message") || input.Subject == "" || utf8.RuneCountInString(input.Subject) > 160 || input.Body == "" || utf8.RuneCountInString(input.Body) > 5000 {
			writeError(w, 400, "invalid_feedback")
			return
		}
		if err := h.users.(FeedbackStore).CreateFeedback(r.Context(), id, input.Kind, input.Subject, input.Body); err != nil {
			internalError(w, "create feedback", err)
			return
		}
		w.WriteHeader(http.StatusCreated)
	})
	mux.HandleFunc("GET /api/v1/admin/feedback", func(w http.ResponseWriter, r *http.Request) {
		if _, ok := h.authorize(w, r); !ok {
			return
		}
		items, err := h.users.(FeedbackStore).OpenFeedback(r.Context())
		if err != nil {
			internalError(w, "list feedback", err)
			return
		}
		writeJSON(w, 200, map[string]any{"feedback": items})
	})
	mux.HandleFunc("POST /api/v1/admin/feedback/{id}/resolve", func(w http.ResponseWriter, r *http.Request) {
		actor, ok := h.authorize(w, r)
		if !ok {
			return
		}
		err := h.users.(FeedbackStore).ResolveFeedback(r.Context(), r.PathValue("id"), actor)
		if errors.Is(err, store.ErrNotFound) {
			writeError(w, 404, "not_found")
			return
		}
		if err != nil {
			internalError(w, "resolve feedback", err)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})
}
