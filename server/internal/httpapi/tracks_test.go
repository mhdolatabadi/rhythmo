package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/mhdolatabadi/rhythmo/server/internal/auth"
	"github.com/mhdolatabadi/rhythmo/server/internal/storage"
	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

const (
	testMaxUpload  = 1000
	testOwnerQuota = 2000
	testMaxPending = 3
)

type memoryTracks struct {
	mu     sync.Mutex
	nextID int
	tracks []store.Track
	// leaky ignores the owner, to prove the handler does not rely on the store alone.
	leaky bool
}

func (m *memoryTracks) ListForOwner(_ context.Context, ownerID string) ([]store.Track, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var owned []store.Track
	for _, track := range m.tracks {
		if track.OwnerID == ownerID && track.Status == store.TrackReady {
			owned = append(owned, track)
		}
	}
	return owned, nil
}

func (m *memoryTracks) UsageForOwner(_ context.Context, ownerID string) (int64, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var used int64
	for _, track := range m.tracks {
		if track.OwnerID == ownerID {
			used += track.SizeBytes
		}
	}
	return used, nil
}

func (m *memoryTracks) ForOwner(_ context.Context, ownerID, trackID string) (store.Track, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, track := range m.tracks {
		if track.ID == trackID && (m.leaky || track.OwnerID == ownerID) {
			return track, nil
		}
	}
	return store.Track{}, store.ErrNotFound
}

func (m *memoryTracks) ReservePending(
	_ context.Context,
	ownerID string,
	t store.NewTrack,
	maxOwnerBytes int64,
	maxPending int,
) (store.Track, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var used int64
	var pending int
	for _, track := range m.tracks {
		if track.OwnerID != ownerID {
			continue
		}
		used += track.SizeBytes
		if track.Status == store.TrackPending {
			pending++
		}
	}
	if pending >= maxPending {
		return store.Track{}, store.ErrTooManyPending
	}
	if used > maxOwnerBytes || t.SizeBytes > maxOwnerBytes-used {
		return store.Track{}, store.ErrQuotaExceeded
	}
	m.nextID++
	id := "t" + string(rune('0'+m.nextID))
	track := store.Track{
		ID: id, OwnerID: ownerID, Status: store.TrackPending, Title: t.Title, Artist: t.Artist, Album: t.Album,
		FileName: t.FileName, StorageKey: store.StorageKey(ownerID, id, t.FileName),
		ContentType: t.ContentType, SizeBytes: t.SizeBytes, MetadataVersion: 1,
	}
	m.tracks = append(m.tracks, track)
	return track, nil
}

func (m *memoryTracks) QuotaForOwner(_ context.Context, _ string, fallback int64) (int64, error) {
	return fallback, nil
}

func (m *memoryTracks) MarkReady(_ context.Context, ownerID, trackID string) (store.Track, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	for i, track := range m.tracks {
		if track.ID == trackID && track.OwnerID == ownerID {
			m.tracks[i].Status = store.TrackReady
			return m.tracks[i], nil
		}
	}
	return store.Track{}, store.ErrNotFound
}

func (m *memoryTracks) UpdateMetadata(_ context.Context, ownerID, trackID string, version int64, metadata store.TrackMetadata) (store.Track, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	for i, track := range m.tracks {
		if track.ID == trackID && track.OwnerID == ownerID && track.Status == store.TrackReady {
			if track.MetadataVersion != version {
				return store.Track{}, store.ErrVersionConflict
			}
			m.tracks[i].MetadataVersion++
			m.tracks[i].TagStatus = metadata.TagStatus
			m.tracks[i].FileName = metadata.FileName
			m.tracks[i].Title = metadata.Title
			m.tracks[i].Artist = metadata.Artist
			m.tracks[i].Album = metadata.Album
			m.tracks[i].AlbumArtist = metadata.AlbumArtist
			m.tracks[i].Composer = metadata.Composer
			m.tracks[i].Genre = metadata.Genre
			m.tracks[i].Year = metadata.Year
			m.tracks[i].TrackNumber = metadata.TrackNumber
			m.tracks[i].DiscNumber = metadata.DiscNumber
			m.tracks[i].Comment = metadata.Comment
			return m.tracks[i], nil
		}
	}
	return store.Track{}, store.ErrNotFound
}

func (m *memoryTracks) Delete(_ context.Context, ownerID, trackID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for i, track := range m.tracks {
		if track.ID == trackID && track.OwnerID == ownerID {
			m.tracks = append(m.tracks[:i], m.tracks[i+1:]...)
			return nil
		}
	}
	return store.ErrNotFound
}

func (m *memoryTracks) has(id string) bool {
	_, err := (&memoryTracks{tracks: m.tracks, leaky: true}).ForOwner(context.Background(), "", id)
	return err == nil
}

type fakeObjects struct {
	objects map[string][]byte
	signed  []string
}

func (f *fakeObjects) PresignGet(_ context.Context, key string) (string, time.Time, error) {
	f.signed = append(f.signed, key)
	return "https://music.example.com/nafir-music/" + key + "?X-Amz-Signature=sig", time.Now().Add(time.Hour), nil
}

