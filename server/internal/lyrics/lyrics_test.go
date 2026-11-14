package lyrics

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func ptr(s string) *string { return &s }

// fakeLRCLIB serves records like LRCLIB's API and counts requests.
type fakeLRCLIB struct {
	records  []Record
	requests atomic.Int32
	// status, when set, is answered to every request instead.
	status atomic.Int32
	// exactStatus, when set, is answered to exact lookups (/api/get) only.
	exactStatus atomic.Int32
	delay       time.Duration
	mu          sync.Mutex
	agents      []string
	paths       []string
}

func (f *fakeLRCLIB) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.requests.Add(1)
	f.mu.Lock()
	f.agents = append(f.agents, r.Header.Get("User-Agent"))
	f.paths = append(f.paths, r.URL.Path+"?"+r.URL.RawQuery)
	f.mu.Unlock()
	if f.delay > 0 {
		select {
		case <-time.After(f.delay):
		case <-r.Context().Done():
			return
		}
	}
	if status := f.status.Load(); status != 0 {
		w.WriteHeader(int(status))
		return
	}
	if status := f.exactStatus.Load(); status != 0 && r.URL.Path == "/api/get" {
		w.WriteHeader(int(status))
		return
	}
	q := r.URL.Query()
	notFound := func() {
		w.WriteHeader(http.StatusNotFound)
		_, _ = w.Write([]byte(`{"code":404,"name":"TrackNotFound","message":"Failed to find specified track"}`))
	}
	switch {
	case strings.HasPrefix(r.URL.Path, "/api/get/"):
		id, _ := strconv.ParseInt(strings.TrimPrefix(r.URL.Path, "/api/get/"), 10, 64)
		for _, rec := range f.records {
			if rec.ID == id {
				_ = json.NewEncoder(w).Encode(rec)
				return
			}
		}
		notFound()
	case r.URL.Path == "/api/get":
		duration, _ := strconv.ParseFloat(q.Get("duration"), 64)
		for _, rec := range f.records {
			if rec.TrackName == q.Get("track_name") && rec.ArtistName == q.Get("artist_name") &&
				(q.Get("duration") == "" || abs(rec.Duration-duration) <= 2) {
				_ = json.NewEncoder(w).Encode(rec)
				return
			}
		}
		notFound()
	case r.URL.Path == "/api/search":
		found := []Record{}
		for _, rec := range f.records {
			text := strings.ToLower(rec.TrackName + " " + rec.ArtistName + " " + rec.AlbumName)
			switch {
			case q.Get("q") != "" && strings.Contains(text, strings.ToLower(q.Get("q"))):
			case q.Get("q") == "" && strings.Contains(strings.ToLower(rec.TrackName), strings.ToLower(q.Get("track_name"))) &&
				strings.Contains(strings.ToLower(rec.ArtistName), strings.ToLower(q.Get("artist_name"))):
			default:
				continue
			}
			found = append(found, rec)
		}
		_ = json.NewEncoder(w).Encode(found)
	default:
		http.NotFound(w, r)
	}
}

func abs(x float64) float64 {
	if x < 0 {
		return -x
	}
	return x
}

// memoryCache is a lyrics.Cache in memory.
type memoryCache struct {
	mu      sync.Mutex
	entries map[string]Entry
}

func (c *memoryCache) Lyrics(_ context.Context, trackID string) (Entry, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	e, ok := c.entries[trackID]
	if !ok {
		return Entry{}, ErrNotCached
	}
	return e, nil
}

func (c *memoryCache) SaveLyrics(_ context.Context, e Entry) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.entries == nil {
		c.entries = map[string]Entry{}
	}
	c.entries[e.TrackID] = e
	return nil
}

var catalogue = []Record{
	{ID: 1, TrackName: "Sultans of Swing", ArtistName: "Dire Straits", AlbumName: "Dire Straits", Duration: 348,
		PlainLyrics: ptr("You get a shiver in the dark"), SyncedLyrics: ptr("[00:01.00]You get a shiver in the dark")},
	// Same song, a live version: much longer, plain lyrics only.
	{ID: 2, TrackName: "Sultans of Swing", ArtistName: "Dire Straits", AlbumName: "Alchemy", Duration: 650,
		PlainLyrics: ptr("live")},
	{ID: 3, TrackName: "گل پامچال", ArtistName: "محسن نامجو", Duration: 240,
		PlainLyrics: ptr("گل پامچال"), SyncedLyrics: ptr("[00:10.50]گل پامچال")},
	{ID: 4, TrackName: "Intro", ArtistName: "Somebody", Duration: 60, Instrumental: true},
	{ID: 5, TrackName: "Empty", ArtistName: "Nobody", Duration: 100},
}

func newTestService(t *testing.T, fake *fakeLRCLIB, config ClientConfig) (*Service, *memoryCache, *time.Time) {
	t.Helper()
	server := httptest.NewServer(fake)
	t.Cleanup(server.Close)
	config.BaseURL = server.URL
	if config.Interval == 0 {
		config.Interval = time.Nanosecond
	}
	client, err := NewClient(config)
	if err != nil {
		t.Fatal(err)
	}
	cache := &memoryCache{}
	service := NewService(client, cache, time.Hour, time.Minute)
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	service.now = func() time.Time { return now }
	return service, cache, &now
}

