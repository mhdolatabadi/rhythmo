package httpapi

import (
	"context"
	"github.com/mhdolatabadi/rhythmo/server/internal/auth"
	"github.com/mhdolatabadi/rhythmo/server/internal/store"
	"strings"
	"testing"
)

type feedbackMemory struct {
	fakeAdminStore
	items      []store.Feedback
	resolvedBy string
}

func (f *feedbackMemory) CreateFeedback(_ context.Context, user, kind, subject, body string) error {
	f.items = append(f.items, store.Feedback{ID: "one", Email: user, Kind: kind, Subject: subject, Body: body})
	return nil
}
func (f *feedbackMemory) OpenFeedback(context.Context) ([]store.Feedback, error) { return f.items, nil }
func (f *feedbackMemory) ResolveFeedback(_ context.Context, id, actor string) error {
	if id != "one" {
		return store.ErrNotFound
	}
	f.resolvedBy = actor
	f.items = []store.Feedback{}
	return nil
}
func TestFeedbackSubmissionAndAdminAccess(t *testing.T) {
	api := newTestAPI(t)
	ctx := context.Background()
	admin, _ := api.users.Create(ctx, "admin@example.com", "hash")
	member, _ := api.users.Create(ctx, "member@example.com", "hash")
	at, _, _ := api.tokens.Issue(admin.ID)
	mt, _, _ := api.tokens.Issue(member.ID)
	h, err := NewAuthHandlers(api.users, auth.Passwords{}, api.tokens, AuthRateLimiters{})
	if err != nil {
		t.Fatal(err)
	}
	h.WithAdmins([]string{admin.Email})
	storage := &feedbackMemory{}
	api.handler = NewHandler(Config{Auth: h, Admin: NewAdminHandlers(h, storage)})
	expectError(t, api.do(t, "POST", "/api/v1/feedback", `{}`, ""), 401, "unauthorized")
	for _, path := range []string{"/api/v1/admin/feedback", "/api/v1/admin/feedback/one/resolve"} {
		method := "GET"
		if strings.Contains(path, "resolve") {
			method = "POST"
		}
		expectError(t, api.do(t, method, path, "", mt), 403, "admin_required")
	}
	for _, body := range []string{`{}`, `{"kind":"other","subject":"a","body":"b"}`, `{"kind":"bug","subject":" ","body":"b"}`, `{"kind":"bug","subject":"a","body":"b","extra":1}`, `{"kind":"bug","subject":"a","body":"b"} {}`} {
		expectError(t, api.do(t, "POST", "/api/v1/feedback", body, mt), 400, "invalid_feedback")
	}
	for _, kind := range []string{"bug", "feature", "message"} {
		r := api.do(t, "POST", "/api/v1/feedback", `{"kind":"`+kind+`","subject":" عنوان ","body":"متن"}`, mt)
		if r.Code != 201 {
			t.Fatalf("submit: %d %s", r.Code, r.Body)
		}
	}
	if len(storage.items) != 3 || storage.items[0].Subject != "عنوان" || storage.items[0].Email != member.ID {
		t.Fatal(storage.items)
	}
	if r := api.do(t, "GET", "/api/v1/admin/feedback", "", at); r.Code != 200 || !strings.Contains(r.Body.String(), "عنوان") {
		t.Fatal(r.Body)
	}
	if r := api.do(t, "POST", "/api/v1/admin/feedback/one/resolve", "", at); r.Code != 204 || storage.resolvedBy != admin.ID {
		t.Fatal(r.Body)
	}
	expectError(t, api.do(t, "POST", "/api/v1/admin/feedback/missing/resolve", "", at), 404, "not_found")
	for i := 0; i < 2; i++ {
		api.do(t, "POST", "/api/v1/feedback", `{}`, mt)
	}
	if r := api.do(t, "POST", "/api/v1/feedback", `{}`, mt); r.Code != 429 {
		t.Fatalf("rate limit: %d", r.Code)
	}
}
