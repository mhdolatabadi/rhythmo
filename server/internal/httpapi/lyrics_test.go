package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/mhdolatabadi/rhythmo/server/internal/auth"
	"github.com/mhdolatabadi/rhythmo/server/internal/lyrics"
	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

// fakeLRCLIB answers like LRCLIB for a fixed catalogue; down makes it fail.
func fakeLRCLIB(t *testing.T, down *atomic.Bool) string {
	t.Helper()
	records := []lyrics.Record{
		{ID: 1, TrackName: "Shared Song", ArtistName: "Band", Duration: 200, SyncedLyrics: ptrTo("[00:01.00]first line\n[00:05.00]second line"), PlainLyrics: ptrTo("first line\nsecond line")},
		{ID: 2, TrackName: "Shared Song", ArtistName: "Band", Duration: 420, PlainLyrics: ptrTo("live version")},
		{ID: 3, TrackName: "Renamed", ArtistName: "Band", Duration: 180, PlainLyrics: ptrTo("renamed lyrics")},
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if down.Load() {
			w.WriteHeader(http.StatusBadGateway)
			return
		}
		var found []lyrics.Record
		for _, rec := range records {
			name := r.URL.Query().Get("track_name") + r.URL.Query().Get("q")
			if r.URL.Path == "/api/get/2" && rec.ID == 2 {
				_ = json.NewEncoder(w).Encode(rec)
				return
			}
			if r.URL.Path == "/api/search" && strings.Contains(strings.ToLower(rec.TrackName), strings.ToLower(name)) {
				found = append(found, rec)
			}
		}
		if r.URL.Path != "/api/search" {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		_ = json.NewEncoder(w).Encode(found)
	}))
	t.Cleanup(server.Close)
	return server.URL
}

