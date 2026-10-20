package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"math/rand"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/mhdolatabadi/rhythmo/server/internal/auth"
	"github.com/mhdolatabadi/rhythmo/server/internal/fingerprint"
	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

// songPoints is a made-up fingerprint for each "song" a test snippet
// names: random bits, so different songs share about half of them.
var songPoints = func() map[string][]uint32 {
	rng := rand.New(rand.NewSource(1))
	songs := map[string][]uint32{}
	for _, name := range []string{"song-a", "song-b", "song-c", "unknown"} {
		points := make([]uint32, 12)
		for i := range points {
			points[i] = rng.Uint32()
		}
		songs[name] = points
	}
	return songs
}()

// snippetFingerprinter reads which song a snippet "is" from its contents,
// and remembers which files it was handed.
type snippetFingerprinter struct{ paths []string }

func (f *snippetFingerprinter) File(_ context.Context, path string) (fingerprint.Fingerprint, error) {
	f.paths = append(f.paths, path)
	data, _ := os.ReadFile(path)
	name := string(data)
	if name == "short" {
		return fingerprint.Fingerprint{Duration: time.Second, Points: []uint32{1}}, nil
	}
	points, ok := songPoints[name]
	if !ok {
		return fingerprint.Fingerprint{}, fingerprint.ErrNoAudio
	}
	return fingerprint.Fingerprint{Duration: 10 * time.Second, Points: points[2:10]}, nil
}