func (f *fakeObjects) PresignDownload(_ context.Context, key, disposition, contentType string) (string, time.Time, error) {
	f.signed = append(f.signed, key)
	return "https://music.example.com/nafir-music/" + key + "?response-content-disposition=" + url.QueryEscape(disposition) +
		"&response-content-type=" + url.QueryEscape(contentType) + "&X-Amz-Signature=sig", time.Now().Add(time.Hour), nil
}

func (f *fakeObjects) PresignUpload(_ context.Context, key, contentType string, size int64) (storage.Upload, error) {
	return storage.Upload{
		URL:       "https://music.example.com/nafir-music/",
		Fields:    map[string]string{"key": key, "Content-Type": contentType, "policy": "p"},
		ExpiresAt: time.Now().Add(time.Hour),
	}, nil
}

func (f *fakeObjects) Size(_ context.Context, key string) (int64, error) {
	data, ok := f.objects[key]
	if !ok {
		return 0, storage.ErrObjectMissing
	}
	return int64(len(data)), nil
}

func (f *fakeObjects) Head(_ context.Context, key string, n int64) ([]byte, error) {
	data := f.objects[key]
	if int64(len(data)) > n {
		data = data[:n]
	}
	return data, nil
}

func (f *fakeObjects) Remove(_ context.Context, key string) error {
	delete(f.objects, key)
	return nil
}

type tracksAPI struct {
	handler http.Handler
	tracks  *memoryTracks
	objects *fakeObjects
	alice   string
	bob     string
	// fingerprints counts wake-ups of the fingerprint worker.
	fingerprints *countingNotifier
}

func newTracksAPI(t *testing.T, tracks *memoryTracks) tracksAPI {
	t.Helper()
	return newTracksAPIWithLimits(t, tracks, UploadLimits{
		MaxFileBytes: testMaxUpload, MaxOwnerBytes: testOwnerQuota,
		MaxPending: testMaxPending, Enabled: true,
	})
}

func newTracksAPIWithLimits(t *testing.T, tracks *memoryTracks, limits UploadLimits) tracksAPI {
	t.Helper()
	tokens, err := auth.NewTokens([]byte(strings.Repeat("k", auth.MinSecretBytes)), time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	alice, _, _ := tokens.Issue("alice")
	bob, _, _ := tokens.Issue("bob")
	objects := &fakeObjects{objects: map[string][]byte{}}
	fingerprints := &countingNotifier{}
	return tracksAPI{
		handler:      NewHandler(Config{Tracks: NewTrackHandlers(tracks, objects, tokens, limits).WithFingerprints(fingerprints)}),
		fingerprints: fingerprints,
		tracks:       tracks,
		objects:      objects,
		alice:        alice,
		bob:          bob,
	}
}

func (a tracksAPI) do(t *testing.T, method, path, body, token string) *httptest.ResponseRecorder {
	t.Helper()
	request := httptest.NewRequest(method, path, bytes.NewBufferString(body))
	if token != "" {
		request.Header.Set("Authorization", "Bearer "+token)
	}
	response := httptest.NewRecorder()
	a.handler.ServeHTTP(response, request)
	return response
}

func (a tracksAPI) get(t *testing.T, path, token string) *httptest.ResponseRecorder {
	return a.do(t, http.MethodGet, path, "", token)
}

func sampleTracks() *memoryTracks {
	return &memoryTracks{tracks: []store.Track{
		{ID: "a1", OwnerID: "alice", Status: store.TrackReady, Title: "Alice song", FileName: "song.mp3", StorageKey: "users/alice/tracks/a1/song.mp3", ContentType: "audio/mpeg", MetadataVersion: 1},
		{ID: "b1", OwnerID: "bob", Status: store.TrackReady, Title: "Bob song", FileName: "song.mp3", StorageKey: "users/bob/tracks/b1/song.mp3", ContentType: "audio/mpeg", MetadataVersion: 1},
	}}
}

func TestListReturnsOnlyOwnTracks(t *testing.T) {
	api := newTracksAPI(t, sampleTracks())

	response := api.get(t, "/api/v1/tracks", api.alice)
	if response.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", response.Code)
	}
	list := decode[trackListResponse](t, response)
	if len(list.Tracks) != 1 || list.Tracks[0].ID != "a1" {
		t.Fatalf("alice should see only a1, got %+v", list.Tracks)
	}
	if list.Storage.UsedBytes != 0 || list.Storage.LimitBytes != testOwnerQuota {
		t.Fatalf("unexpected storage usage %+v", list.Storage)
	}
	if strings.Contains(response.Body.String(), "users/") {
		t.Fatal("storage keys must not be exposed")
	}
}

func TestEmptyLibraryIsAnEmptyArray(t *testing.T) {
	api := newTracksAPI(t, &memoryTracks{})
	if body := strings.TrimSpace(api.get(t, "/api/v1/tracks", api.alice).Body.String()); body != `{"tracks":[],"storage":{"usedBytes":0,"limitBytes":2000},"importsInProgress":0}` {
		t.Fatalf("unexpected body %s", body)
	}
}

