package httpapi

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/mhdolatabadi/rhythmo/server/internal/auth"
	"github.com/mhdolatabadi/rhythmo/server/internal/store"
	"golang.org/x/crypto/bcrypt"
)

type fakeAdminStore struct {
	user  store.User
	actor string
	fail  bool
	calls int
}

func (m *fakeAdminStore) ListAccounts(_ context.Context, _ string, _, _ int) ([]store.User, bool, error) {
	m.calls++
	if m.fail {
		return nil, false, errors.New("unavailable")
	}
	return []store.User{m.user}, false, nil
}

func (m *fakeAdminStore) SetVerification(_ context.Context, id, actor string, verified bool) (store.User, error) {
	m.calls++
	if m.fail {
		return store.User{}, errors.New("unavailable")
	}
	if id != m.user.ID {
		return store.User{}, store.ErrNotFound
	}
	m.actor = actor
	m.user.Verified = verified
	return m.user, nil
}

func (m *fakeAdminStore) SetStorageQuota(_ context.Context, id, actor string, bytes, fallback int64) (store.User, error) {
	if m.fail {
		return store.User{}, errors.New("unavailable")
	}
	if id != m.user.ID {
		return store.User{}, store.ErrNotFound
	}
	current := fallback
	if m.user.StorageQuotaBytes != nil {
		current = *m.user.StorageQuotaBytes
	}
	if bytes < current {
		return store.User{}, store.ErrQuotaDecrease
	}
	m.user.StorageQuotaBytes = &bytes
	m.actor = actor
	return m.user, nil
}

func TestAdminAuthorizationAndVerification(t *testing.T) {
	api := newTestAPI(t)
	admin, _ := api.users.Create(context.Background(), "admin@example.com", "hash")
	member, _ := api.users.Create(context.Background(), "member@example.com", "hash")
	adminToken, _, _ := api.tokens.Issue(admin.ID)
	memberToken, _, _ := api.tokens.Issue(member.ID)
	handlers, err := NewAuthHandlers(api.users, auth.Passwords{Cost: bcrypt.MinCost}, api.tokens, AuthRateLimiters{})
	if err != nil {
		t.Fatal(err)
	}
	handlers.WithAdmins([]string{" ADMIN@example.com "})
	storage := &fakeAdminStore{user: member}
	api.handler = NewHandler(Config{Auth: handlers, Admin: NewAdminHandlers(handlers, storage)})
	for _, path := range []string{"/api/v1/admin/accounts", "/api/v1/admin/accounts/" + member.ID + "/verification"} {
		method, body := "GET", ""
		if strings.HasSuffix(path, "/verification") {
			method, body = "PATCH", `{"verified":true}`
		}
		expectError(t, api.do(t, method, path, body, ""), http.StatusUnauthorized, "unauthorized")
		expectError(t, api.do(t, method, path, body, memberToken), http.StatusForbidden, "admin_required")
	}
	if storage.calls != 0 {
		t.Fatal("unauthorized callers reached account storage")
	}
	me := decode[userResponse](t, api.do(t, "GET", "/api/v1/me", "", adminToken))
	if !me.IsAdmin || me.Verified {
		t.Fatalf("unexpected admin identity: %+v", me)
	}
	result := api.do(t, "PATCH", "/api/v1/admin/accounts/"+member.ID+"/verification", `{"verified":true}`, adminToken)
	if result.Code != http.StatusOK || !decode[adminAccountResponse](t, result).Verified || storage.actor != admin.ID {
		t.Fatalf("verification failed: %s", result.Body)
	}
	result = api.do(t, "PATCH", "/api/v1/admin/accounts/"+member.ID+"/verification", `{"verified":false}`, adminToken)
	if result.Code != http.StatusOK || decode[adminAccountResponse](t, result).Verified {
		t.Fatalf("revoke failed: %s", result.Body)
	}
	for _, body := range []string{`{}`, `{"verified":null}`, `{"verified":true,"isAdmin":true}`, `{"verified":true} {}`} {
		expectError(t, api.do(t, "PATCH", "/api/v1/admin/accounts/"+member.ID+"/verification", body, adminToken), http.StatusBadRequest, "invalid_json")
	}
	expectError(t, api.do(t, "GET", "/api/v1/admin/accounts?offset=-1", "", adminToken), http.StatusBadRequest, "invalid_offset")
	expectError(t, api.do(t, "GET", "/api/v1/admin/accounts?offset=100001", "", adminToken), http.StatusBadRequest, "invalid_offset")
	expectError(t, api.do(t, "PATCH", "/api/v1/admin/accounts/missing/verification", `{"verified":true}`, adminToken), http.StatusNotFound, "account_not_found")
	storage.fail = true
	expectError(t, api.do(t, "PATCH", "/api/v1/admin/accounts/"+member.ID+"/verification", `{"verified":true}`, adminToken), http.StatusInternalServerError, "internal_error")
	storage.fail = false
	handlers.WithAdmins(nil)
	expectError(t, api.do(t, "GET", "/api/v1/admin/accounts", "", adminToken), http.StatusForbidden, "admin_required")
	handlers.WithAdmins([]string{admin.Email})
	delete(api.users.users, admin.ID)
	expectError(t, api.do(t, "GET", "/api/v1/admin/accounts", "", adminToken), http.StatusUnauthorized, "unauthorized")
}