func TestMatching(t *testing.T) {
	fake := &fakeLRCLIB{records: catalogue}
	service, _, _ := newTestService(t, fake, ClientConfig{})
	ctx := context.Background()
	cases := []struct {
		name  string
		query Query
		want  int64
	}{
		{"exact lookup", Query{Title: "Sultans of Swing", Artist: "Dire Straits", Album: "Dire Straits", Duration: 347 * time.Second}, 1},
		{"length picks the live version", Query{Title: "Sultans of Swing", Artist: "Dire Straits", Duration: 651 * time.Second}, 2},
		{"unknown length prefers synced lyrics", Query{Title: "sultans of swing", Artist: "dire straits"}, 1},
		{"title only", Query{Title: "sultans of swing"}, 1},
		{"Persian with Arabic letters", Query{Title: "گل پامچال", Artist: "محسن نامجو"}, 3},
		{"instrumental", Query{Title: "Intro", Artist: "Somebody"}, 4},
		{"wrong artist", Query{Title: "Sultans of Swing", Artist: "Someone Else"}, 0},
		{"length too far off", Query{Title: "گل پامچال", Duration: 300 * time.Second}, 0},
		{"no lyrics at all", Query{Title: "Empty", Artist: "Nobody"}, 0},
		{"unknown song", Query{Title: "Nothing like it"}, 0},
		{"no title", Query{Artist: "Dire Straits"}, 0},
	}
	for i, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			entry, err := service.ForSong(ctx, Song{TrackID: strconv.Itoa(i), Query: c.query})
			if err != nil {
				t.Fatal(err)
			}
			if c.want == 0 {
				if entry.Found {
					t.Fatalf("found %+v, want none", entry.Record)
				}
				return
			}
			if !entry.Found || entry.Record.ID != c.want {
				t.Fatalf("found %v %d, want %d", entry.Found, entry.Record.ID, c.want)
			}
		})
	}
	for _, agent := range fake.agents {
		if agent != UserAgent {
			t.Fatalf("User-Agent = %q", agent)
		}
	}
}

func TestPersianNormalization(t *testing.T) {
	if normalize("علي   كوچك‌زاده!") != normalize("علی کوچک زاده") {
		t.Fatalf("%q != %q", normalize("علي   كوچك‌زاده!"), normalize("علی کوچک زاده"))
	}
}

func TestCaching(t *testing.T) {
	fake := &fakeLRCLIB{records: catalogue}
	service, cache, now := newTestService(t, fake, ClientConfig{})
	ctx := context.Background()
	song := Song{TrackID: "t1", Query: Query{Title: "Sultans of Swing", Artist: "Dire Straits", Duration: 348 * time.Second}}

	first, err := service.ForSong(ctx, song)
	if err != nil || !first.Found {
		t.Fatalf("first lookup = %+v, %v", first, err)
	}
	asked := fake.requests.Load()
	if _, err := service.ForSong(ctx, song); err != nil {
		t.Fatal(err)
	}
	if fake.requests.Load() != asked {
		t.Fatal("a fresh cached entry asked LRCLIB again")
	}

	// A miss is cached too, for its own shorter time.
	missing := Song{TrackID: "t2", Query: Query{Title: "Nothing like it", Artist: "Nobody"}}
	if entry, err := service.ForSong(ctx, missing); err != nil || entry.Found {
		t.Fatalf("miss = %+v, %v", entry, err)
	}
	asked = fake.requests.Load()
	if _, err := service.ForSong(ctx, missing); err != nil || fake.requests.Load() != asked {
		t.Fatal("a cached miss asked LRCLIB again")
	}
	*now = now.Add(2 * time.Minute)
	if _, err := service.ForSong(ctx, missing); err != nil || fake.requests.Load() == asked {
		t.Fatal("an expired miss was not looked up again")
	}

	// Editing the title or artist makes the cached lyrics stale.
	asked = fake.requests.Load()
	edited := song
	edited.Title = "گل پامچال"
	edited.Artist = "محسن نامجو"
	edited.Duration = 0
	entry, err := service.ForSong(ctx, edited)
	if err != nil || entry.Record.ID != 3 || fake.requests.Load() == asked {
		t.Fatalf("after an edit = %+v, %v", entry.Record, err)
	}

	// Once expired, LRCLIB failing still serves the stale lyrics.
	*now = now.Add(2 * time.Hour)
	fake.status.Store(http.StatusInternalServerError)
	entry, err = service.ForSong(ctx, edited)
	if err != nil || entry.Record.ID != 3 {
		t.Fatalf("stale fallback = %+v, %v", entry, err)
	}
	// With nothing cached, the failure is reported.
	if _, err := service.ForSong(ctx, Song{TrackID: "t3", Query: song.Query}); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("uncached failure = %v", err)
	}
	if _, ok := cache.entries["t3"]; ok {
		t.Fatal("a failed lookup was cached as a miss")
	}
}