func TestOwnTrackAndStreamURL(t *testing.T) {
	api := newTracksAPI(t, sampleTracks())

	if response := api.get(t, "/api/v1/tracks/a1", api.alice); response.Code != http.StatusOK {
		t.Fatalf("get: expected 200, got %d", response.Code)
	}
	response := api.get(t, "/api/v1/tracks/a1/stream", api.alice)
	if response.Code != http.StatusOK {
		t.Fatalf("stream: expected 200, got %d", response.Code)
	}
	if response.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("stream URLs must not be cached")
	}
	stream := decode[streamResponse](t, response)
	if !strings.Contains(stream.URL, "users/alice/tracks/a1/") || !stream.ExpiresAt.After(time.Now()) {
		t.Fatalf("unexpected stream response %+v", stream)
	}
}

func TestDownloadURLSavesTheFileUnderItsName(t *testing.T) {
	tracks := sampleTracks()
	tracks.tracks = append(tracks.tracks, store.Track{
		ID: "p1", OwnerID: "alice", Status: store.TrackPending, Title: "Pending",
		FileName: "pending.mp3", StorageKey: "users/alice/tracks/p1/pending.mp3", ContentType: "audio/mpeg",
	})
	api := newTracksAPI(t, tracks)

	response := api.get(t, "/api/v1/tracks/a1/download", api.alice)
	if response.Code != http.StatusOK {
		t.Fatalf("download: expected 200, got %d", response.Code)
	}
	if response.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("download URLs must not be cached")
	}
	download := decode[downloadResponse](t, response)
	if download.FileName != "song.mp3" || !download.ExpiresAt.After(time.Now()) {
		t.Fatalf("unexpected download response %+v", download)
	}
	parsed, err := url.Parse(download.URL)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(parsed.Path, "users/alice/tracks/a1/") ||
		parsed.Query().Get("response-content-disposition") != `attachment; filename="song.mp3"; filename*=UTF-8''song.mp3` {
		t.Fatalf("download URL does not save as the filename: %s", download.URL)
	}

	// Unfinished uploads have nothing to download.
	expectError(t, api.get(t, "/api/v1/tracks/p1/download", api.alice), http.StatusNotFound, "not_found")
}

func TestUpdateTrackMetadata(t *testing.T) {
	artist := "Old artist"
	album := "Old album"
	tracks := &memoryTracks{tracks: []store.Track{
		{ID: "a1", OwnerID: "alice", Status: store.TrackReady, Title: "Old title", Artist: &artist, Album: &album, FileName: "song.mp3", StorageKey: "users/alice/tracks/a1/song.mp3", ContentType: "audio/mpeg", MetadataVersion: 1},
		{ID: "p1", OwnerID: "alice", Status: store.TrackPending, Title: "Pending", FileName: "song.mp3", StorageKey: "users/alice/tracks/p1/song.mp3", ContentType: "audio/mpeg", MetadataVersion: 1},
	}}
	api := newTracksAPI(t, tracks)

	response := api.do(t, http.MethodPatch, "/api/v1/tracks/a1",
		`{"version":1,"fileName":" آهنگ تازه.MP3 ","title":" New title ","artist":"","album":" Album ","albumArtist":" Various ","composer":" Composer ","genre":" Rock ","year":2026,"trackNumber":7,"discNumber":1,"comment":" Line one\nLine two "}`, api.alice)
	if response.Code != http.StatusOK {
		t.Fatalf("update: expected 200, got %d: %s", response.Code, response.Body.String())
	}
	updated := decode[trackResponse](t, response)
	if updated.FileName != "آهنگ تازه.mp3" || updated.Title != "New title" || updated.Artist != nil ||
		updated.Album == nil || *updated.Album != "Album" ||
		updated.AlbumArtist == nil || *updated.AlbumArtist != "Various" ||
		updated.Composer == nil || *updated.Composer != "Composer" ||
		updated.Genre == nil || *updated.Genre != "Rock" ||
		updated.Year == nil || *updated.Year != 2026 ||
		updated.TrackNumber == nil || *updated.TrackNumber != 7 ||
		updated.DiscNumber == nil || *updated.DiscNumber != 1 ||
		updated.Comment == nil || *updated.Comment != "Line one\nLine two" ||
		updated.Version != 2 {
		t.Fatalf("unexpected updated track %+v", updated)
	}
	listed := decode[trackListResponse](t, api.get(t, "/api/v1/tracks", api.alice))
	if listed.Tracks[0].Title != "New title" || listed.Tracks[0].Version != 2 {
		t.Fatalf("list did not reflect update: %+v", listed.Tracks)
	}

	// Clearing optional fields and keeping the file name.
	response = api.do(t, http.MethodPatch, "/api/v1/tracks/a1", `{"version":2,"title":"New title"}`, api.alice)
	cleared := decode[trackResponse](t, response)
	if response.Code != http.StatusOK || cleared.FileName != "آهنگ تازه.mp3" || cleared.Album != nil ||
		cleared.Year != nil || cleared.Comment != nil || cleared.Version != 3 {
		t.Fatalf("clear: %d %+v", response.Code, cleared)
	}

	expectError(t, api.do(t, http.MethodPatch, "/api/v1/tracks/p1", `{"version":1,"title":"Hidden"}`, api.alice), http.StatusNotFound, "not_found")
}

