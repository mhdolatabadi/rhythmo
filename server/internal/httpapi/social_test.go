package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/mhdolatabadi/rhythmo/server/internal/auth"
	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

func TestNormalizeHandle(t *testing.T) {
	for raw, want := range map[string]string{
		"@Sara_1": "sara_1", " ali ": "ali", "": "",
	} {
		if got, ok := normalizeHandle(raw); !ok || got != want {
			t.Errorf("normalizeHandle(%q) = %q, %v", raw, got, ok)
		}
	}
	for _, bad := range []string{"ab", "1abc", "has space", "سارا", "admin", "rhythmo_team", strings.Repeat("a", 21), "a-b"} {
		if _, ok := normalizeHandle(bad); ok {
			t.Errorf("normalizeHandle(%q) passed", bad)
		}
	}
}

func TestNormalizeBio(t *testing.T) {
	if bio, ok := normalizeBio("  موسیقی‌دوست \n از تهران "); !ok || bio != "موسیقی‌دوست از تهران" {
		t.Fatalf("bio = %q, %v", bio, ok)
	}
	for _, bad := range []string{strings.Repeat("ب", 161), "me@example.com", "x‮y"} {
		if _, ok := normalizeBio(bad); ok {
			t.Errorf("normalizeBio(%q) passed", bad)
		}
	}
}

func TestFeedCursorRoundTrip(t *testing.T) {
	at := time.Date(2026, 11, 14, 1, 2, 3, 456000, time.UTC)
	cursor, ok := decodeFeedCursor(encodeFeedCursor(store.FeedItem{At: at, Kind: "like", ID: "abc"}))
	if !ok || !cursor.At.Equal(at) || cursor.Kind != "like" || cursor.ID != "abc" {
		t.Fatalf("cursor = %+v, %v", cursor, ok)
	}
	for _, bad := range []string{"!!", "eA", encodeFeedCursor(store.FeedItem{Kind: "other", ID: "x"})} {
		if _, ok := decodeFeedCursor(bad); ok {
			t.Errorf("decodeFeedCursor(%q) passed", bad)
		}
	}
}

