package catalog

import (
	"context"
	"math/rand"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/mhdolatabadi/rhythmo/server/internal/fingerprint"
	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

func str(s string) *string    { return &s }
func secs(s float64) *float64 { return &s }

// recording is a made-up fingerprint of seconds of audio; the same seed is
// the same recording.
func recording(seed int64, seconds float64) []uint32 {
	r := rand.New(rand.NewSource(seed))
	points := make([]uint32, int(time.Duration(seconds*float64(time.Second))/fingerprint.ItemDuration))
	for i := range points {
		points[i] = r.Uint32()
	}
	return points
}

// reencoded flips a few bits, as a different encoder of the same audio
// would.
func reencoded(points []uint32) []uint32 {
	r := rand.New(rand.NewSource(99))
	out := make([]uint32, len(points))
	for i, p := range points {
		out[i] = p ^ (1 << r.Intn(32)) ^ (1 << r.Intn(32))
	}
	return out
}

func TestTitleKey(t *testing.T) {
	for _, c := range []struct {
		track store.Track
		want  string
	}{
		{store.Track{Title: "Rain  Song!", Artist: str("Kayhan")}, "rain song|kayhan"},
		{store.Track{Title: "كتاب‌ها", Artist: str("علي")}, "کتاب ها|علی"},
		{store.Track{Title: "عَلَى", AlbumArtist: str("گروه")}, "علی|گروه"},
		{store.Track{Title: "song", Artist: str(" "), AlbumArtist: str("Band")}, "song|band"},
		{store.Track{ID: "t9", Title: "--"}, "track:t9"},
	} {
		if got := TitleKey(c.track); got != c.want {
			t.Errorf("TitleKey(%q) = %q, want %q", c.track.Title, got, c.want)
		}
	}
}

func TestDuplicate(t *testing.T) {
	song := recording(1, 200)
	other := recording(2, 200)
	candidates := []store.CatalogCandidate{
		{EntryID: "other", TitleKey: "song|band", DurationSeconds: secs(200), Points: fingerprint.Encode(other)},
		{EntryID: "song", TitleKey: "renamed|", DurationSeconds: secs(201), Points: fingerprint.Encode(song)},
		{EntryID: "named", TitleKey: "named|", DurationSeconds: secs(180)},
	}
	for _, c := range []struct {
		name     string
		key      string
		points   []uint32
		duration *float64
		want     string
	}{
		{"same sound, other name", "different|", reencoded(song), secs(200), "song"},
		{"same name, other sound", "song|band", recording(3, 200), secs(200), ""},
		{"too far apart", "different|", reencoded(song), secs(210), ""},
		{"by name without fingerprints", "named|", nil, secs(182), "named"},
		{"by name, unknown length", "named|", nil, nil, "named"},
		{"by name, length too far", "named|", nil, secs(190), ""},
		{"fingerprinted copy, unfingerprinted entry", "named|", recording(4, 180), secs(180), "named"},
		{"nothing alike", "new|", recording(5, 100), secs(100), ""},
	} {
		var points []byte
		if c.points != nil {
			points = fingerprint.Encode(c.points)
		}
		got, ok := Duplicate(c.key, points, c.duration, candidates)
		if got != c.want || ok != (c.want != "") {
			t.Errorf("%s: Duplicate = %q, %v; want %q", c.name, got, ok, c.want)
		}
	}
}

// newTestPool gives this package its own database, so it can run alongside
// the store tests, which reset theirs.
func newTestPool(t *testing.T) *pgxpool.Pool {
	t.Helper()
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("TEST_DATABASE_URL is not set")
	}
	ctx := context.Background()
	admin, err := pgx.Connect(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	defer admin.Close(ctx)
	const name = "rhythmo_catalog_test"
	if _, err := admin.Exec(ctx, "DROP DATABASE IF EXISTS "+name+" WITH (FORCE)"); err != nil {
		t.Fatal(err)
	}
	if _, err := admin.Exec(ctx, "CREATE DATABASE "+name); err != nil {
		t.Fatal(err)
	}
	config, err := pgxpool.ParseConfig(url)
	if err != nil {
		t.Fatal(err)
	}
	config.ConnConfig.Database = name
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

func TestFoldMatchesTheDatabase(t *testing.T) {
	pool := newTestPool(t)
	input := "ABC كتاب‌ها عَلِيّ ـــ ۀ أإآ ؤ ئ ى ة"
	var folded string
	if err := pool.QueryRow(context.Background(), `SELECT store_fold($1)`, input).Scan(&folded); err != nil {
		t.Fatal(err)
	}
	if got := Fold(input); got != folded {
		t.Fatalf("Fold = %q, store_fold = %q", got, folded)
	}
}

func TestIndexerGroupsCopiesIntoOneEntry(t *testing.T) {
	pool := newTestPool(t)
	ctx := context.Background()
	users, tracks, playlists := store.NewUsers(pool), store.NewTracks(pool), store.NewPlaylists(pool)
	fps, catalog := store.NewFingerprints(pool), store.NewCatalog(pool)
	duration := int32(200_000)
	add := func(email, title string, points []uint32) store.Track {
		t.Helper()
		user, err := users.Create(ctx, email, "hash")
		if err != nil {
			t.Fatal(err)
		}
		track, err := tracks.Create(ctx, user.ID, store.NewTrack{Title: title, FileName: "a.mp3",
			ContentType: "audio/mpeg", SizeBytes: 1000, DurationMS: &duration})
		if err != nil {
			t.Fatal(err)
		}
		if points != nil {
			if err := fps.SaveFingerprint(ctx, track.ID, fingerprint.Encode(points), 200*time.Second); err != nil {
				t.Fatal(err)
			}
		}
		playlist, _ := playlists.Create(ctx, user.ID, "mix")
		if err := playlists.ReplaceTracks(ctx, user.ID, playlist.ID, []string{track.ID}); err != nil {
			t.Fatal(err)
		}
		public := true
		if _, err := playlists.Share(ctx, user.ID, playlist.ID, "token-"+playlist.ID, &public, true); err != nil {
			t.Fatal(err)
		}
		return track
	}
	song := recording(1, 200)
	add("a@example.com", "Song", song)
	add("b@example.com", "Song (remaster)", reencoded(song))
	add("c@example.com", "Song", recording(2, 200))
	waiting := add("d@example.com", "Unfingerprinted", nil)

	indexer := NewIndexer(catalog, Config{Settle: time.Hour})
	if n, err := indexer.RunOnce(ctx); err != nil || n != 3 {
		t.Fatalf("first pass = %d, %v", n, err)
	}
	listed, _, err := catalog.StoreEntries(ctx, store.StoreQuery{Limit: 10})
	if err != nil || len(listed) != 2 {
		t.Fatalf("listed %+v, %v; want the remaster grouped with the original and the other song apart", listed, err)
	}
	copies := map[int]int{}
	for _, entry := range listed {
		copies[entry.Copies]++
	}
	if copies[2] != 1 || copies[1] != 1 {
		t.Fatalf("copies = %v", copies)
	}
	// The unfingerprinted copy is grouped by name once it has settled.
	_, _ = pool.Exec(ctx, `UPDATE tracks SET created_at = now() - interval '2 hours' WHERE id::text = $1`, waiting.ID)
	if n, err := indexer.RunOnce(ctx); err != nil || n != 1 {
		t.Fatalf("second pass = %d, %v", n, err)
	}
	if listed, _, _ := catalog.StoreEntries(ctx, store.StoreQuery{Limit: 10}); len(listed) != 3 {
		t.Fatalf("listed %d entries", len(listed))
	}
	if n, err := indexer.RunOnce(ctx); err != nil || n != 0 {
		t.Fatalf("idle pass = %d, %v", n, err)
	}
}