func TestUpdateTrackMetadataVersioning(t *testing.T) {
	api := newTracksAPI(t, sampleTracks())

	// The version may come from If-Match instead of the body.
	request := httptest.NewRequest(http.MethodPatch, "/api/v1/tracks/a1", strings.NewReader(`{"title":"First"}`))
	request.Header.Set("Authorization", "Bearer "+api.alice)
	request.Header.Set("If-Match", `"1"`)
	response := httptest.NewRecorder()
	api.handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK || decode[trackResponse](t, response).Version != 2 {
		t.Fatalf("If-Match update: %d %s", response.Code, response.Body.String())
	}

	// A second editor still on version 1 must not overwrite "First".
	response = api.do(t, http.MethodPatch, "/api/v1/tracks/a1", `{"version":1,"title":"Stale"}`, api.alice)
	if response.Code != http.StatusConflict {
		t.Fatalf("stale update: expected 409, got %d: %s", response.Code, response.Body.String())
	}
	conflict := decode[conflictResponse](t, response)
	if conflict.Error != "version_conflict" || conflict.Track.Title != "First" || conflict.Track.Version != 2 {
		t.Fatalf("conflict body = %+v", conflict)
	}
	if got := decode[trackResponse](t, api.get(t, "/api/v1/tracks/a1", api.alice)); got.Title != "First" {
		t.Fatalf("stale edit overwrote the track: %+v", got)
	}

	for _, body := range []string{`{"title":"No version"}`, `{"version":0,"title":"Zero"}`, `{"version":-1,"title":"Negative"}`} {
		expectError(t, api.do(t, http.MethodPatch, "/api/v1/tracks/a1", body, api.alice), http.StatusPreconditionRequired, "version_required")
	}
	// Another user's track is still not found, never a conflict.
	expectError(t, api.do(t, http.MethodPatch, "/api/v1/tracks/b1", `{"version":9,"title":"Stolen"}`, api.alice), http.StatusNotFound, "not_found")
}

func TestUpdateTrackMetadataValidation(t *testing.T) {
	api := newTracksAPI(t, sampleTracks())
	long := strings.Repeat("x", 201)
	cases := []struct {
		name, body, field string
	}{
		{"missing title", `{"version":1,"artist":"Artist"}`, "title"},
		{"empty title", `{"version":1,"title":"   "}`, "title"},
		{"multi-line title", `{"version":1,"title":"a\nb"}`, "title"},
		{"long title", `{"version":1,"title":"` + long + `"}`, "title"},
		{"long artist", `{"version":1,"title":"Song","artist":"` + long + `"}`, "artist"},
		{"long album", `{"version":1,"title":"Song","album":"` + long + `"}`, "album"},
		{"long album artist", `{"version":1,"title":"Song","albumArtist":"` + long + `"}`, "albumArtist"},
		{"long composer", `{"version":1,"title":"Song","composer":"` + long + `"}`, "composer"},
		{"control genre", `{"version":1,"title":"Song","genre":"Rock\u0000"}`, "genre"},
		{"long comment", `{"version":1,"title":"Song","comment":"` + strings.Repeat("ک", 1001) + `"}`, "comment"},
		{"changed extension", `{"version":1,"fileName":"song.flac","title":"Song"}`, "fileName"},
		{"dropped extension", `{"version":1,"fileName":"song","title":"Song"}`, "fileName"},
		{"empty file name", `{"version":1,"fileName":" ","title":"Song"}`, "fileName"},
		{"path traversal", `{"version":1,"fileName":"../../other/song.mp3","title":"Song"}`, "fileName"},
		{"windows traversal", `{"version":1,"fileName":"..\\song.mp3","title":"Song"}`, "fileName"},
		{"bidi spoofed extension", `{"version":1,"fileName":"song\u202e3pm.mp3","title":"Song"}`, "fileName"},
		{"long file name", `{"version":1,"fileName":"` + long + `.mp3","title":"Song"}`, "fileName"},
		{"bad year", `{"version":1,"title":"Song","year":10000}`, "year"},
		{"negative year", `{"version":1,"title":"Song","year":-1}`, "year"},
		{"zero track number", `{"version":1,"title":"Song","trackNumber":0}`, "trackNumber"},
		{"huge track number", `{"version":1,"title":"Song","trackNumber":1000}`, "trackNumber"},
		{"zero disc number", `{"version":1,"title":"Song","discNumber":0}`, "discNumber"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			response := api.do(t, http.MethodPatch, "/api/v1/tracks/a1", tc.body, api.alice)
			if response.Code != http.StatusBadRequest {
				t.Fatalf("expected 400, got %d: %s", response.Code, response.Body.String())
			}
			if got := decode[metadataErrorResponse](t, response); got.Error != "invalid_metadata" || got.Field != tc.field {
				t.Fatalf("error = %+v, want field %q", got, tc.field)
			}
		})
	}
	for name, body := range map[string]string{
		"unknown field":  `{"version":1,"title":"Song","owner":"bob"}`,
		"trailing data":  `{"version":1,"title":"Song"} {}`,
		"wrong type":     `{"version":1,"title":"Song","year":"2020"}`,
		"oversized body": `{"version":1,"title":"Song","comment":"` + strings.Repeat("x", 30<<10) + `"}`,
	} {
		t.Run(name, func(t *testing.T) {
			expectError(t, api.do(t, http.MethodPatch, "/api/v1/tracks/a1", body, api.alice), http.StatusBadRequest, "invalid_json")
		})
	}
	if got := decode[trackResponse](t, api.get(t, "/api/v1/tracks/a1", api.alice)); got.Title != "Alice song" || got.Version != 1 {
		t.Fatalf("rejected edits changed the track: %+v", got)
	}
}

