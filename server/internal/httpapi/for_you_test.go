package httpapi

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/mhdolatabadi/rhythmo/server/internal/auth"
	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

type forYouMemory struct {
	tracks map[string][]store.Track
	plays  map[string][]store.PlayRecord
}

func (m forYouMemory) ListForOwner(_ context.Context, owner string) ([]store.Track, error) {
	return m.tracks[owner], nil
}

func (m forYouMemory) OwnPlays(_ context.Context, user string) ([]store.PlayRecord, error) {
	return m.plays[user], nil
}

func TestForYouAPI(t *testing.T) {
	now := time.Date(2026, 11, 13, 9, 0, 0, 0, time.UTC)
	tokens, _ := auth.NewTokens([]byte(strings.Repeat("k", auth.MinSecretBytes)), time.Hour)
	alice, _, _ := tokens.Issue("alice")
	bob, _, _ := tokens.Issue("bob")
	artist := "Kayhan"
	data := forYouMemory{tracks: map[string][]store.Track{}, plays: map[string][]store.PlayRecord{}}
	for i := range 25 {
		data.tracks["alice"] = append(data.tracks["alice"], store.Track{
			ID: fmt.Sprintf("a%02d", i), Title: "song", Artist: &artist, Status: store.TrackReady,
			StorageKey: "users/alice/secret", CreatedAt: now.Add(-time.Duration(i*5) * 24 * time.Hour)})
	}
	data.plays["alice"] = []store.PlayRecord{{TrackID: "a03", PlayedAt: now.Add(-time.Hour)}}
	handlers := NewForYouHandlers(data, tokens, NewRateLimiter(RateLimit{Requests: 100, Window: time.Hour}, 10))
	handlers.now = func() time.Time { return now }
	handler := NewHandler(Config{ForYou: handlers})
	call := func(method, path, token, body string) *httptest.ResponseRecorder {
		request := httptest.NewRequest(method, path, strings.NewReader(body))
		if token != "" {
			request.Header.Set("Authorization", "Bearer "+token)
		}
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		return response
	}

	expectError(t, call("GET", "/api/v1/for-you", "", ""), 401, "unauthorized")
	expectError(t, call("POST", "/api/v1/radio", "", `{"seeds":["a01"]}`), 401, "unauthorized")

	response := call("GET", "/api/v1/for-you", alice, "")
	var got forYouResponse
	if response.Code != 200 || json.Unmarshal(response.Body.Bytes(), &got) != nil {
		t.Fatalf("for you = %d %s", response.Code, response.Body)
	}
	if strings.Contains(response.Body.String(), "users/alice") {
		t.Fatal("a storage key leaked")
	}
	keys := []string{}
	for _, l := range got.Smart {
		keys = append(keys, l.Key)
	}
	if fmt.Sprint(keys) != "[most-played recently-added not-heard]" || got.Smart[0].Tracks[0].ID != "a03" {
		t.Fatalf("smart = %v", keys)
	}
	if len(got.Mixes) != 1 || len(got.Mixes[0].Tracks) < 20 || got.Day != "2026-11-13" {
		t.Fatalf("mixes = %d for %s", len(got.Mixes), got.Day)
	}

	// Bob's library is empty, and he never sees Alice's.
	response = call("GET", "/api/v1/for-you", bob, "")
	if response.Code != 200 || strings.Contains(response.Body.String(), "a03") {
		t.Fatalf("bob = %d %s", response.Code, response.Body)
	}

	response = call("POST", "/api/v1/radio", alice, `{"seeds":["a01"],"exclude":["a02"]}`)
	var radio struct {
		Tracks []trackResponse `json:"tracks"`
	}
	if response.Code != 200 || json.Unmarshal(response.Body.Bytes(), &radio) != nil || len(radio.Tracks) != 20 {
		t.Fatalf("radio = %d %s", response.Code, response.Body)
	}
	for _, tr := range radio.Tracks {
		if tr.ID == "a01" || tr.ID == "a02" {
			t.Fatalf("radio repeated %s", tr.ID)
		}
	}
	if response := call("POST", "/api/v1/radio", bob, `{"seeds":["a01"]}`); response.Code != 200 || strings.Contains(response.Body.String(), "a0") {
		t.Fatalf("bob's radio = %d %s", response.Code, response.Body)
	}
	for _, body := range []string{`{}`, `{"seeds":[]}`, `{"seeds":["a"],"other":1}`, `not json`} {
		expectError(t, call("POST", "/api/v1/radio", alice, body), 400, "invalid_radio")
	}
}
