package httpapi

import (
	"context"
	"net/http"
	"strings"
	"testing"

	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

func (m *memoryUsers) SetDisplayName(_ context.Context, id, name string) (store.User, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	user, ok := m.users[id]
	if !ok {
		return store.User{}, store.ErrNotFound
	}
	user.DisplayName = name
	m.users[id] = user
	return user, nil
}

func TestUpdateDisplayName(t *testing.T) {
	api := newTestAPI(t)
	session := decode[sessionResponse](t, api.do(t, http.MethodPost, "/api/v1/auth/register",
		`{"email":"listener@example.com","password":"correct horse"}`, ""))

	expectError(t, api.do(t, http.MethodPatch, "/api/v1/me", `{"displayName":"x"}`, ""), http.StatusUnauthorized, "unauthorized")
	for _, bad := range []string{`{}`, `{"email":"x"}`, `not json`} {
		expectError(t, api.do(t, http.MethodPatch, "/api/v1/me", bad, session.Token), http.StatusBadRequest, "invalid_request")
	}
	for _, bad := range []string{
		"me@example.com", strings.Repeat("ن", maxDisplayNameRunes+1), `a‮b`, `a\u0007b`,
	} {
		expectError(t, api.do(t, http.MethodPatch, "/api/v1/me", `{"displayName":"`+bad+`"}`, session.Token),
			http.StatusBadRequest, "invalid_display_name")
	}

	response := api.do(t, http.MethodPatch, "/api/v1/me", `{"displayName":"  علی   رضا‌یی "}`, session.Token)
	if response.Code != http.StatusOK {
		t.Fatalf("set name = %d %s", response.Code, response.Body)
	}
	if got := decode[userResponse](t, response).DisplayName; got != "علی رضا‌یی" {
		t.Fatalf("display name = %q", got)
	}
	if got := decode[userResponse](t, api.do(t, http.MethodGet, "/api/v1/me", "", session.Token)).DisplayName; got != "علی رضا‌یی" {
		t.Fatalf("me display name = %q", got)
	}
	response = api.do(t, http.MethodPatch, "/api/v1/me", `{"displayName":"   "}`, session.Token)
	if got := decode[userResponse](t, response).DisplayName; response.Code != http.StatusOK || got != "" {
		t.Fatalf("clear name = %d %q", response.Code, got)
	}
}

func TestPublicOwnerNameNeverFallsBackToEmail(t *testing.T) {
	if got := publicOwnerName(""); got != anonymousOwnerName {
		t.Fatalf("empty name = %q", got)
	}
	if got := publicOwnerName(" نیما "); got != "نیما" {
		t.Fatalf("name = %q", got)
	}
}