func TestOtherUsersTracksAreNotFound(t *testing.T) {
	for name, tracks := range map[string]*memoryTracks{
		"scoped store": sampleTracks(),
		"leaky store":  func() *memoryTracks { m := sampleTracks(); m.leaky = true; return m }(),
	} {
		t.Run(name, func(t *testing.T) {
			api := newTracksAPI(t, tracks)
			api.objects.objects["users/bob/tracks/b1/song.mp3"] = []byte("ID3")
			for _, request := range []struct{ method, path, body string }{
				{http.MethodGet, "/api/v1/tracks/b1", ""},
				{http.MethodGet, "/api/v1/tracks/b1/stream", ""},
				{http.MethodGet, "/api/v1/tracks/b1/download", ""},
				{http.MethodPatch, "/api/v1/tracks/b1", `{"version":1,"title":"Stolen"}`},
				{http.MethodPost, "/api/v1/tracks/b1/complete", ""},
				{http.MethodDelete, "/api/v1/tracks/b1", ""},
			} {
				expectError(t, api.do(t, request.method, request.path, request.body, api.alice), http.StatusNotFound, "not_found")
			}
			// Same answer as a track that does not exist at all.
			expectError(t, api.get(t, "/api/v1/tracks/missing", api.alice), http.StatusNotFound, "not_found")
			if len(api.objects.signed) != 0 {
				t.Fatalf("presigned %v for another user", api.objects.signed)
			}
			if !tracks.has("b1") || api.objects.objects["users/bob/tracks/b1/song.mp3"] == nil {
				t.Fatal("alice deleted bob's track")
			}
		})
	}
}

func TestTracksRequireAuthentication(t *testing.T) {
	api := newTracksAPI(t, sampleTracks())
	for _, request := range []struct{ method, path string }{
		{http.MethodGet, "/api/v1/tracks"},
		{http.MethodGet, "/api/v1/tracks/a1"},
		{http.MethodGet, "/api/v1/tracks/a1/stream"},
		{http.MethodGet, "/api/v1/tracks/a1/download"},
		{http.MethodPatch, "/api/v1/tracks/a1"},
		{http.MethodPost, "/api/v1/tracks/uploads"},
		{http.MethodPost, "/api/v1/tracks/a1/complete"},
		{http.MethodDelete, "/api/v1/tracks/a1"},
	} {
		expectError(t, api.do(t, request.method, request.path, "", ""), http.StatusUnauthorized, "unauthorized")
		expectError(t, api.do(t, request.method, request.path, "", "forged"), http.StatusUnauthorized, "unauthorized")
	}
}

func (a tracksAPI) createUpload(t *testing.T, body string) createUploadResponse {
	t.Helper()
	response := a.do(t, http.MethodPost, "/api/v1/tracks/uploads", body, a.alice)
	if response.Code != http.StatusCreated {
		t.Fatalf("create upload: expected 201, got %d: %s", response.Code, response.Body.String())
	}
	return decode[createUploadResponse](t, response)
}

func TestUploadLifecycle(t *testing.T) {
	api := newTracksAPI(t, &memoryTracks{})

	created := api.createUpload(t, `{"fileName":"آهنگ من.mp3","sizeBytes":6,"artist":" Artist "}`)
	if created.Track.Title != "آهنگ من" || *created.Track.Artist != "Artist" || created.Track.ContentType != "audio/mpeg" ||
		created.Track.FileName != "آهنگ من.mp3" || created.Track.Version != 1 {
		t.Fatalf("unexpected track %+v", created.Track)
	}
	key := created.Upload.Fields["key"]
	if !strings.HasPrefix(key, "users/alice/tracks/"+created.Track.ID+"/") || !strings.HasSuffix(key, "/track.mp3") {
		t.Fatalf("upload key %q is not owner-scoped and sanitized", key)
	}
	id := created.Track.ID

	// A pending track is invisible until it is completed.
	if list := decode[trackListResponse](t, api.get(t, "/api/v1/tracks", api.alice)); len(list.Tracks) != 0 {
		t.Fatalf("pending track listed: %+v", list.Tracks)
	}
	expectError(t, api.get(t, "/api/v1/tracks/"+id+"/stream", api.alice), http.StatusNotFound, "not_found")
	expectError(t, api.do(t, http.MethodPost, "/api/v1/tracks/"+id+"/complete", "", api.alice), http.StatusConflict, "upload_missing")

	api.objects.objects[key] = []byte("ID3\x04\x00\x00")
	completed := api.do(t, http.MethodPost, "/api/v1/tracks/"+id+"/complete", "", api.alice)
	if completed.Code != http.StatusOK {
		t.Fatalf("complete: expected 200, got %d: %s", completed.Code, completed.Body.String())
	}
	if again := api.do(t, http.MethodPost, "/api/v1/tracks/"+id+"/complete", "", api.alice); again.Code != http.StatusOK {
		t.Fatalf("completing twice should be harmless, got %d", again.Code)
	}
	if api.fingerprints.calls != 1 {
		t.Fatalf("the fingerprint worker was woken %d times, want once", api.fingerprints.calls)
	}
	if list := decode[trackListResponse](t, api.get(t, "/api/v1/tracks", api.alice)); len(list.Tracks) != 1 {
		t.Fatalf("completed track not listed: %+v", list.Tracks)
	}

	if response := api.do(t, http.MethodDelete, "/api/v1/tracks/"+id, "", api.alice); response.Code != http.StatusNoContent {
		t.Fatalf("delete: expected 204, got %d", response.Code)
	}
	if api.tracks.has(id) || api.objects.objects[key] != nil {
		t.Fatal("delete left the track or object behind")
	}
}

