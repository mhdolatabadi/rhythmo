package httpapi

import (
	"context"
	"net/http"
	"testing"

	"github.com/mhdolatabadi/rhythmo/server/internal/auth"
	"github.com/mhdolatabadi/rhythmo/server/internal/store"
	"golang.org/x/crypto/bcrypt"
)

type profilePublications struct{ *fakePublications }

func (f profilePublications) ReviewProfile(_ context.Context, id, actor string, approve bool) error {
	return f.review(store.PublicationProfile, id, actor, approve)
}

type fakeAdminProfiles struct {
	reports  []store.ProfileReport
	resolved map[string]bool
}

func (f *fakeAdminProfiles) PendingAvatar(_ context.Context, userID string) (string, []byte, error) {
	if userID != "u1" {
		return "", nil, store.ErrNotFound
	}
	return "image/png", []byte("png"), nil
}

func (f *fakeAdminProfiles) OpenReports(context.Context, int) ([]store.ProfileReport, error) {
	return f.reports, nil
}

func (f *fakeAdminProfiles) ResolveReports(_ context.Context, userID, _ string, hide bool) error {
	if userID != "u1" {
		return store.ErrNotFound
	}
	f.resolved[userID] = hide
	return nil
}

func TestAdminModeratesProfiles(t *testing.T) {
	api := newTestAPI(t)
	admin, _ := api.users.Create(context.Background(), "admin@example.com", "hash")
	member, _ := api.users.Create(context.Background(), "member@example.com", "hash")
	adminToken, _, _ := api.tokens.Issue(admin.ID)
	memberToken, _, _ := api.tokens.Issue(member.ID)
	handlers, err := NewAuthHandlers(api.users, auth.Passwords{Cost: bcrypt.MinCost}, api.tokens, AuthRateLimiters{})
	if err != nil {
		t.Fatal(err)
	}
	handlers.WithAdmins([]string{admin.Email})
	publications := profilePublications{&fakePublications{
		pending:  []store.PendingPublication{{Kind: store.PublicationProfile, ID: "u1", Title: "سارا", Handle: "sara", Bio: "سلام", HasAvatar: true}},
		decided:  map[string]bool{},
		presence: map[string]bool{"profile|u1": true},
	}}
	profiles := &fakeAdminProfiles{
		reports:  []store.ProfileReport{{ID: "u1", Handle: "sara", Reason: "spam", Reports: 2}},
		resolved: map[string]bool{},
	}
	api.handler = NewHandler(Config{Auth: handlers,
		Admin: NewAdminHandlers(handlers, &fakeAdminStore{}).WithPublications(publications, fixedPresigner{}).WithProfiles(profiles)})

	for _, c := range []struct{ method, path, body string }{
		{"PATCH", "/api/v1/admin/publications/profiles/u1", `{"approved":true}`},
		{"GET", "/api/v1/admin/publications/profiles/u1/avatar", ""},
		{"GET", "/api/v1/admin/profile-reports", ""},
		{"PATCH", "/api/v1/admin/profile-reports/u1", `{"hide":true}`},
	} {
		expectError(t, api.do(t, c.method, c.path, c.body, memberToken), http.StatusForbidden, "admin_required")
	}

	list := decode[struct {
		Publications []pendingPublicationResponse `json:"publications"`
	}](t, api.do(t, "GET", "/api/v1/admin/publications", "", adminToken))
	if len(list.Publications) != 1 || list.Publications[0].Handle != "sara" || !list.Publications[0].HasAvatar {
		t.Fatalf("queue = %+v", list)
	}
	if avatar := api.do(t, "GET", "/api/v1/admin/publications/profiles/u1/avatar", "", adminToken); avatar.Code != http.StatusOK ||
		avatar.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("avatar = %d %q", avatar.Code, avatar.Header().Get("Cache-Control"))
	}
	if response := api.do(t, "PATCH", "/api/v1/admin/publications/profiles/u1", `{"approved":true}`, adminToken); response.Code != http.StatusOK {
		t.Fatalf("approve profile = %d %s", response.Code, response.Body)
	}
	if !publications.decided["profile|u1"] {
		t.Fatal("approval not recorded")
	}

	reports := decode[struct {
		Reports []profileReportResponse `json:"reports"`
	}](t, api.do(t, "GET", "/api/v1/admin/profile-reports", "", adminToken))
	if len(reports.Reports) != 1 || reports.Reports[0].Reports != 2 {
		t.Fatalf("reports = %+v", reports)
	}
	expectError(t, api.do(t, "PATCH", "/api/v1/admin/profile-reports/u1", `{}`, adminToken), http.StatusBadRequest, "invalid_json")
	expectError(t, api.do(t, "PATCH", "/api/v1/admin/profile-reports/u9", `{"hide":false}`, adminToken), http.StatusNotFound, "not_found")
	if response := api.do(t, "PATCH", "/api/v1/admin/profile-reports/u1", `{"hide":true}`, adminToken); response.Code != http.StatusOK || !profiles.resolved["u1"] {
		t.Fatalf("hide = %d %v", response.Code, profiles.resolved)
	}
}