func TestVerificationInSessionAndMe(t *testing.T) {
	api := newTestAPI(t)
	response := api.do(t, "POST", "/api/v1/auth/register", `{"email":"verified@example.com","password":"long-password"}`, "")
	session := decode[sessionResponse](t, response)
	user := api.users.users[session.User.ID]
	user.Verified = true
	now := time.Now()
	user.VerifiedAt = &now
	api.users.users[user.ID] = user
	me := decode[userResponse](t, api.do(t, "GET", "/api/v1/me", "", session.Token))
	if !me.Verified || me.IsAdmin {
		t.Fatalf("verification identity lost: %+v", me)
	}
	login := decode[sessionResponse](t, api.do(t, "POST", "/api/v1/auth/login", `{"email":"verified@example.com","password":"long-password"}`, ""))
	if !login.User.Verified {
		t.Fatal("login omitted verification")
	}
}

type fakeAdminPlaylists struct {
	token, actor string
	hidden       bool
	deleted      bool
	calls        int
}

func (f *fakeAdminPlaylists) DeleteShared(_ context.Context, token, actor string) error {
	f.calls++
	if token != f.token || f.deleted {
		return store.ErrNotFound
	}
	f.actor, f.deleted = actor, true
	return nil
}

func (f *fakeAdminPlaylists) SetPopularHidden(_ context.Context, token, actor string, hidden bool) error {
	f.calls++
	if token != f.token {
		return store.ErrNotFound
	}
	f.actor, f.hidden = actor, hidden
	return nil
}

func TestAdminHidesPopularPlaylist(t *testing.T) {
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
	share, _ := newShareToken()
	other, _ := newShareToken()
	playlists := &fakeAdminPlaylists{token: share}
	api.handler = NewHandler(Config{Auth: handlers,
		Admin: NewAdminHandlers(handlers, &fakeAdminStore{}).WithPlaylists(playlists)})
	path := "/api/v1/admin/public-playlists/" + share

	expectError(t, api.do(t, "PATCH", path, `{"hidden":true}`, ""), http.StatusUnauthorized, "unauthorized")
	expectError(t, api.do(t, "PATCH", path, `{"hidden":true}`, memberToken), http.StatusForbidden, "admin_required")
	expectError(t, api.do(t, "DELETE", path, "", ""), http.StatusUnauthorized, "unauthorized")
	expectError(t, api.do(t, "DELETE", path, "", memberToken), http.StatusForbidden, "admin_required")
	if playlists.calls != 0 {
		t.Fatal("a non-admin reached playlist storage")
	}
	for _, hidden := range []bool{true, false} {
		body := `{"hidden":false}`
		if hidden {
			body = `{"hidden":true}`
		}
		result := api.do(t, "PATCH", path, body, adminToken)
		if result.Code != http.StatusOK || playlists.hidden != hidden || playlists.actor != admin.ID {
			t.Fatalf("hidden=%v: %d %s", hidden, result.Code, result.Body)
		}
	}
	for _, body := range []string{`{}`, `{"hidden":null}`, `{"hidden":true,"delete":true}`, `{"hidden":true} {}`} {
		expectError(t, api.do(t, "PATCH", path, body, adminToken), http.StatusBadRequest, "invalid_json")
	}
	expectError(t, api.do(t, "PATCH", "/api/v1/admin/public-playlists/"+other, `{"hidden":true}`, adminToken), http.StatusNotFound, "playlist_not_found")
	expectError(t, api.do(t, "PATCH", "/api/v1/admin/public-playlists/bad", `{"hidden":true}`, adminToken), http.StatusNotFound, "playlist_not_found")

	expectError(t, api.do(t, "DELETE", "/api/v1/admin/public-playlists/bad", "", adminToken), http.StatusNotFound, "playlist_not_found")
	if result := api.do(t, "DELETE", path, "", adminToken); result.Code != http.StatusNoContent || !playlists.deleted || playlists.actor != admin.ID {
		t.Fatalf("delete: %d %s", result.Code, result.Body)
	}
	expectError(t, api.do(t, "DELETE", path, "", adminToken), http.StatusNotFound, "playlist_not_found")
}