func TestCompleteRejectsFilesThatAreNotTheDeclaredAudio(t *testing.T) {
	for name, content := range map[string]string{
		"wrong size":        "ID3\x04",
		"not an audio file": "<html>",
	} {
		t.Run(name, func(t *testing.T) {
			api := newTracksAPI(t, &memoryTracks{})
			created := api.createUpload(t, `{"fileName":"song.mp3","sizeBytes":6}`)
			key := created.Upload.Fields["key"]
			api.objects.objects[key] = []byte(content)

			response := api.do(t, http.MethodPost, "/api/v1/tracks/"+created.Track.ID+"/complete", "", api.alice)
			expectError(t, response, http.StatusUnprocessableEntity, "invalid_audio")
			if api.tracks.has(created.Track.ID) || api.objects.objects[key] != nil {
				t.Fatal("rejected upload was not cleaned up")
			}
		})
	}
}

func TestCreateUploadValidation(t *testing.T) {
	api := newTracksAPI(t, &memoryTracks{})
	cases := []struct {
		name, body string
		status     int
		code       string
	}{
		{"unknown field", `{"fileName":"a.mp3","sizeBytes":1,"owner":"bob"}`, http.StatusBadRequest, "invalid_json"},
		{"not audio", `{"fileName":"notes.txt","sizeBytes":1}`, http.StatusUnsupportedMediaType, "unsupported_format"},
		{"empty file", `{"fileName":"a.mp3","sizeBytes":0}`, http.StatusRequestEntityTooLarge, "invalid_size"},
		{"too large", `{"fileName":"a.mp3","sizeBytes":1001}`, http.StatusRequestEntityTooLarge, "invalid_size"},
		{"long title", `{"fileName":"a.mp3","sizeBytes":1,"title":"` + strings.Repeat("x", 201) + `"}`, http.StatusBadRequest, "invalid_metadata"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			expectError(t, api.do(t, http.MethodPost, "/api/v1/tracks/uploads", tc.body, api.alice), tc.status, tc.code)
		})
	}
	if len(api.tracks.tracks) != 0 {
		t.Fatalf("invalid requests created tracks: %+v", api.tracks.tracks)
	}
}

func TestUploadReservationsEnforceOwnerQuota(t *testing.T) {
	tracks := &memoryTracks{tracks: []store.Track{{
		ID: "existing", OwnerID: "alice", Status: store.TrackReady,
		SizeBytes: testOwnerQuota - 5,
	}}}
	api := newTracksAPI(t, tracks)

	response := api.do(t, http.MethodPost, "/api/v1/tracks/uploads",
		`{"fileName":"song.mp3","sizeBytes":6}`, api.alice)
	expectError(t, response, http.StatusRequestEntityTooLarge, "quota_exceeded")
	if len(tracks.tracks) != 1 {
		t.Fatalf("quota rejection created a reservation: %+v", tracks.tracks)
	}
}

func TestUploadReservationsLimitPendingTracks(t *testing.T) {
	api := newTracksAPI(t, &memoryTracks{})
	for i := 0; i < testMaxPending; i++ {
		api.createUpload(t, `{"fileName":"song.mp3","sizeBytes":1}`)
	}

	response := api.do(t, http.MethodPost, "/api/v1/tracks/uploads",
		`{"fileName":"one-too-many.mp3","sizeBytes":1}`, api.alice)
	expectError(t, response, http.StatusTooManyRequests, "too_many_pending_uploads")
	if response.Header().Get("Retry-After") == "" {
		t.Fatal("pending limit response must tell the client when to retry")
	}
}

func TestUploadsCanBeDisabledWithoutDisablingPlayback(t *testing.T) {
	tracks := sampleTracks()
	api := newTracksAPIWithLimits(t, tracks, UploadLimits{
		MaxFileBytes: testMaxUpload, MaxOwnerBytes: testOwnerQuota,
		MaxPending: testMaxPending, Enabled: false,
	})

	expectError(t, api.do(t, http.MethodPost, "/api/v1/tracks/uploads",
		`{"fileName":"song.mp3","sizeBytes":1}`, api.alice),
		http.StatusServiceUnavailable, "uploads_disabled")
	if response := api.get(t, "/api/v1/tracks/a1", api.alice); response.Code != http.StatusOK {
		t.Fatalf("disabling uploads also disabled playback metadata: %d", response.Code)
	}
}