func TestChoosing(t *testing.T) {
	fake := &fakeLRCLIB{records: catalogue}
	service, _, now := newTestService(t, fake, ClientConfig{})
	ctx := context.Background()
	song := Song{TrackID: "t1", Query: Query{Title: "Sultans of Swing", Artist: "Dire Straits"}}

	candidates, err := service.Candidates(ctx, song.Query, "")
	if err != nil || len(candidates) != 2 {
		t.Fatalf("candidates = %+v, %v", candidates, err)
	}
	if found, err := service.Candidates(ctx, song.Query, "نامجو"); err != nil || len(found) != 1 || found[0].ID != 3 {
		t.Fatalf("free text candidates = %+v, %v", found, err)
	}
	if found, err := service.Candidates(ctx, song.Query, "nobody"); err != nil || len(found) != 0 {
		t.Fatalf("records without lyrics are offered: %+v, %v", found, err)
	}

	chosen, err := service.Choose(ctx, song, 2)
	if err != nil || !chosen.Chosen || chosen.Record.ID != 2 {
		t.Fatalf("choose = %+v, %v", chosen, err)
	}
	if entry, _ := service.ForSong(ctx, song); entry.Record.ID != 2 || !entry.Chosen {
		t.Fatalf("the pick did not stick: %+v", entry)
	}
	// Refreshing an expired pick fetches the same record, not a new match.
	*now = now.Add(2 * time.Hour)
	if entry, _ := service.ForSong(ctx, song); entry.Record.ID != 2 || !entry.Chosen {
		t.Fatalf("refreshing replaced the pick: %+v", entry)
	}
	// An edit drops the pick.
	edited := song
	edited.Artist = "Another Band"
	if entry, _ := service.ForSong(ctx, edited); entry.Chosen || entry.Found {
		t.Fatalf("pick survived an edit: %+v", entry)
	}

	for _, id := range []int64{0, 99, 5} {
		if _, err := service.Choose(ctx, song, id); !errors.Is(err, ErrNotFound) {
			t.Fatalf("choose %d = %v", id, err)
		}
	}
}

func TestTimeoutAndRateLimit(t *testing.T) {
	fake := &fakeLRCLIB{records: catalogue, delay: time.Second}
	service, _, _ := newTestService(t, fake, ClientConfig{Timeout: 50 * time.Millisecond})
	_, err := service.ForSong(context.Background(), Song{TrackID: "t", Query: Query{Title: "Intro"}})
	if !errors.Is(err, ErrUnavailable) {
		t.Fatalf("timeout = %v", err)
	}

	limiter := &intervalLimiter{interval: time.Second, maxWait: 1500 * time.Millisecond}
	at := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	limiter.now = func() time.Time { return at }
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := limiter.wait(ctx); err != nil {
		t.Fatalf("first request waited: %v", err)
	}
	// The second must wait a second: with the context gone it gives up.
	if err := limiter.wait(ctx); !errors.Is(err, context.Canceled) {
		t.Fatalf("second request = %v", err)
	}
	// The third would wait two seconds, more than allowed.
	if err := limiter.wait(ctx); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("third request = %v", err)
	}
}

func TestClean(t *testing.T) {
	r := clean(Record{
		TrackName: strings.Repeat("x", 500), PlainLyrics: ptr(strings.Repeat("a", MaxLyricsBytes+1)),
		SyncedLyrics: ptr("  "), Duration: -1,
	})
	if len(r.TrackName) != maxFieldLength || r.PlainLyrics != nil || r.SyncedLyrics != nil || r.Duration != 0 {
		t.Fatalf("clean = %+v", r)
	}
	if r.HasLyrics() {
		t.Fatal("nothing left to show, yet HasLyrics")
	}
}

func TestNewClientRejectsBadURL(t *testing.T) {
	for _, raw := range []string{"ftp://lrclib.net", "lrclib.net", "http://"} {
		if _, err := NewClient(ClientConfig{BaseURL: raw}); err == nil {
			t.Fatalf("%q accepted", raw)
		}
	}
}

// A failing exact lookup used to fail the whole request with «متن آهنگ
// دریافت نشد» (#233), although the search alone finds the song.
func TestFailedExactLookupFallsBackToSearch(t *testing.T) {
	fake := &fakeLRCLIB{records: catalogue}
	fake.exactStatus.Store(http.StatusBadGateway)
	service, _, _ := newTestService(t, fake, ClientConfig{})
	var song Query
	for _, r := range catalogue {
		if r.ArtistName != "" && r.Duration > 0 && r.HasLyrics() {
			song = Query{Title: r.TrackName, Artist: r.ArtistName, Duration: time.Duration(r.Duration) * time.Second}
			break
		}
	}
	entry, err := service.ForSong(context.Background(), Song{TrackID: "t", Query: song})
	if err != nil || !entry.Found {
		t.Fatalf("lookup = %+v, %v; want found through search", entry, err)
	}
	if fake.requests.Load() != 2 {
		t.Fatalf("requests = %d, want exact lookup then search", fake.requests.Load())
	}
}