func TestAdminAccountQuota(t *testing.T) {
	api := newTestAPI(t)
	admin, _ := api.users.Create(context.Background(), "admin@example.com", "hash")
	member, _ := api.users.Create(context.Background(), "member@example.com", "hash")
	adminToken, _, _ := api.tokens.Issue(admin.ID)
	memberToken, _, _ := api.tokens.Issue(member.ID)
	handlers, err := NewAuthHandlers(api.users, auth.Passwords{Cost: bcrypt.MinCost}, api.tokens, AuthRateLimiters{})
	if err != nil {
		t.Fatal(err)
	}
	handlers.WithAdmins([]string{"admin@example.com"})
	storage := &fakeAdminStore{user: member}
	api.handler = NewHandler(Config{Auth: handlers, Admin: NewAdminHandlers(handlers, storage)})
	path := "/api/v1/admin/accounts/" + member.ID + "/storage-quota"
	expectError(t, api.do(t, "PATCH", path, `{"bytes":2147483648}`, ""), http.StatusUnauthorized, "unauthorized")
	expectError(t, api.do(t, "PATCH", path, `{"bytes":2147483648}`, memberToken), http.StatusForbidden, "admin_required")
	for _, body := range []string{`{"bytes":-1}`, `{"bytes":1099511627777}`, `{"bytes":0}`} {
		expectError(t, api.do(t, "PATCH", path, body, adminToken), http.StatusBadRequest, "invalid_storage_quota")
	}
	response := api.do(t, "PATCH", path, `{"bytes":2147483648}`, adminToken)
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), `"storageQuotaBytes":2147483648`) || storage.actor != admin.ID {
		t.Fatalf("quota = %d %s", response.Code, response.Body)
	}
	expectError(t, api.do(t, "PATCH", path, `{"bytes":1073741824}`, adminToken), http.StatusConflict, "quota_must_increase")
}

type fakeStorageRequests struct {
	*fakeAdminStore
	open     *store.StorageRequest
	decided  string
	approved bool
	granted  int64
}

func (f *fakeStorageRequests) RequestStorage(_ context.Context, accountID string, bytes int64, reason string) (store.StorageRequest, error) {
	if f.open != nil {
		return store.StorageRequest{}, store.ErrStorageRequestOpen
	}
	f.open = &store.StorageRequest{ID: "r1", AccountID: accountID, RequestedBytes: bytes, Reason: reason, Status: store.StorageRequestPending, CreatedAt: time.Now()}
	return *f.open, nil
}

func (f *fakeStorageRequests) LatestStorageRequest(context.Context, string) (store.StorageRequest, error) {
	if f.open == nil {
		return store.StorageRequest{}, store.ErrNotFound
	}
	return *f.open, nil
}

func (f *fakeStorageRequests) PendingStorageRequests(context.Context, int, int64) ([]store.PendingStorageRequest, error) {
	if f.open == nil || f.open.Status != store.StorageRequestPending {
		return nil, nil
	}
	return []store.PendingStorageRequest{{StorageRequest: *f.open, Email: "member@example.com", QuotaBytes: 1 << 30}}, nil
}