func TestIdentifyAPI(t *testing.T) {
	pool := collabTestPool(t)
	ctx := context.Background()
	users := store.NewUsers(pool)
	tracks := store.NewTracks(pool)
	playlists := store.NewPlaylists(pool)
	fps := store.NewFingerprints(pool)
	tokens, _ := auth.NewTokens([]byte(strings.Repeat("k", auth.MinSecretBytes)), time.Hour)
	tempDir := t.TempDir()
	calc := &snippetFingerprinter{}
	handler := NewHandler(Config{Identify: NewIdentifyHandlers(IdentifyConfig{
		Fingerprinter: calc, Matches: fps, Playlists: playlists, Copier: fps,
		Save:    SavePolicy{Objects: noCopies{}, MaxOwnerBytes: 1000, Enabled: true},
		TempDir: tempDir, Rate: NewRateLimiter(RateLimit{Requests: 12, Window: time.Hour}, 100),
	}, tokens)})

	alice, _ := users.Create(ctx, "alice@example.com", "hash")
	bob, _ := users.Create(ctx, "bob@example.com", "hash")
	aliceToken, _, _ := tokens.Issue(alice.ID)
	add := func(owner, title, song string) store.Track {
		t.Helper()
		track, _ := tracks.Create(ctx, owner, store.NewTrack{Title: title, Artist: ptrTo("Band"), FileName: title + ".mp3", ContentType: "audio/mpeg", SizeBytes: 100})
		if err := fps.SaveFingerprint(ctx, track.ID, fingerprint.Encode(songPoints[song]), time.Minute); err != nil {
			t.Fatal(err)
		}
		return track
	}
	mine := add(alice.ID, "Mine", "song-a")
	public := add(bob.ID, "Public", "song-b")
	add(bob.ID, "Private", "song-c")
	shareToken, _ := newShareToken()
	list, _ := playlists.Create(ctx, bob.ID, "public")
	_ = playlists.ReplaceTracks(ctx, bob.ID, list.ID, []string{public.ID})
	yes := true
	_, _ = playlists.Share(ctx, bob.ID, list.ID, shareToken, &yes, true)

	identify := func(body, contentType string) (*httptest.ResponseRecorder, identifyResponse) {
		t.Helper()
		request := httptest.NewRequest("POST", "/api/v1/identify", strings.NewReader(body))
		request.Header.Set("Authorization", "Bearer "+aliceToken)
		request.Header.Set("Content-Type", contentType)
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		var decoded identifyResponse
		_ = json.Unmarshal(response.Body.Bytes(), &decoded)
		return response, decoded
	}

	response, result := identify("song-a", "audio/wav")
	if response.Code != http.StatusOK || result.Status != "found" || result.Track.ID != mine.ID ||
		result.Source != "library" || result.Track.AddedBy != nil || result.Confidence < fingerprint.MinConfidence {
		t.Fatalf("own song = %d %s", response.Code, response.Body)
	}
	if result.OffsetMS != (2 * fingerprint.ItemDuration).Milliseconds() {
		t.Fatalf("offset = %d", result.OffsetMS)
	}
	_, result = identify("song-b", "audio/webm;codecs=opus")
	if result.Status != "found" || result.Track.ID != public.ID || result.Source != "public" ||
		result.ShareToken == nil || *result.ShareToken != shareToken || result.Track.AddedBy == nil ||
		strings.Contains(*result.Track.AddedBy, "bob@example.com") {
		t.Fatalf("public song = %+v", result)
	}
	// Another user's private song is never matched, nor anything about it told.
	response, result = identify("song-c", "audio/wav")
	if result.Status != "not_found" || strings.Contains(response.Body.String(), "Private") {
		t.Fatalf("private song = %s", response.Body)
	}
	if _, result := identify("unknown", "audio/wav"); result.Status != "not_found" {
		t.Fatalf("unknown = %+v", result)
	}

	for _, c := range []struct {
		body, contentType string
		status            int
		code              string
	}{
		{"song-a", "text/plain", http.StatusUnsupportedMediaType, "unsupported_format"},
		{"", "audio/wav", http.StatusBadRequest, "invalid_snippet"},
		{"short", "audio/wav", http.StatusUnprocessableEntity, "snippet_too_short"},
		{"garbage", "audio/wav", http.StatusUnprocessableEntity, "invalid_snippet"},
		{strings.Repeat("x", maxSnippetBytes+1), "audio/wav", http.StatusRequestEntityTooLarge, "snippet_too_large"},
	} {
		response, _ := identify(c.body, c.contentType)
		if response.Code != c.status || !strings.Contains(response.Body.String(), c.code) {
			t.Fatalf("%q as %s = %d %s", c.body[:min(len(c.body), 10)], c.contentType, response.Code, response.Body)
		}
	}
	// Every snippet was deleted right after it was read.
	if entries, _ := os.ReadDir(tempDir); len(entries) != 0 {
		t.Fatalf("%d snippets left behind", len(entries))
	}
	if len(calc.paths) == 0 {
		t.Fatal("nothing was fingerprinted")
	}

	// Adding the public match to the library copies it once.
	save := func(body any) *httptest.ResponseRecorder {
		encoded, _ := json.Marshal(body)
		request := httptest.NewRequest("POST", "/api/v1/identify/save", bytes.NewReader(encoded))
		request.Header.Set("Authorization", "Bearer "+aliceToken)
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		return response
	}
	if response := save(map[string]any{"trackId": public.ID, "shareToken": shareToken}); response.Code != http.StatusCreated {
		t.Fatalf("save = %d %s", response.Code, response.Body)
	}
	owned, _ := tracks.ListForOwner(ctx, alice.ID)
	if len(owned) != 2 {
		t.Fatalf("alice has %d tracks after saving", len(owned))
	}
	if response := save(map[string]any{"trackId": mine.ID, "shareToken": shareToken}); response.Code != http.StatusNotFound {
		t.Fatalf("saving a track not in the playlist = %d", response.Code)
	}
	if response := save(map[string]any{"trackId": public.ID, "playlistId": list.ID}); response.Code != http.StatusNotFound {
		t.Fatalf("saving through a playlist alice isn't in = %d", response.Code)
	}
	if response := save(map[string]any{"trackId": public.ID}); response.Code != http.StatusBadRequest {
		t.Fatalf("saving without a source = %d", response.Code)
	}
	// Ten more bytes than her quota allows.
	big := add(bob.ID, "Big", "song-a")
	_, _ = pool.Exec(ctx, "UPDATE tracks SET size_bytes = 900 WHERE id::text = $1", big.ID)
	_ = playlists.ReplaceTracks(ctx, bob.ID, list.ID, []string{public.ID, big.ID})
	if response := save(map[string]any{"trackId": big.ID, "shareToken": shareToken}); response.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("over quota = %d %s", response.Code, response.Body)
	}

	// Without a token nothing is identified; past the rate limit it waits.
	request := httptest.NewRequest("POST", "/api/v1/identify", strings.NewReader("song-a"))
	request.Header.Set("Content-Type", "audio/wav")
	response = httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusUnauthorized {
		t.Fatalf("anonymous = %d", response.Code)
	}
	for {
		response, _ := identify("song-a", "audio/wav")
		if response.Code == http.StatusTooManyRequests {
			break
		}
		if response.Code != http.StatusOK {
			t.Fatalf("before the limit = %d", response.Code)
		}
	}
}