func TestUploadReservationRateLimitIsPerUserAndIP(t *testing.T) {
	limits := UploadLimits{
		MaxFileBytes: testMaxUpload, MaxOwnerBytes: testOwnerQuota,
		MaxPending: testMaxPending, Enabled: true,
		ReservationUserRate: NewRateLimiter(
			RateLimit{Requests: 1, Window: time.Minute}, 10,
		),
		ReservationIPRate: NewRateLimiter(
			RateLimit{Requests: 10, Window: time.Minute}, 10,
		),
	}
	api := newTracksAPIWithLimits(t, &memoryTracks{}, limits)
	api.createUpload(t, `{"fileName":"first.mp3","sizeBytes":1}`)

	response := api.do(t, http.MethodPost, "/api/v1/tracks/uploads",
		`{"fileName":"second.mp3","sizeBytes":1}`, api.alice)
	expectError(t, response, http.StatusTooManyRequests, "rate_limited")
	if response.Header().Get("Retry-After") == "" {
		t.Fatal("rate limit response is missing Retry-After")
	}

	// A different authenticated user on the same IP has an independent user+IP key.
	response = api.do(t, http.MethodPost, "/api/v1/tracks/uploads",
		`{"fileName":"bob.mp3","sizeBytes":1}`, api.bob)
	if response.Code != http.StatusCreated {
		t.Fatalf("bob was limited by alice: %d %s", response.Code, response.Body.String())
	}
}

func TestUploadReservationIPLimitCoversMultipleUsers(t *testing.T) {
	limits := UploadLimits{
		MaxFileBytes: testMaxUpload, MaxOwnerBytes: testOwnerQuota,
		MaxPending: testMaxPending, Enabled: true,
		ReservationUserRate: NewRateLimiter(
			RateLimit{Requests: 10, Window: time.Minute}, 10,
		),
		ReservationIPRate: NewRateLimiter(
			RateLimit{Requests: 1, Window: time.Minute}, 10,
		),
	}
	api := newTracksAPIWithLimits(t, &memoryTracks{}, limits)
	api.createUpload(t, `{"fileName":"alice.mp3","sizeBytes":1}`)

	response := api.do(t, http.MethodPost, "/api/v1/tracks/uploads",
		`{"fileName":"bob.mp3","sizeBytes":1}`, api.bob)
	expectError(t, response, http.StatusTooManyRequests, "rate_limited")
}

type countingImports map[string]int

func (c countingImports) ActiveImports(_ context.Context, userID string) (int, error) {
	return c[userID], nil
}

func TestTrackListReportsBotImportsInProgress(t *testing.T) {
	api := newTracksAPI(t, &memoryTracks{})
	tokens, _ := auth.NewTokens([]byte(strings.Repeat("k", auth.MinSecretBytes)), time.Hour)
	handlers := NewTrackHandlers(api.tracks, api.objects, tokens, UploadLimits{MaxOwnerBytes: testOwnerQuota}).
		WithImports(countingImports{"alice": 2})
	handler := NewHandler(Config{Tracks: handlers})

	request := httptest.NewRequest(http.MethodGet, "/api/v1/tracks", nil)
	request.Header.Set("Authorization", "Bearer "+api.alice)
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)

	var body trackListResponse
	json.NewDecoder(response.Body).Decode(&body)
	if response.Code != http.StatusOK || body.ImportsInProgress != 2 {
		t.Fatalf("list = %d, importsInProgress %d", response.Code, body.ImportsInProgress)
	}
}

type countingNotifier struct{ calls int }

func (n *countingNotifier) Notify() { n.calls++ }

