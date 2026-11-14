package httpapi

import (
	"context"
	"errors"
	"net/http"
	"time"

	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

// ProfileReviewer decides pending public profiles (#228);
// *store.Publications implements it.
type ProfileReviewer interface {
	ReviewProfile(ctx context.Context, userID, actorID string, approve bool) error
}

// AdminProfileStore is admin moderation of public profiles (#228);
// *store.Profiles implements it.
type AdminProfileStore interface {
	PendingAvatar(ctx context.Context, userID string) (string, []byte, error)
	OpenReports(ctx context.Context, limit int) ([]store.ProfileReport, error)
	ResolveReports(ctx context.Context, userID, adminID string, hide bool) error
}

// maxProfileReports caps one page of the profile report queue.
const maxProfileReports = 200

// WithProfiles lets admins review public profiles and their reports.
func (h *AdminHandlers) WithProfiles(profiles AdminProfileStore) *AdminHandlers {
	h.profiles = profiles
	return h
}

func (h *AdminHandlers) registerProfiles(mux *http.ServeMux) {
	if h.publications != nil {
		mux.HandleFunc("PATCH /api/v1/admin/publications/profiles/{id}", h.reviewPublication(store.PublicationProfile))
	}
	mux.HandleFunc("GET /api/v1/admin/publications/profiles/{id}/avatar", h.pendingAvatar)
	mux.HandleFunc("GET /api/v1/admin/profile-reports", h.listProfileReports)
	mux.HandleFunc("PATCH /api/v1/admin/profile-reports/{id}", h.resolveProfileReports)
}

func (h *AdminHandlers) pendingAvatar(w http.ResponseWriter, r *http.Request) {
	if _, ok := h.authorize(w, r); !ok {
		return
	}
	kind, data, err := h.profiles.PendingAvatar(r.Context(), r.PathValue("id"))
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	if err != nil {
		internalError(w, "read pending avatar", err)
		return
	}
	writeImage(w, kind, data)
}

type profileReportResponse struct {
	UserID      string    `json:"userId"`
	Handle      string    `json:"handle"`
	DisplayName string    `json:"displayName"`
	Bio         string    `json:"bio"`
	Reason      string    `json:"reason"`
	Details     *string   `json:"details,omitempty"`
	Reports     int       `json:"reports"`
	ReportedAt  time.Time `json:"reportedAt"`
}

// listProfileReports is the queue of reported profiles, oldest first.
func (h *AdminHandlers) listProfileReports(w http.ResponseWriter, r *http.Request) {
	if _, ok := h.authorize(w, r); !ok {
		return
	}
	reports, err := h.profiles.OpenReports(r.Context(), maxProfileReports)
	if err != nil {
		internalError(w, "list profile reports", err)
		return
	}
	items := make([]profileReportResponse, 0, len(reports))
	for _, report := range reports {
		items = append(items, profileReportResponse{
			UserID: report.ID, Handle: report.Handle, DisplayName: report.DisplayName, Bio: report.Bio,
			Reason: report.Reason, Details: report.Details, Reports: report.Reports, ReportedAt: report.CreatedAt.UTC(),
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"reports": items})
}

// resolveProfileReports closes a profile's reports; {"hide":true} also
// takes the profile down.
func (h *AdminHandlers) resolveProfileReports(w http.ResponseWriter, r *http.Request) {
	actor, ok := h.authorize(w, r)
	if !ok {
		return
	}
	var input struct {
		Hide *bool `json:"hide"`
	}
	if !decodeStrict(w, r, &input) {
		return
	}
	if input.Hide == nil {
		writeError(w, http.StatusBadRequest, "invalid_json")
		return
	}
	err := h.profiles.ResolveReports(r.Context(), r.PathValue("id"), actor, *input.Hide)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	if err != nil {
		internalError(w, "resolve profile reports", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"hidden": *input.Hide})
}