func TestSocialAPI(t *testing.T) {
	pool := collabTestPool(t)
	ctx := context.Background()
	users := store.NewUsers(pool)
	playlists := store.NewPlaylists(pool)
	profiles := store.NewProfiles(pool)
	tokens, _ := auth.NewTokens([]byte(strings.Repeat("k", auth.MinSecretBytes)), time.Hour)
	followRate := NewRateLimiter(RateLimit{Requests: 3, Window: time.Hour}, 100)
	handler := NewHandler(Config{
		Social: NewSocialHandlers(profiles, tokens, followRate, nil, nil),
		Public: NewPublicPages(playlists, fixedPresigner{}, AnonymousLimits{}).WithProfiles(profiles),
	})

	alice, _ := users.Create(ctx, "alice@example.com", "hash")
	bob, _ := users.Create(ctx, "bob@example.com", "hash")
	aliceToken, _, _ := tokens.Issue(alice.ID)
	bobToken, _, _ := tokens.Issue(bob.ID)

	call := func(method, path, token string, body any) *httptest.ResponseRecorder {
		t.Helper()
		var reader *bytes.Reader
		if raw, ok := body.([]byte); ok {
			reader = bytes.NewReader(raw)
		} else if body != nil {
			encoded, _ := json.Marshal(body)
			reader = bytes.NewReader(encoded)
		} else {
			reader = bytes.NewReader(nil)
		}
		request := httptest.NewRequest(method, path, reader)
		if token != "" {
			request.Header.Set("Authorization", "Bearer "+token)
		}
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		return response
	}
	profile := func(handle string, public bool) map[string]any {
		return map[string]any{"handle": handle, "displayName": "نام " + strings.ToLower(strings.TrimPrefix(handle, "@")), "bio": "", "public": public, "hideActivity": false}
	}

	// The profile starts private and never shows the email.
	mine := call(http.MethodGet, "/api/v1/me/profile", aliceToken, nil)
	if mine.Code != http.StatusOK || strings.Contains(mine.Body.String(), "example.com") ||
		!strings.Contains(mine.Body.String(), `"public":false`) {
		t.Fatalf("own profile = %d %s", mine.Code, mine.Body)
	}
	if code := call(http.MethodPut, "/api/v1/me/profile", aliceToken, profile("admin", true)).Code; code != http.StatusBadRequest {
		t.Fatalf("reserved handle = %d", code)
	}
	if code := call(http.MethodPut, "/api/v1/me/profile", aliceToken, profile("", true)).Code; code != http.StatusBadRequest {
		t.Fatalf("public without handle = %d", code)
	}
	if code := call(http.MethodPut, "/api/v1/me/profile", aliceToken, profile("@Alice", true)).Code; code != http.StatusOK {
		t.Fatalf("set profile = %d", code)
	}
	if code := call(http.MethodPut, "/api/v1/me/profile", bobToken, profile("alice", false)).Code; code != http.StatusConflict {
		t.Fatalf("taken handle = %d", code)
	}
	if code := call(http.MethodPut, "/api/v1/me/profile", bobToken, profile("bob", true)).Code; code != http.StatusOK {
		t.Fatal("bob's profile")
	}

	// Avatars: only small images.
	png := append([]byte("\x89PNG\r\n\x1a\n"), make([]byte, 32)...)
	if code := call(http.MethodPut, "/api/v1/me/profile/avatar", aliceToken, []byte("not an image")).Code; code != http.StatusUnsupportedMediaType {
		t.Fatalf("text avatar = %d", code)
	}
	if code := call(http.MethodPut, "/api/v1/me/profile/avatar", aliceToken, make([]byte, maxAvatarBytes+1)).Code; code != http.StatusRequestEntityTooLarge {
		t.Fatalf("large avatar = %d", code)
	}
	if code := call(http.MethodPut, "/api/v1/me/profile/avatar", aliceToken, png).Code; code != http.StatusOK {
		t.Fatalf("png avatar = %d", code)
	}

	// A visitor sees the profile and its avatar.
	seen := call(http.MethodGet, "/api/v1/users/alice", "", nil)
	var shown profileResponse
	json.NewDecoder(seen.Body).Decode(&shown)
	if seen.Code != http.StatusOK || shown.DisplayName != "نام alice" || shown.AvatarURL == nil {
		t.Fatalf("visitor sees %d %+v", seen.Code, shown)
	}
	if avatar := call(http.MethodGet, *shown.AvatarURL, "", nil); avatar.Code != http.StatusOK || avatar.Header().Get("Content-Type") != "image/png" {
		t.Fatalf("avatar = %d %q", avatar.Code, avatar.Header().Get("Content-Type"))
	}
	page := call(http.MethodGet, "/u/alice", "", nil)
	if page.Code != http.StatusOK || !strings.Contains(page.Body.String(), "@alice") {
		t.Fatalf("public page = %d", page.Code)
	}
	if code := call(http.MethodGet, "/u/nobody", "", nil).Code; code != http.StatusNotFound {
		t.Fatalf("missing page = %d", code)
	}

	// Following is rate limited.
	if code := call(http.MethodPut, "/api/v1/users/alice/follow", bobToken, nil).Code; code != http.StatusNoContent {
		t.Fatalf("follow = %d", code)
	}
	call(http.MethodDelete, "/api/v1/users/alice/follow", bobToken, nil)
	call(http.MethodPut, "/api/v1/users/alice/follow", bobToken, nil)
	call(http.MethodPut, "/api/v1/users/alice/follow", bobToken, nil)
	if code := call(http.MethodPut, "/api/v1/users/alice/follow", bobToken, nil).Code; code != http.StatusTooManyRequests {
		t.Fatalf("fourth follow = %d", code)
	}
	if code := call(http.MethodGet, "/api/v1/users/alice", bobToken, nil); !strings.Contains(code.Body.String(), `"isFollowing":true`) {
		t.Fatalf("bob follows alice: %s", code.Body)
	}

	// The feed shows alice's new public playlist, paged.
	for i := 0; i < 3; i++ {
		created, _ := playlists.Create(ctx, alice.ID, "mix")
		public := true
		if _, err := playlists.Share(ctx, alice.ID, created.ID, "token-"+created.ID, &public, true); err != nil {
			t.Fatal(err)
		}
	}
	first := call(http.MethodGet, "/api/v1/feed?limit=2", bobToken, nil)
	var feed struct {
		Items []feedItemResponse `json:"items"`
		Next  *string            `json:"next"`
	}
	json.NewDecoder(first.Body).Decode(&feed)
	if first.Code != http.StatusOK || len(feed.Items) != 2 || feed.Next == nil || feed.Items[0].ActorHandle != "alice" {
		t.Fatalf("feed = %d %+v", first.Code, feed)
	}
	second := call(http.MethodGet, "/api/v1/feed?limit=2&before="+*feed.Next, bobToken, nil)
	feed.Items, feed.Next = nil, nil
	json.NewDecoder(second.Body).Decode(&feed)
	if len(feed.Items) != 1 || feed.Next != nil {
		t.Fatalf("second page = %+v", feed)
	}
	if code := call(http.MethodGet, "/api/v1/feed?before=bad!", bobToken, nil).Code; code != http.StatusBadRequest {
		t.Fatalf("bad cursor = %d", code)
	}

	// Reports and blocks.
	if code := call(http.MethodPost, "/api/v1/users/alice/report", bobToken, map[string]any{"reason": "nonsense"}).Code; code != http.StatusBadRequest {
		t.Fatalf("bad reason = %d", code)
	}
	if code := call(http.MethodPost, "/api/v1/users/alice/report", bobToken, map[string]any{"reason": "spam"}).Code; code != http.StatusNoContent {
		t.Fatalf("report = %d", code)
	}
	if code := call(http.MethodPut, "/api/v1/users/bob/block", aliceToken, nil).Code; code != http.StatusNoContent {
		t.Fatalf("block = %d", code)
	}
	if code := call(http.MethodGet, "/api/v1/users/alice", bobToken, nil).Code; code != http.StatusNotFound {
		t.Fatalf("blocked viewer = %d", code)
	}
	if code := call(http.MethodGet, "/api/v1/feed", bobToken, nil); strings.Contains(code.Body.String(), "alice") {
		t.Fatalf("blocked feed = %s", code.Body)
	}
	blocked := call(http.MethodGet, "/api/v1/me/blocked", aliceToken, nil)
	if !strings.Contains(blocked.Body.String(), `"handle":"bob"`) {
		t.Fatalf("blocked list = %s", blocked.Body)
	}

	// Private again: gone for visitors.
	call(http.MethodPut, "/api/v1/me/profile", aliceToken, profile("alice", false))
	if code := call(http.MethodGet, "/api/v1/users/alice", "", nil).Code; code != http.StatusNotFound {
		t.Fatalf("private profile = %d", code)
	}
	if code := call(http.MethodGet, "/api/v1/me/profile", "", nil).Code; code != http.StatusUnauthorized {
		t.Fatalf("anonymous own profile = %d", code)
	}
}