func TestUpdateTrackMetadataQueuesEmbeddedTagRewrite(t *testing.T) {
	tracks := &memoryTracks{tracks: []store.Track{
		{ID: "a1", OwnerID: "alice", Status: store.TrackReady, Title: "MP3", FileName: "song.mp3", StorageKey: "users/alice/tracks/a1/song.mp3", ContentType: "audio/mpeg", MetadataVersion: 1, TagStatus: store.TagOriginal},
		{ID: "a2", OwnerID: "alice", Status: store.TrackReady, Title: "M4A", FileName: "song.m4a", StorageKey: "users/alice/tracks/a2/song.m4a", ContentType: "audio/mp4", MetadataVersion: 1, TagStatus: store.TagOriginal},
	}}
	tokens, err := auth.NewTokens([]byte(strings.Repeat("k", auth.MinSecretBytes)), time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	alice, _, _ := tokens.Issue("alice")
	notifier := &countingNotifier{}
	handler := NewHandler(Config{Tracks: NewTrackHandlers(tracks, &fakeObjects{objects: map[string][]byte{}}, tokens, UploadLimits{}).WithTagRewrites(notifier)})
	api := tracksAPI{handler: handler, tracks: tracks, alice: alice}

	before := decode[trackResponse](t, api.get(t, "/api/v1/tracks/a1", alice))
	if before.EmbeddedTags.Status != store.TagOriginal || len(before.EmbeddedTags.UnsupportedFields) != 0 {
		t.Fatalf("before edit: %+v", before.EmbeddedTags)
	}
	mp3 := decode[trackResponse](t, api.do(t, http.MethodPatch, "/api/v1/tracks/a1", `{"version":1,"title":"New"}`, alice))
	if mp3.EmbeddedTags.Status != store.TagPending || notifier.calls != 1 {
		t.Fatalf("mp3 edit: %+v, %d notifications", mp3.EmbeddedTags, notifier.calls)
	}
	m4a := decode[trackResponse](t, api.do(t, http.MethodPatch, "/api/v1/tracks/a2", `{"version":1,"title":"New"}`, alice))
	if m4a.EmbeddedTags.Status != store.TagUnsupported || len(m4a.EmbeddedTags.UnsupportedFields) != 10 || notifier.calls != 1 {
		t.Fatalf("m4a edit: %+v, %d notifications", m4a.EmbeddedTags, notifier.calls)
	}
}

func TestDownloadUsesEditedNameAndNeverServesStaleTags(t *testing.T) {
	written, original := int64(2), store.TagOriginal
	tracks := &memoryTracks{tracks: []store.Track{
		{ID: "a1", OwnerID: "alice", Status: store.TrackReady, Title: "Song", FileName: "آهنگ «تازه».mp3", StorageKey: "users/alice/tracks/a1/v2-1/track.mp3", ContentType: "audio/mpeg", SizeBytes: 9, MetadataVersion: 2, TagStatus: store.TagWritten, TagVersion: &written},
		{ID: "a2", OwnerID: "alice", Status: store.TrackReady, Title: "Old", FileName: "old.flac", StorageKey: "users/alice/tracks/a2/old.flac", ContentType: "audio/flac", MetadataVersion: 1, TagStatus: original},
		{ID: "a3", OwnerID: "alice", Status: store.TrackReady, Title: "M4A", FileName: "song.m4a", StorageKey: "users/alice/tracks/a3/song.m4a", ContentType: "audio/mp4", MetadataVersion: 3, TagStatus: store.TagUnsupported},
		{ID: "p1", OwnerID: "alice", Status: store.TrackPending, Title: "Pending", FileName: "p.mp3", StorageKey: "users/alice/tracks/p1/p.mp3", ContentType: "audio/mpeg", MetadataVersion: 1},
	}}
	api := newTracksAPI(t, tracks)

	response := api.get(t, "/api/v1/tracks/a1/download", api.alice)
	if response.Code != http.StatusOK || response.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("download: %d %s", response.Code, response.Body.String())
	}
	download := decode[downloadResponse](t, response)
	signed, err := url.Parse(download.URL)
	if err != nil {
		t.Fatal(err)
	}
	wantDisposition := `attachment; filename="track.mp3"; filename*=UTF-8''%D8%A2%D9%87%D9%86%DA%AF%20%C2%AB%D8%AA%D8%A7%D8%B2%D9%87%C2%BB.mp3`
	if download.FileName != "آهنگ «تازه».mp3" || !download.TagsUpToDate || download.Version != 2 ||
		signed.Path != "/nafir-music/users/alice/tracks/a1/v2-1/track.mp3" ||
		signed.Query().Get("response-content-disposition") != wantDisposition ||
		signed.Query().Get("response-content-type") != "audio/mpeg" {
		t.Fatalf("download = %+v (disposition %q)", download, signed.Query().Get("response-content-disposition"))
	}

	// An edit makes the stored file stale until its tags are rewritten.
	if edit := api.do(t, http.MethodPatch, "/api/v1/tracks/a1", `{"version":2,"title":"Newer"}`, api.alice); edit.Code != http.StatusOK {
		t.Fatalf("edit: %d %s", edit.Code, edit.Body.String())
	}
	response = api.get(t, "/api/v1/tracks/a1/download", api.alice)
	if response.Code != http.StatusConflict || response.Header().Get("Retry-After") == "" {
		t.Fatalf("download during rewrite: %d %s", response.Code, response.Body.String())
	}
	if pending := decode[conflictResponse](t, response); pending.Error != "tags_pending" || pending.Track.EmbeddedTags.Status != store.TagPending {
		t.Fatalf("pending body = %+v", pending)
	}

	if d := decode[downloadResponse](t, api.get(t, "/api/v1/tracks/a2/download", api.alice)); !d.TagsUpToDate || d.FileName != "old.flac" {
		t.Fatalf("never edited: %+v", d)
	}
	if d := decode[downloadResponse](t, api.get(t, "/api/v1/tracks/a3/download", api.alice)); d.TagsUpToDate || len(d.EmbeddedTags.UnsupportedFields) == 0 {
		t.Fatalf("unsupported format: %+v", d)
	}
	expectError(t, api.get(t, "/api/v1/tracks/p1/download", api.alice), http.StatusNotFound, "not_found")
	expectError(t, api.get(t, "/api/v1/tracks/a1/download", ""), http.StatusUnauthorized, "unauthorized")
}
