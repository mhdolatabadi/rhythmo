package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/mhdolatabadi/rhythmo/server/internal/auth"
	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

// collabTestPool connects to TEST_DATABASE_URL, a disposable database, and
// works in a schema of its own, so it can't race the store package's tests
// that wipe the same database. The test is skipped without it.
func collabTestPool(t *testing.T) *pgxpool.Pool {
	t.Helper()
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("TEST_DATABASE_URL is not set")
	}
	ctx := context.Background()
	const schema = "rhythmo_httpapi_test"
	admin, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	_, err = admin.Exec(ctx, "DROP SCHEMA IF EXISTS "+schema+" CASCADE; CREATE SCHEMA "+schema)
	admin.Close()
	if err != nil {
		t.Fatal(err)
	}
	config, err := pgxpool.ParseConfig(url)
	if err != nil {
		t.Fatal(err)
	}
	config.ConnConfig.RuntimeParams["search_path"] = schema
	pool, err := pgxpool.NewWithConfig(ctx, config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	if err := store.Migrate(ctx, pool); err != nil {
		t.Fatal(err)
	}
	return pool
}

func TestCollaborativePlaylistAPI(t *testing.T) {
	pool := collabTestPool(t)
	ctx := context.Background()
	users := store.NewUsers(pool)
	tracks := store.NewTracks(pool)
	playlists := store.NewPlaylists(pool)
	tokens, _ := auth.NewTokens([]byte(strings.Repeat("k", auth.MinSecretBytes)), time.Hour)
	handler := NewHandler(Config{Playlists: NewPlaylistHandlers(playlists, tokens).WithSharing(playlists, fixedPresigner{}, SavePolicy{})})

	owner, _ := users.Create(ctx, "owner@example.com", "hash")
	member, _ := users.Create(ctx, "member@example.com", "hash")
	stranger, _ := users.Create(ctx, "stranger@example.com", "hash")
	ownerToken, _, _ := tokens.Issue(owner.ID)
	memberToken, _, _ := tokens.Issue(member.ID)
	strangerToken, _, _ := tokens.Issue(stranger.ID)
	ownerTrack, _ := tracks.Create(ctx, owner.ID, store.NewTrack{Title: "o", FileName: "o.mp3", ContentType: "audio/mpeg", SizeBytes: 1})
	memberTrack, _ := tracks.Create(ctx, member.ID, store.NewTrack{Title: "m", FileName: "m.mp3", ContentType: "audio/mpeg", SizeBytes: 1})
	playlist, _ := playlists.Create(ctx, owner.ID, "together")

	call := func(method, path, token string, body any) *httptest.ResponseRecorder {
		t.Helper()
		var reader *bytes.Reader
		if body != nil {
			encoded, _ := json.Marshal(body)
			reader = bytes.NewReader(encoded)
		} else {
			reader = bytes.NewReader(nil)
		}
		request := httptest.NewRequest(method, path, reader)
		request.Header.Set("Authorization", "Bearer "+token)
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		return response
	}
	base := "/api/v1/playlists/" + playlist.ID
	setTracks := func(token string, ids ...string) int {
		return call(http.MethodPut, base+"/tracks", token, map[string]any{"trackIds": ids}).Code
	}
	if code := setTracks(ownerToken, ownerTrack.ID); code != http.StatusOK {
		t.Fatalf("owner adds own track = %d", code)
	}

	// Only the owner makes the link.
	if code := call(http.MethodPost, base+"/collab", memberToken, nil).Code; code != http.StatusNotFound {
		t.Fatalf("stranger makes a link = %d", code)
	}
	response := call(http.MethodPost, base+"/collab", ownerToken, nil)
	var link collabResponse
	json.NewDecoder(response.Body).Decode(&link)
	if response.Code != http.StatusOK || !validShareToken(link.CollabToken) {
		t.Fatalf("make link = %d %+v", response.Code, link)
	}
	if code := call(http.MethodPost, "/api/v1/collab/not-a-token/join", memberToken, nil).Code; code != http.StatusNotFound {
		t.Fatalf("bad link = %d", code)
	}

	// The member joins and adds a track; the owner's link stays hidden.
	response = call(http.MethodPost, "/api/v1/collab/"+link.CollabToken+"/join", memberToken, nil)
	var joined playlistResponse
	json.NewDecoder(response.Body).Decode(&joined)
	if response.Code != http.StatusOK || joined.IsOwner || joined.CollabToken != nil || joined.Owner != "o***@example.com" {
		t.Fatalf("join = %d %+v", response.Code, joined)
	}
	if code := setTracks(memberToken, ownerTrack.ID, memberTrack.ID); code != http.StatusOK {
		t.Fatalf("member adds own track = %d", code)
	}

	// The owner sees who added what, and the member list.
	response = call(http.MethodGet, base, ownerToken, nil)
	var seen playlistResponse
	json.NewDecoder(response.Body).Decode(&seen)
	if !seen.IsOwner || seen.CollabToken == nil || len(seen.Members) != 1 || seen.Members[0].Name != "m***@example.com" ||
		len(seen.Tracks) != 2 || seen.Tracks[0].AddedBy != nil || seen.Tracks[1].AddedBy == nil || *seen.Tracks[1].AddedBy != "m***@example.com" {
		t.Fatalf("owner view = %+v", seen)
	}

	// Members stream each other's tracks through the playlist; strangers can't.
	if code := call(http.MethodGet, base+"/tracks/"+memberTrack.ID+"/stream", ownerToken, nil).Code; code != http.StatusOK {
		t.Fatalf("owner streams member track = %d", code)
	}
	if code := call(http.MethodGet, base+"/tracks/"+memberTrack.ID+"/stream", strangerToken, nil).Code; code != http.StatusNotFound {
		t.Fatalf("stranger streams = %d", code)
	}
	if code := call(http.MethodGet, base, strangerToken, nil).Code; code != http.StatusNotFound {
		t.Fatalf("stranger views = %d", code)
	}

	// A member may not take out the owner's track, rename, or remove others.
	if code := setTracks(memberToken, memberTrack.ID); code != http.StatusForbidden {
		t.Fatalf("member removes owner's track = %d", code)
	}
	if code := call(http.MethodPut, base, memberToken, map[string]string{"name": "mine"}).Code; code != http.StatusNotFound {
		t.Fatalf("member renames = %d", code)
	}
	if code := call(http.MethodDelete, base+"/members/"+owner.ID, memberToken, nil).Code; code != http.StatusForbidden {
		t.Fatalf("member removes owner = %d", code)
	}

	// The owner makes the member an admin, who may then edit the channel
	// (#428); only the owner sets roles.
	role := base + "/members/" + member.ID + "/role"
	if code := call(http.MethodPut, role, memberToken, map[string]string{"role": "admin"}).Code; code != http.StatusNotFound {
		t.Fatalf("member making themselves admin = %d", code)
	}
	if code := call(http.MethodPut, role, ownerToken, map[string]string{"role": "boss"}).Code; code != http.StatusBadRequest {
		t.Fatalf("unknown role = %d", code)
	}
	if code := call(http.MethodPut, role, ownerToken, map[string]string{"role": "admin"}).Code; code != http.StatusNoContent {
		t.Fatalf("make admin = %d", code)
	}
	response = call(http.MethodPut, base, memberToken, map[string]string{"name": "ours", "description": "  songs we love "})
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), `"description":"songs we love"`) ||
		!strings.Contains(response.Body.String(), `"isAdmin":true`) {
		t.Fatalf("admin renames = %d %s", response.Code, response.Body)
	}
	if code := call(http.MethodPut, base, memberToken, map[string]string{"name": "ours", "description": strings.Repeat("x", 501)}).Code; code != http.StatusBadRequest {
		t.Fatalf("long description = %d", code)
	}
	response = call(http.MethodGet, base, ownerToken, nil)
	if !strings.Contains(response.Body.String(), `"role":"admin"`) {
		t.Fatalf("members after making admin = %s", response.Body)
	}
	call(http.MethodPut, role, ownerToken, map[string]string{"role": "member"})

	// Leaving takes the member's tracks out; the member list is empty again.
	if code := call(http.MethodDelete, base+"/membership", memberToken, nil).Code; code != http.StatusNoContent {
		t.Fatalf("leave = %d", code)
	}
	response = call(http.MethodGet, base, ownerToken, nil)
	seen = playlistResponse{}
	json.NewDecoder(response.Body).Decode(&seen)
	if len(seen.Tracks) != 1 || len(seen.Members) != 0 {
		t.Fatalf("after leaving = %+v", seen)
	}

	// Revoking stops the link.
	if code := call(http.MethodDelete, base+"/collab", ownerToken, nil).Code; code != http.StatusNoContent {
		t.Fatalf("revoke = %d", code)
	}
	if code := call(http.MethodPost, "/api/v1/collab/"+link.CollabToken+"/join", strangerToken, nil).Code; code != http.StatusNotFound {
		t.Fatalf("join after revoke = %d", code)
	}
}
