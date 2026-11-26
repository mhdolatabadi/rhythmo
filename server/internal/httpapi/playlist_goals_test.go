package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/mhdolatabadi/rhythmo/server/internal/auth"
	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

// #276: a shared goal counts the playlist's real songs and members, shows
// no ranking, and only the owner or an admin sets it; occasion collections
// are each listener's own.
func TestPlaylistGoalsAndOccasions(t *testing.T) {
	pool := collabTestPool(t)
	ctx := context.Background()
	users := store.NewUsers(pool)
	tracks := store.NewTracks(pool)
	playlists := store.NewPlaylists(pool)
	tokens, _ := auth.NewTokens([]byte(strings.Repeat("k", auth.MinSecretBytes)), time.Hour)
	handler := NewHandler(Config{Playlists: NewPlaylistHandlers(playlists, tokens)})

	owner, _ := users.Create(ctx, "owner@example.com", "hash")
	member, _ := users.Create(ctx, "member@example.com", "hash")
	stranger, _ := users.Create(ctx, "stranger@example.com", "hash")
	ownerToken, _, _ := tokens.Issue(owner.ID)
	memberToken, _, _ := tokens.Issue(member.ID)
	strangerToken, _, _ := tokens.Issue(stranger.ID)
	track := func(ownerID, title string) store.Track {
		t.Helper()
		tr, err := tracks.Create(ctx, ownerID, store.NewTrack{Title: title, FileName: title + ".mp3", ContentType: "audio/mpeg", SizeBytes: 1})
		if err != nil {
			t.Fatal(err)
		}
		return tr
	}
	trip, _ := playlists.Create(ctx, owner.ID, "trip")
	_, _ = playlists.SetCollabToken(ctx, owner.ID, trip.ID, ptrTo("trip-join"))
	_, _ = playlists.Join(ctx, member.ID, "trip-join")
	a, b := track(owner.ID, "a"), track(owner.ID, "b")
	m := track(member.ID, "m")
	if err := playlists.ReplaceTracks(ctx, owner.ID, trip.ID, []string{a.ID, b.ID}); err != nil {
		t.Fatal(err)
	}
	if err := playlists.ReplaceTracks(ctx, member.ID, trip.ID, []string{a.ID, b.ID, m.ID}); err != nil {
		t.Fatal(err)
	}

	call := func(method, path, token, body string) *httptest.ResponseRecorder {
		request := httptest.NewRequest(method, path, bytes.NewReader([]byte(body)))
		request.Header.Set("Authorization", "Bearer "+token)
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		return response
	}
	get := func(token string) playlistResponse {
		t.Helper()
		response := call("GET", "/api/v1/playlists/"+trip.ID, token, "")
		var body playlistResponse
		if response.Code != 200 || json.Unmarshal(response.Body.Bytes(), &body) != nil {
			t.Fatalf("get = %d %s", response.Code, response.Body)
		}
		return body
	}
	goal := "/api/v1/playlists/" + trip.ID + "/goal"
	occasion := "/api/v1/playlists/" + trip.ID + "/occasion"

	if got := get(ownerToken); got.Goal != nil || *got.Contributors != 2 || *got.ViewerContribution != 2 {
		t.Fatalf("before a goal = %+v", got)
	}
	// Only the owner or an admin sets it; strangers don't see the playlist.
	expectError(t, call("PUT", goal, memberToken, `{"goal":10}`), 404, "not_found")
	expectError(t, call("PUT", goal, strangerToken, `{"goal":10}`), 404, "not_found")
	for _, body := range []string{`{"goal":0}`, `{"goal":1001}`, `{"goal":"ten"}`, `{"goal":5,"x":1}`} {
		expectError(t, call("PUT", goal, ownerToken, body), 400, "invalid_goal")
	}
	if r := call("PUT", goal, ownerToken, `{"goal":10}`); r.Code != 200 {
		t.Fatalf("set goal = %d %s", r.Code, r.Body)
	}
	got := get(memberToken)
	if got.Goal == nil || *got.Goal != 10 || got.TrackCount != 3 || *got.Contributors != 2 || *got.ViewerContribution != 1 {
		t.Fatalf("member sees %+v", got)
	}
	// Progress follows the real songs: a deleted track counts no more.
	if err := tracks.Delete(ctx, member.ID, m.ID); err != nil {
		t.Fatal(err)
	}
	if got := get(ownerToken); got.TrackCount != 2 || *got.Contributors != 1 {
		t.Fatalf("after a deletion = %d tracks, %d contributors", got.TrackCount, *got.Contributors)
	}
	// An admin may change it; clearing it removes it.
	if err := playlists.SetMemberRole(ctx, owner.ID, trip.ID, member.ID, store.RoleAdmin); err != nil {
		t.Fatal(err)
	}
	if r := call("PUT", goal, memberToken, `{"goal":null}`); r.Code != 200 {
		t.Fatalf("admin clears goal = %d", r.Code)
	}
	if get(ownerToken).Goal != nil {
		t.Fatal("goal was not cleared")
	}

	// Occasions are each listener's own.
	if r := call("PUT", occasion, memberToken, `{"occasion":"  سفر   تابستان "}`); r.Code != 200 || !strings.Contains(r.Body.String(), `"سفر تابستان"`) {
		t.Fatalf("member files = %d %s", r.Code, r.Body)
	}
	if got := get(memberToken).Occasion; got != "سفر تابستان" {
		t.Fatalf("member's occasion = %q", got)
	}
	if got := get(ownerToken).Occasion; got != "" {
		t.Fatalf("owner sees the member's occasion %q", got)
	}
	list := call("GET", "/api/v1/playlists", memberToken, "")
	if !strings.Contains(list.Body.String(), `"occasion":"سفر تابستان"`) {
		t.Fatalf("list = %s", list.Body)
	}
	expectError(t, call("PUT", occasion, strangerToken, `{"occasion":"x"}`), 404, "not_found")
	expectError(t, call("PUT", occasion, memberToken, `{"occasion":"`+strings.Repeat("ا", 41)+`"}`), 400, "invalid_occasion")
	if r := call("PUT", occasion, memberToken, `{"occasion":""}`); r.Code != 200 || get(memberToken).Occasion != "" {
		t.Fatalf("clear occasion = %d", r.Code)
	}
	if r := call("PUT", occasion, memberToken, `{"occasion":""}`); r.Code != 200 {
		t.Fatalf("clearing twice = %d", r.Code)
	}
	expectError(t, call("PUT", occasion, strangerToken, `{"occasion":""}`), 404, "not_found")

	// Deleting the playlist takes the collections' entries with it.
	_ = call("PUT", occasion, ownerToken, `{"occasion":"ورزش"}`)
	if err := playlists.Delete(ctx, owner.ID, trip.ID); err != nil {
		t.Fatal(err)
	}
	var left int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM playlist_occasions`).Scan(&left); err != nil || left != 0 {
		t.Fatalf("occasions left = %d, %v", left, err)
	}
}