func TestLyricsAPI(t *testing.T) {
	pool := collabTestPool(t)
	ctx := context.Background()
	users := store.NewUsers(pool)
	tracks := store.NewTracks(pool)
	playlists := store.NewPlaylists(pool)
	tokens, _ := auth.NewTokens([]byte(strings.Repeat("k", auth.MinSecretBytes)), time.Hour)
	var down atomic.Bool
	client, err := lyrics.NewClient(lyrics.ClientConfig{BaseURL: fakeLRCLIB(t, &down), Interval: time.Nanosecond})
	if err != nil {
		t.Fatal(err)
	}
	service := lyrics.NewService(client, store.NewLyrics(pool), time.Hour, time.Hour)
	limits := LyricsLimits{
		User: NewRateLimiter(RateLimit{Requests: 100, Window: time.Hour}, 100),
		IP:   NewRateLimiter(RateLimit{Requests: 100, Window: time.Hour}, 100),
	}
	handler := NewHandler(Config{Lyrics: NewLyricsHandlers(service, tracks, playlists, tokens, limits)})

	alice, _ := users.Create(ctx, "alice@example.com", "hash")
	bob, _ := users.Create(ctx, "bob@example.com", "hash")
	carol, _ := users.Create(ctx, "carol@example.com", "hash")
	aliceToken, _, _ := tokens.Issue(alice.ID)
	bobToken, _, _ := tokens.Issue(bob.ID)
	carolToken, _, _ := tokens.Issue(carol.ID)
	song, _ := tracks.Create(ctx, alice.ID, store.NewTrack{Title: "Shared Song", Artist: ptrTo("Band"), FileName: "s.mp3", ContentType: "audio/mpeg", SizeBytes: 1})
	unknown, _ := tracks.Create(ctx, alice.ID, store.NewTrack{Title: "No Such Song", FileName: "n.mp3", ContentType: "audio/mpeg", SizeBytes: 1})
	pending, _ := tracks.ReservePending(ctx, alice.ID, store.NewTrack{Title: "Shared Song", FileName: "p.mp3", ContentType: "audio/mpeg", SizeBytes: 1}, 1<<30, 10)

	// Bob joins Alice's collaborative playlist; Carol never does.
	together, _ := playlists.Create(ctx, alice.ID, "together")
	_ = playlists.ReplaceTracks(ctx, alice.ID, together.ID, []string{song.ID})
	_, _ = playlists.SetCollabToken(ctx, alice.ID, together.ID, ptrTo("join"))
	if _, err := playlists.Join(ctx, bob.ID, "join"); err != nil {
		t.Fatal(err)
	}
	// A second playlist, shared by link only for now.
	shareToken, _ := newShareToken()
	shared, _ := playlists.Create(ctx, alice.ID, "shared")
	_ = playlists.ReplaceTracks(ctx, alice.ID, shared.ID, []string{song.ID})
	notPublic := false
	if _, err := playlists.Share(ctx, alice.ID, shared.ID, shareToken, &notPublic, true); err != nil {
		t.Fatal(err)
	}

	call := func(method, path, token string, body any) *httptest.ResponseRecorder {
		t.Helper()
		var encoded []byte
		if body != nil {
			encoded, _ = json.Marshal(body)
		}
		request := httptest.NewRequest(method, path, bytes.NewReader(encoded))
		if token != "" {
			request.Header.Set("Authorization", "Bearer "+token)
		}
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		return response
	}
	get := func(path, token string, want int) lyricsResponse {
		t.Helper()
		response := call("GET", path, token, nil)
		if response.Code != want {
			t.Fatalf("GET %s = %d %s, want %d", path, response.Code, response.Body, want)
		}
		var body lyricsResponse
		_ = json.Unmarshal(response.Body.Bytes(), &body)
		return body
	}

	own := "/api/v1/tracks/" + song.ID + "/lyrics"
	viaPlaylist := "/api/v1/playlists/" + together.ID + "/tracks/" + song.ID + "/lyrics"
	viaLink := "/api/v1/shared-playlists/" + shareToken + "/tracks/" + song.ID + "/lyrics"

	// The owner gets synced lyrics, matched on length when the app says it.
	body := get(own+"?durationMs=201000", aliceToken, http.StatusOK)
	if body.Status != "found" || body.Synced == nil || body.Match.ID != 1 || !body.CanChoose || body.Chosen {
		t.Fatalf("owner = %+v", body)
	}
	if body := get("/api/v1/tracks/"+unknown.ID+"/lyrics", aliceToken, http.StatusOK); body.Status != "not_found" || body.Match != nil {
		t.Fatalf("unknown song = %+v", body)
	}

	// Who may read them: whoever may play the track, and no one else.
	get(own, "", http.StatusUnauthorized)
	get(own, bobToken, http.StatusNotFound)
	get("/api/v1/tracks/"+pending.ID+"/lyrics", aliceToken, http.StatusNotFound)
	if body := get(viaPlaylist, bobToken, http.StatusOK); body.Status != "found" || body.CanChoose {
		t.Fatalf("member = %+v", body)
	}
	get(viaPlaylist, carolToken, http.StatusNotFound)
	if body := get(viaLink, carolToken, http.StatusOK); body.Status != "found" || body.CanChoose {
		t.Fatalf("link holder = %+v", body)
	}
	get(viaLink, "", http.StatusNotFound)
	get("/api/v1/shared-playlists/not-a-token/tracks/"+song.ID+"/lyrics", carolToken, http.StatusNotFound)
	get("/api/v1/shared-playlists/"+shareToken+"/tracks/"+unknown.ID+"/lyrics", carolToken, http.StatusNotFound)
	public := true
	_, _ = playlists.Share(ctx, alice.ID, shared.ID, shareToken, &public, true)
	if body := get(viaLink, "", http.StatusOK); body.Status != "found" || body.CanChoose {
		t.Fatalf("visitor of a public playlist = %+v", body)
	}

	// Only the owner may look for and pick another match.
	candidates := "/api/v1/tracks/" + song.ID + "/lyrics/candidates"
	if response := call("GET", candidates, bobToken, nil); response.Code != http.StatusNotFound {
		t.Fatalf("stranger's candidates = %d", response.Code)
	}
	if response := call("PUT", own, bobToken, chooseLyricsRequest{LRCLIBID: 2}); response.Code != http.StatusNotFound {
		t.Fatalf("stranger's choice = %d", response.Code)
	}
	response := call("GET", candidates, aliceToken, nil)
	var list lyricsCandidatesResponse
	_ = json.Unmarshal(response.Body.Bytes(), &list)
	if response.Code != http.StatusOK || len(list.Candidates) != 2 {
		t.Fatalf("candidates = %d %s", response.Code, response.Body)
	}
	if response := call("GET", candidates+"?q=renamed", aliceToken, nil); !strings.Contains(response.Body.String(), `"id":3`) {
		t.Fatalf("free text candidates = %s", response.Body)
	}
	if response := call("PUT", own, aliceToken, map[string]any{"lrclibId": 0}); response.Code != http.StatusBadRequest {
		t.Fatalf("invalid choice = %d", response.Code)
	}
	if response := call("PUT", own, aliceToken, chooseLyricsRequest{LRCLIBID: 99}); response.Code != http.StatusNotFound {
		t.Fatalf("unknown choice = %d %s", response.Code, response.Body)
	}
	if response := call("PUT", own, aliceToken, chooseLyricsRequest{LRCLIBID: 2}); response.Code != http.StatusOK {
		t.Fatalf("choose = %d %s", response.Code, response.Body)
	}
	if body := get(viaPlaylist, bobToken, http.StatusOK); body.Match.ID != 2 || !body.Chosen || *body.Plain != "live version" {
		t.Fatalf("the owner's pick is not what members see: %+v", body)
	}

	// Editing the title invalidates the cached lyrics.
	if _, err := tracks.UpdateMetadata(ctx, alice.ID, song.ID, song.MetadataVersion, store.TrackMetadata{
		FileName: song.FileName, Title: "Renamed", Artist: ptrTo("Band"), TagStatus: store.TagUnsupported,
	}); err != nil {
		t.Fatal(err)
	}
	if body := get(own, aliceToken, http.StatusOK); body.Match == nil || body.Match.ID != 3 || body.Chosen {
		t.Fatalf("after renaming = %+v", body)
	}

	// LRCLIB down: cached lyrics still show; a first lookup says so.
	down.Store(true)
	get(own, aliceToken, http.StatusOK)
	another, _ := tracks.Create(ctx, alice.ID, store.NewTrack{Title: "Another", FileName: "x.mp3", ContentType: "audio/mpeg", SizeBytes: 1})
	response = call("GET", "/api/v1/tracks/"+another.ID+"/lyrics", aliceToken, nil)
	if response.Code != http.StatusServiceUnavailable || response.Header().Get("Retry-After") == "" {
		t.Fatalf("LRCLIB down = %d %s", response.Code, response.Body)
	}
}