func (f *fakeStorageRequests) DecideStorageRequest(_ context.Context, id, actor string, approve bool, bytes int64, reason string, _ int64) (store.StorageRequest, error) {
	if f.open == nil || f.open.ID != id || f.open.Status != store.StorageRequestPending {
		return store.StorageRequest{}, store.ErrNotPending
	}
	f.decided, f.approved, f.granted = actor, approve, bytes
	f.open.Status = store.StorageRequestRejected
	if approve {
		f.open.Status = store.StorageRequestApproved
	}
	return *f.open, nil
}

func TestStorageRequests(t *testing.T) {
	api := newTestAPI(t)
	admin, _ := api.users.Create(context.Background(), "admin@example.com", "hash")
	member, _ := api.users.Create(context.Background(), "member@example.com", "hash")
	adminToken, _, _ := api.tokens.Issue(admin.ID)
	memberToken, _, _ := api.tokens.Issue(member.ID)
	handlers, err := NewAuthHandlers(api.users, auth.Passwords{Cost: bcrypt.MinCost}, api.tokens, AuthRateLimiters{})
	if err != nil {
		t.Fatal(err)
	}
	handlers.WithAdmins([]string{"admin@example.com"})
	requests := &fakeStorageRequests{fakeAdminStore: &fakeAdminStore{user: member}}
	api.handler = NewHandler(Config{Auth: handlers, Admin: NewAdminHandlers(handlers, requests).WithQuota(1 << 30)})
	mine := "/api/v1/me/storage-request"
	expectError(t, api.do(t, "GET", mine, "", ""), http.StatusUnauthorized, "unauthorized")
	if result := api.do(t, "GET", mine, "", memberToken); result.Code != http.StatusNoContent {
		t.Fatalf("no request: %d %s", result.Code, result.Body)
	}
	for _, body := range []string{`{"bytes":1073741824}`, `{"bytes":0}`, `{"bytes":1099511627777}`, `{"bytes":5368709120,"reason":"a\u0007b"}`} {
		expectError(t, api.do(t, "POST", mine, body, memberToken), http.StatusBadRequest, "invalid_storage_request")
	}
	result := api.do(t, "POST", mine, `{"bytes":5368709120,"reason":"  آرشیو   کنسرت‌ها "}`, memberToken)
	if result.Code != http.StatusCreated || requests.open.Reason != "آرشیو کنسرت‌ها" || requests.open.AccountID != member.ID {
		t.Fatalf("request: %d %s", result.Code, result.Body)
	}
	expectError(t, api.do(t, "POST", mine, `{"bytes":5368709120}`, memberToken), http.StatusConflict, "request_open")
	if result := api.do(t, "GET", mine, "", memberToken); result.Code != http.StatusOK || !strings.Contains(result.Body.String(), `"status":"pending"`) {
		t.Fatalf("mine: %d %s", result.Code, result.Body)
	}

	queue := "/api/v1/admin/storage-requests"
	expectError(t, api.do(t, "GET", queue, "", memberToken), http.StatusForbidden, "admin_required")
	if result := api.do(t, "GET", queue, "", adminToken); result.Code != http.StatusOK || !strings.Contains(result.Body.String(), `"email":"member@example.com"`) {
		t.Fatalf("queue: %d %s", result.Code, result.Body)
	}
	expectError(t, api.do(t, "PATCH", queue+"/r1", `{"approved":true,"bytes":5368709120}`, memberToken), http.StatusForbidden, "admin_required")
	expectError(t, api.do(t, "PATCH", queue+"/r1", `{}`, adminToken), http.StatusBadRequest, "invalid_json")
	expectError(t, api.do(t, "PATCH", queue+"/r1", `{"approved":true}`, adminToken), http.StatusBadRequest, "invalid_storage_request")
	if result := api.do(t, "PATCH", queue+"/r1", `{"approved":true,"bytes":5368709120}`, adminToken); result.Code != http.StatusOK || requests.decided != admin.ID || !requests.approved || requests.granted != 5368709120 {
		t.Fatalf("approve: %d %s", result.Code, result.Body)
	}
	expectError(t, api.do(t, "PATCH", queue+"/r1", `{"approved":false}`, adminToken), http.StatusConflict, "not_pending")
}
