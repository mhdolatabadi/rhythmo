package httpapi

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/mhdolatabadi/rhythmo/server/internal/auth"
	"github.com/mhdolatabadi/rhythmo/server/internal/balearchive"
	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

type fakeBaleArchive struct {
	calls   int
	before  int64
	topic   string
	session int
}

func (f *fakeBaleArchive) Preview(_ context.Context, before int64) (balearchive.Page, error) {
	f.calls++
	f.before = before
	return balearchive.Page{Entries: []balearchive.Entry{}, NextBefore: 123}, nil
}
func (f *fakeBaleArchive) Submit(_ context.Context, _, _ string, _ int64, topic string, session int) (store.BotImport, error) {
	f.calls++
	f.topic = topic
	f.session = session
	return store.BotImport{ID: "job", State: store.ImportQueued}, nil
}
func (f *fakeBaleArchive) Recent(context.Context, string) ([]store.BaleArchiveImport, error) {
	f.calls++
	return []store.BaleArchiveImport{{ID: "job", MessageID: "-123", Date: 1234, Title: "فاطمیه؛ جلسه اول", Topic: "فاطمیه", Session: 1, State: store.ImportDone}}, nil
}
func (f *fakeBaleArchive) Catalog(context.Context, string) (store.BaleCatalog, error) {
	f.calls++
	return store.BaleCatalog{Scan: store.BaleScan{State: "scanning"}, Topics: []store.BaleTopic{}}, nil
}
func (f *fakeBaleArchive) RefreshCatalog(context.Context) error { f.calls++; return nil }
func (f *fakeBaleArchive) ImportTopic(_ context.Context, actor, key string) error {
	f.calls++
	f.topic = key
	if key == "unknown" {
		return store.ErrNotFound
	}
	return nil
}
func TestBaleAdminAuthorizationAndInput(t *testing.T) {
	api := newTestAPI(t)
	admin, _ := api.users.Create(context.Background(), "admin@example.com", "hash")
	member, _ := api.users.Create(context.Background(), "member@example.com", "hash")
	at, _, _ := api.tokens.Issue(admin.ID)
	mt, _, _ := api.tokens.Issue(member.ID)
	h, err := NewAuthHandlers(api.users, auth.Passwords{}, api.tokens, AuthRateLimiters{})
	if err != nil {
		t.Fatal(err)
	}
	h.WithAdmins([]string{admin.Email})
	source := &fakeBaleArchive{}
	api.handler = NewHandler(Config{Admin: NewAdminHandlers(h, &fakeAdminStore{}).WithBaleArchive(source, nil)})
	for _, tc := range []struct{ method, path, body string }{
		{"GET", "/api/v1/admin/bale-archive/preview", ""}, {"GET", "/api/v1/admin/bale-archive/imports", ""},
		{"POST", "/api/v1/admin/bale-archive/import", `{"id":"-123","date":1234,"topic":"فاطمیه","session":1}`},
		{"GET", "/api/v1/admin/bale-archive/topics", ""},
		{"POST", "/api/v1/admin/bale-archive/scan", ""},
		{"POST", "/api/v1/admin/bale-archive/topics/import", `{"key":"موضوع"}`},
	} {
		expectError(t, api.do(t, tc.method, tc.path, tc.body, ""), http.StatusUnauthorized, "unauthorized")
		expectError(t, api.do(t, tc.method, tc.path, tc.body, mt), http.StatusForbidden, "admin_required")
	}
	if source.calls != 0 {
		t.Fatal("unauthorized request reached source")
	}
	r := api.do(t, "GET", "/api/v1/admin/bale-archive/preview?before=1234", "", at)
	if r.Code != http.StatusOK || source.before != 1234 || r.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("preview %s", r.Body)
	}
	r = api.do(t, "POST", "/api/v1/admin/bale-archive/import", `{"id":"-123","date":1234,"topic":"فاطمیه","session":1}`, at)
	if r.Code != http.StatusAccepted || source.topic != "فاطمیه" || source.session != 1 {
		t.Fatalf("submit %s", r.Body)
	}
	calls := source.calls
	for _, body := range []string{`{}`, `{"id":"https://evil","date":1234}`, `{"id":"123","date":1234,"url":"https://evil"}`, `{"id":"123","date":1234} {}`, `{"id":"123","date":1234,"session":-1}`} {
		r = api.do(t, "POST", "/api/v1/admin/bale-archive/import", body, at)
		if r.Code != 400 {
			t.Errorf("%s -> %d", body, r.Code)
		}
	}
	for _, cursor := range []string{"-1", "nope", "9007199254740991"} {
		expectError(t, api.do(t, "GET", "/api/v1/admin/bale-archive/preview?before="+cursor, "", at), 400, "invalid_cursor")
	}
	if source.calls != calls {
		t.Fatal("invalid input reached source")
	}
	r = api.do(t, "GET", "/api/v1/admin/bale-archive/topics", "", at)
	if r.Code != 200 {
		t.Fatal(r.Body)
	}
	r = api.do(t, "POST", "/api/v1/admin/bale-archive/topics/import", `{"key":"موضوع"}`, at)
	if r.Code != 202 || source.topic != "موضوع" {
		t.Fatal(r.Body)
	}
	expectError(t, api.do(t, "POST", "/api/v1/admin/bale-archive/topics/import", `{"key":"unknown"}`, at), 404, "topic_not_found")
	for _, body := range []string{`{}`, `{"key":""}`, `{"key":"موضوع","ownerId":"other"}`, `{"key":"موضوع"} {}`} {
		expectError(t, api.do(t, "POST", "/api/v1/admin/bale-archive/topics/import", body, at), 400, "invalid_topic")
	}

	// Import status is independent of preview throttling and includes the
	// persisted source/topic metadata needed to restore a reopened screen.
	api.handler = NewHandler(Config{Admin: NewAdminHandlers(h, &fakeAdminStore{}).WithBaleArchive(source, NewRateLimiter(RateLimit{Requests: 1, Window: time.Minute}, 10))})
	r = api.do(t, "GET", "/api/v1/admin/bale-archive/preview", "", at)
	if r.Code != http.StatusOK {
		t.Fatal(r.Body)
	}
	expectError(t, api.do(t, "GET", "/api/v1/admin/bale-archive/preview", "", at), 429, "rate_limited")
	r = api.do(t, "GET", "/api/v1/admin/bale-archive/imports", "", at)
	result := decode[struct {
		Imports []store.BaleArchiveImport `json:"imports"`
	}](t, r)
	if r.Code != 200 || len(result.Imports) != 1 || result.Imports[0].Topic != "فاطمیه" || result.Imports[0].Session != 1 || result.Imports[0].MessageID != "-123" {
		t.Fatalf("lost archive metadata: %s", r.Body)
	}

}