func TestLyricsRateLimit(t *testing.T) {
	tokens, _ := auth.NewTokens([]byte(strings.Repeat("k", auth.MinSecretBytes)), time.Hour)
	limits := LyricsLimits{
		User: NewRateLimiter(RateLimit{Requests: 1, Window: time.Hour}, 100),
		IP:   NewRateLimiter(RateLimit{Requests: 1, Window: time.Hour}, 100),
	}
	handler := NewHandler(Config{Lyrics: NewLyricsHandlers(nil, notFoundTracks{}, notFoundTracks{}, tokens, limits)})
	token, _, _ := tokens.Issue("00000000-0000-0000-0000-000000000001")
	shareToken, _ := newShareToken()
	for _, c := range []struct{ path, token string }{
		{"/api/v1/tracks/x/lyrics", token},
		{"/api/v1/shared-playlists/" + shareToken + "/tracks/x/lyrics", ""},
	} {
		codes := []int{}
		for range 2 {
			request := httptest.NewRequest("GET", c.path, nil)
			if c.token != "" {
				request.Header.Set("Authorization", "Bearer "+c.token)
			}
			response := httptest.NewRecorder()
			handler.ServeHTTP(response, request)
			codes = append(codes, response.Code)
		}
		if codes[0] != http.StatusNotFound || codes[1] != http.StatusTooManyRequests {
			t.Fatalf("%s: %v", c.path, codes)
		}
	}
}

type notFoundTracks struct{}

func (notFoundTracks) ForOwner(context.Context, string, string) (store.Track, error) {
	return store.Track{}, store.ErrNotFound
}

func (notFoundTracks) PlaylistTrack(context.Context, string, string, string) (store.Track, error) {
	return store.Track{}, store.ErrNotFound
}

func (notFoundTracks) SharedTrack(context.Context, string, string, bool) (store.Track, error) {
	return store.Track{}, store.ErrNotFound
}