func TestIdentifyWithoutAnAccountMatchesOnlyTheStore(t *testing.T) {
	pool := collabTestPool(t)
	ctx := context.Background()
	users, tracks, playlists := store.NewUsers(pool), store.NewTracks(pool), store.NewPlaylists(pool)
	fps, catalog := store.NewFingerprints(pool), store.NewCatalog(pool)
	tokens, _ := auth.NewTokens([]byte(strings.Repeat("k", auth.MinSecretBytes)), time.Hour)
	handler := NewHandler(Config{Identify: NewIdentifyHandlers(IdentifyConfig{
		Fingerprinter: &snippetFingerprinter{}, Matches: fps, Playlists: playlists, Copier: fps,
		TempDir: t.TempDir(), Rate: NewRateLimiter(RateLimit{Requests: 100, Window: time.Hour}, 100),
		Store: catalog, AnonymousRate: NewRateLimiter(RateLimit{Requests: 4, Window: time.Hour}, 100),
	}, tokens)})

	bob, _ := users.Create(ctx, "bob@example.com", "hash")
	add := func(title, song string, inStore bool) store.Track {
		t.Helper()
		track, _ := tracks.Create(ctx, bob.ID, store.NewTrack{Title: title, FileName: "bob-" + title + ".mp3",
			ContentType: "audio/mpeg", SizeBytes: 100})
		points := fingerprint.Encode(songPoints[song])
		if err := fps.SaveFingerprint(ctx, track.ID, points, time.Minute); err != nil {
			t.Fatal(err)
		}
		if inStore {
			if err := catalog.NewEntry(ctx, track.ID, title, points, nil); err != nil {
				t.Fatal(err)
			}
		}
		return track
	}
	listed := add("Listed", "song-a", true)
	hidden := add("Hidden", "song-b", true)
	add("Private", "song-c", false)
	list, _ := playlists.Create(ctx, bob.ID, "public")
	_ = playlists.ReplaceTracks(ctx, bob.ID, list.ID, []string{listed.ID, hidden.ID})
	shareToken, _ := newShareToken()
	yes := true
	_, _ = playlists.Share(ctx, bob.ID, list.ID, shareToken, &yes, true)
	entries, _, _ := catalog.StoreEntries(ctx, store.StoreQuery{Limit: 10})
	for _, entry := range entries {
		if entry.Track.ID == hidden.ID {
			if err := catalog.SetHidden(ctx, entry.ID, bob.ID, true); err != nil {
				t.Fatal(err)
			}
		}
	}

	identify := func(song, ip string) (*httptest.ResponseRecorder, identifyResponse) {
		t.Helper()
		request := httptest.NewRequest("POST", "/api/v1/identify", strings.NewReader(song))
		request.Header.Set("Content-Type", "audio/wav")
		request.RemoteAddr = ip + ":1234"
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		var decoded identifyResponse
		_ = json.Unmarshal(response.Body.Bytes(), &decoded)
		return response, decoded
	}
	response, result := identify("song-a", "203.0.113.1")
	if response.Code != http.StatusOK || result.Status != "found" || result.Source != "store" ||
		result.StoreTrack == nil || result.StoreTrack.Title != "Listed" || result.Track != nil {
		t.Fatalf("store song = %d %s", response.Code, response.Body)
	}
	for _, leak := range []string{listed.ID, bob.ID, "bob", "shareToken", shareToken} {
		if strings.Contains(response.Body.String(), leak) {
			t.Fatalf("the match shows %q: %s", leak, response.Body)
		}
	}
	// Hidden and private songs are never matched for visitors.
	for _, song := range []string{"song-b", "song-c"} {
		if _, result := identify(song, "203.0.113.1"); result.Status != "not_found" {
			t.Fatalf("%s = %+v", song, result)
		}
	}
	// Unpublishing takes the song out of matching at once.
	no := false
	_, _ = playlists.Share(ctx, bob.ID, list.ID, shareToken, &no, true)
	if _, result := identify("song-a", "203.0.113.1"); result.Status != "not_found" {
		t.Fatalf("unpublished song = %+v", result)
	}
	if response, _ := identify("song-a", "203.0.113.1"); response.Code != http.StatusTooManyRequests {
		t.Fatalf("past the visitor limit = %d", response.Code)
	}
	if response, _ := identify("song-a", "203.0.113.2"); response.Code != http.StatusOK {
		t.Fatalf("another visitor = %d", response.Code)
	}
	// A bad token is refused, not treated as a visitor.
	request := httptest.NewRequest("POST", "/api/v1/identify", strings.NewReader("song-a"))
	request.Header.Set("Content-Type", "audio/wav")
	request.Header.Set("Authorization", "Bearer nope")
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusUnauthorized {
		t.Fatalf("bad token = %d", recorder.Code)
	}
}
