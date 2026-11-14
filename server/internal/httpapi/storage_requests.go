package httpapi

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

// Users ask for more storage and admins decide (#208).

// StorageRequestStore keeps the requests; *store.Users implements it.
type StorageRequestStore interface {
	RequestStorage(ctx context.Context, accountID string, bytes int64, reason string) (store.StorageRequest, error)
	LatestStorageRequest(ctx context.Context, accountID string) (store.StorageRequest, error)
	PendingStorageRequests(ctx context.Context, limit int, fallback int64) ([]store.PendingStorageRequest, error)
	DecideStorageRequest(ctx context.Context, id, actorID string, approve bool, bytes int64, reason string, fallback int64) (store.StorageRequest, error)
}

const (
	maxStorageRequestReasonRunes = 300
	// maxStorageRequestBytes matches the largest quota an account can have.
	maxStorageRequestBytes    = 1 << 40
	maxPendingStorageRequests = 200
)

type storageRequestResponse struct {
	ID             string     `json:"id"`
	RequestedBytes int64      `json:"requestedBytes"`
	Reason         string     `json:"reason"`
	Status         string     `json:"status"`
	GrantedBytes   *int64     `json:"grantedBytes,omitempty"`
	DecisionReason *string    `json:"decisionReason,omitempty"`
	DecidedAt      *time.Time `json:"decidedAt,omitempty"`
	CreatedAt      time.Time  `json:"createdAt"`
}

func toStorageRequestResponse(r store.StorageRequest) storageRequestResponse {
	return storageRequestResponse{
		ID: r.ID, RequestedBytes: r.RequestedBytes, Reason: r.Reason, Status: r.Status,
		GrantedBytes: r.GrantedBytes, DecisionReason: r.DecisionReason, DecidedAt: r.DecidedAt,
		CreatedAt: r.CreatedAt.UTC(),
	}
}

type pendingStorageRequestResponse struct {
	storageRequestResponse
	AccountID  string `json:"accountId"`
	Email      string `json:"email"`
	UsedBytes  int64  `json:"usedBytes"`
	QuotaBytes int64  `json:"quotaBytes"`
}

func (h *AdminHandlers) storageRequests() StorageRequestStore {
	requests, _ := h.users.(StorageRequestStore)
	return requests
}

func (h *AdminHandlers) registerStorageRequests(mux *http.ServeMux) {
	if h.storageRequests() == nil {
		return
	}
	// A few asks a day per account; one can be open at a time anyway.
	rate := NewRateLimiter(RateLimit{Requests: 3, Window: 24 * time.Hour}, 10000)
	mux.HandleFunc("GET /api/v1/me/storage-request", h.handleMyStorageRequest)
	mux.HandleFunc("POST /api/v1/me/storage-request", func(w http.ResponseWriter, r *http.Request) {
		h.handleRequestStorage(w, r, rate)
	})
	mux.HandleFunc("GET /api/v1/admin/storage-requests", h.handlePendingStorageRequests)
	mux.HandleFunc("PATCH /api/v1/admin/storage-requests/{id}", h.handleDecideStorageRequest)
}

// handleMyStorageRequest is the caller's latest request; 204 when none.
func (h *AdminHandlers) handleMyStorageRequest(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	id, ok := authenticate(h.auth.tokens, w, r)
	if !ok {
		return
	}
	request, err := h.storageRequests().LatestStorageRequest(r.Context(), id)
	if errors.Is(err, store.ErrNotFound) {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if err != nil {
		internalError(w, "load storage request", err)
		return
	}
	writeJSON(w, http.StatusOK, toStorageRequestResponse(request))
}

func (h *AdminHandlers) handleRequestStorage(w http.ResponseWriter, r *http.Request, rate *RateLimiter) {
	w.Header().Set("Cache-Control", "no-store")
	id, ok := authenticate(h.auth.tokens, w, r)
	if !ok {
		return
	}
	user, ok := h.auth.currentUser(w, r, id)
	if !ok {
		return
	}
	// Only accounts that proved their address may ask.
	if !h.auth.emailVerified(user) {
		writeError(w, http.StatusForbidden, "email_unverified")
		return
	}
	var input struct {
		Bytes  int64  `json:"bytes"`
		Reason string `json:"reason"`
	}
	if !decodeStrict(w, r, &input) {
		return
	}
	reason := strings.Join(strings.Fields(input.Reason), " ")
	if input.Bytes <= 0 || input.Bytes > maxStorageRequestBytes ||
		utf8.RuneCountInString(reason) > maxStorageRequestReasonRunes || strings.IndexFunc(reason, unicode.IsControl) >= 0 {
		writeError(w, http.StatusBadRequest, "invalid_storage_request")
		return
	}
	current := h.defaultQuota
	if user.StorageQuotaBytes != nil {
		current = *user.StorageQuotaBytes
	}
	if input.Bytes <= current {
		writeError(w, http.StatusBadRequest, "invalid_storage_request")
		return
	}
	if !enforceRateLimit(w, rate, id) {
		return
	}
	request, err := h.storageRequests().RequestStorage(r.Context(), id, input.Bytes, reason)
	if errors.Is(err, store.ErrStorageRequestOpen) {
		writeError(w, http.StatusConflict, "request_open")
		return
	}
	if err != nil {
		internalError(w, "request storage", err)
		return
	}
	writeJSON(w, http.StatusCreated, toStorageRequestResponse(request))
}

func (h *AdminHandlers) handlePendingStorageRequests(w http.ResponseWriter, r *http.Request) {
	if _, ok := h.authorize(w, r); !ok {
		return
	}
	pending, err := h.storageRequests().PendingStorageRequests(r.Context(), maxPendingStorageRequests, h.defaultQuota)
	if err != nil {
		internalError(w, "list storage requests", err)
		return
	}
	items := make([]pendingStorageRequestResponse, 0, len(pending))
	for _, p := range pending {
		items = append(items, pendingStorageRequestResponse{
			storageRequestResponse: toStorageRequestResponse(p.StorageRequest),
			AccountID:              p.AccountID, Email: p.Email, UsedBytes: p.UsedBytes, QuotaBytes: p.QuotaBytes,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"requests": items})
}

func (h *AdminHandlers) handleDecideStorageRequest(w http.ResponseWriter, r *http.Request) {
	actor, ok := h.authorize(w, r)
	if !ok {
		return
	}
	var input struct {
		Approved *bool  `json:"approved"`
		Bytes    int64  `json:"bytes"`
		Reason   string `json:"reason"`
	}
	if !decodeStrict(w, r, &input) {
		return
	}
	if input.Approved == nil {
		writeError(w, http.StatusBadRequest, "invalid_json")
		return
	}
	reason := strings.Join(strings.Fields(input.Reason), " ")
	if utf8.RuneCountInString(reason) > maxStorageRequestReasonRunes ||
		(*input.Approved && (input.Bytes <= 0 || input.Bytes > maxStorageRequestBytes)) {
		writeError(w, http.StatusBadRequest, "invalid_storage_request")
		return
	}
	request, err := h.storageRequests().DecideStorageRequest(r.Context(), r.PathValue("id"), actor,
		*input.Approved, input.Bytes, reason, h.defaultQuota)
	switch {
	case errors.Is(err, store.ErrNotPending):
		writeError(w, http.StatusConflict, "not_pending")
	case errors.Is(err, store.ErrQuotaDecrease):
		writeError(w, http.StatusConflict, "quota_decrease")
	case err != nil:
		internalError(w, "decide storage request", err)
	default:
		writeJSON(w, http.StatusOK, toStorageRequestResponse(request))
	}
}
