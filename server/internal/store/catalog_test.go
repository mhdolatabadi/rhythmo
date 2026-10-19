package store

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"
)

type catalogFixture struct {
	t         *testing.T
	ctx       context.Context
	catalog   *Catalog
	tracks    *Tracks
	playlists *Playlists
	users     *Users
}

func newCatalogFixture(t *testing.T) catalogFixture {
	pool := newTestPool(t)
	return catalogFixture{t: t, ctx: context.Background(), catalog: NewCatalog(pool),
		tracks: NewTracks(pool), playlists: NewPlaylists(pool), users: NewUsers(pool)}
}

func (f catalogFixture) user(email string) User {
	f.t.Helper()
	user, err := f.users.Create(f.ctx, email, "hash")
	if err != nil {
		f.t.Fatal(err)
	}
	return user
}

func (f catalogFixture) track(ownerID string, track NewTrack) Track {
	f.t.Helper()
	if track.FileName == "" {
		track.FileName = "song.mp3"
	}
	if track.ContentType == "" {
		track.ContentType = "audio/mpeg"
	}
	if track.SizeBytes == 0 {
		track.SizeBytes = 1000
	}
	created, err := f.tracks.Create(f.ctx, ownerID, track)
	if err != nil {
		f.t.Fatal(err)
	}
	return created
}

// playlist makes a playlist of trackIDs, shared with a link and, when
// public, listed for everyone.
func (f catalogFixture) playlist(ownerID string, public bool, trackIDs ...string) Playlist {
	f.t.Helper()
	playlist, err := f.playlists.Create(f.ctx, ownerID, "mix")
	if err != nil {
		f.t.Fatal(err)
	}
	if err := f.playlists.ReplaceTracks(f.ctx, ownerID, playlist.ID, trackIDs); err != nil {
		f.t.Fatal(err)
	}
	playlist, err = f.playlists.Share(f.ctx, ownerID, playlist.ID, "token-"+playlist.ID, &public, true)
	if err != nil {
		f.t.Fatal(err)
	}
	return playlist
}

func (f catalogFixture) pending() []CatalogJob {
	f.t.Helper()
	jobs, err := f.catalog.PendingCatalogTracks(f.ctx, 100, 0)
	if err != nil {
		f.t.Fatal(err)
	}
	return jobs
}

func (f catalogFixture) listed(query StoreQuery) []StoreEntry {
	f.t.Helper()
	if query.Limit == 0 {
		query.Limit = 50
	}
	entries, _, err := f.catalog.StoreEntries(f.ctx, query)
	if err != nil {
		f.t.Fatal(err)
	}
	return entries
}

func (f catalogFixture) indexAll() {
	f.t.Helper()
	for _, job := range f.pending() {
		if err := f.catalog.NewEntry(f.ctx, job.Track.ID, "key:"+job.Track.ID, job.Points, nil); err != nil {
			f.t.Fatal(err)
		}
	}
}

func titles(entries []StoreEntry) string {
	names := make([]string, len(entries))
	for i, entry := range entries {
		names[i] = entry.Track.Title
	}
	return strings.Join(names, ",")
}

func TestStoreListsOnlyTracksInPublicPlaylists(t *testing.T) {
	f := newCatalogFixture(t)
	alice := f.user("alice@example.com")
	private := f.track(alice.ID, NewTrack{Title: "private"})
	linkOnly := f.track(alice.ID, NewTrack{Title: "link only"})
	public := f.track(alice.ID, NewTrack{Title: "public"})
	f.playlist(alice.ID, false, linkOnly.ID)
	playlist := f.playlist(alice.ID, true, public.ID)
	if _, err := f.tracks.ReservePending(f.ctx, alice.ID, NewTrack{Title: "uploading", FileName: "u.mp3", ContentType: "audio/mpeg", SizeBytes: 1}, 1<<30, 10); err != nil {
		t.Fatal(err)
	}

	jobs := f.pending()
	if len(jobs) != 1 || jobs[0].Track.ID != public.ID {
		t.Fatalf("pending = %v; want only the public playlist's track", jobs)
	}
	// Without a fingerprint, a copy waits for one until it settles.
	if waiting, _ := f.catalog.PendingCatalogTracks(f.ctx, 100, time.Hour); len(waiting) != 0 {
		t.Fatalf("an unfingerprinted copy was handed out before it settled: %v", waiting)
	}
	f.indexAll()
	if got := titles(f.listed(StoreQuery{})); got != "public" {
		t.Fatalf("listed %q", got)
	}
	if len(f.pending()) != 0 {
		t.Fatal("a grouped copy is still pending")
	}
	// Even a private track mapped into an entry by mistake is never listed.
	if err := f.catalog.NewEntry(f.ctx, private.ID, "stray", nil, nil); err != nil {
		t.Fatal(err)
	}
	if got := titles(f.listed(StoreQuery{})); got != "public" {
		t.Fatalf("a private track was listed: %q", got)
	}

	// Making the playlist link-only takes the track out of the store at
	// once, before any pruning.
	notPublic := false
	if _, err := f.playlists.Share(f.ctx, alice.ID, playlist.ID, *playlist.ShareToken, &notPublic, true); err != nil {
		t.Fatal(err)
	}
	if got := f.listed(StoreQuery{}); len(got) != 0 {
		t.Fatalf("still listed after unpublishing: %q", titles(got))
	}
	removed, err := f.catalog.PruneCatalog(f.ctx)
	if err != nil || removed != 2 {
		t.Fatalf("prune = %d, %v; want the unpublished and the stray copy", removed, err)
	}
}

func TestStoreRemovalPropagates(t *testing.T) {
	f := newCatalogFixture(t)
	alice, bob := f.user("alice@example.com"), f.user("bob@example.com")
	a := f.track(alice.ID, NewTrack{Title: "removed from playlist"})
	b := f.track(alice.ID, NewTrack{Title: "deleted track"})
	c := f.track(bob.ID, NewTrack{Title: "deleted account"})
	d := f.track(alice.ID, NewTrack{Title: "unshared playlist"})
	e := f.track(alice.ID, NewTrack{Title: "deleted playlist"})
	first := f.playlist(alice.ID, true, a.ID, b.ID)
	f.playlist(bob.ID, true, c.ID)
	third := f.playlist(alice.ID, true, d.ID)
	fourth := f.playlist(alice.ID, true, e.ID)
	f.indexAll()
	if got := f.listed(StoreQuery{}); len(got) != 5 {
		t.Fatalf("listed %q", titles(got))
	}

	if err := f.playlists.ReplaceTracks(f.ctx, alice.ID, first.ID, []string{b.ID}); err != nil {
		t.Fatal(err)
	}
	if err := f.tracks.Delete(f.ctx, alice.ID, b.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := f.catalog.pool.Exec(f.ctx, `DELETE FROM users WHERE id::text = $1`, bob.ID); err != nil {
		t.Fatal(err)
	}
	if err := f.playlists.Unshare(f.ctx, alice.ID, third.ID); err != nil {
		t.Fatal(err)
	}
	if err := f.playlists.Delete(f.ctx, alice.ID, fourth.ID); err != nil {
		t.Fatal(err)
	}
	if got := f.listed(StoreQuery{}); len(got) != 0 {
		t.Fatalf("still listed: %q", titles(got))
	}
	if _, err := f.catalog.PruneCatalog(f.ctx); err != nil {
		t.Fatal(err)
	}
	// Entries emptied a moment ago are kept a little, in case a copy is
	// being grouped into them.
	var entries int
	_ = f.catalog.pool.QueryRow(f.ctx, `SELECT count(*) FROM store_entries`).Scan(&entries)
	if entries != 5 {
		t.Fatalf("%d entries right after pruning", entries)
	}
	_, _ = f.catalog.pool.Exec(f.ctx, `UPDATE store_entries SET created_at = now() - interval '2 minutes'`)
	if _, err := f.catalog.PruneCatalog(f.ctx); err != nil {
		t.Fatal(err)
	}
	_ = f.catalog.pool.QueryRow(f.ctx, `SELECT count(*) FROM store_entries`).Scan(&entries)
	if entries != 0 {
		t.Fatalf("%d emptied entries kept", entries)
	}
}

func TestStorePlaysTheBestEligibleCopy(t *testing.T) {
	f := newCatalogFixture(t)
	alice, bob, carol := f.user("alice@example.com"), f.user("bob@example.com"), f.user("carol@example.com")
	duration := int32(200_000)
	mp3 := f.track(alice.ID, NewTrack{Title: "song", ContentType: "audio/mpeg", SizeBytes: 3_000_000, DurationMS: &duration})
	highMP3 := f.track(carol.ID, NewTrack{Title: "song", ContentType: "audio/mpeg", SizeBytes: 8_000_000, DurationMS: &duration})
	flac := f.track(bob.ID, NewTrack{Title: "song", FileName: "song.flac", ContentType: "audio/flac", SizeBytes: 5_000_000, DurationMS: &duration})
	f.playlist(alice.ID, true, mp3.ID)
	f.playlist(carol.ID, true, highMP3.ID)
	bobs := f.playlist(bob.ID, true, flac.ID)
	if err := f.catalog.NewEntry(f.ctx, mp3.ID, "song|", nil, nil); err != nil {
		t.Fatal(err)
	}
	entryID := f.listed(StoreQuery{})[0].ID
	for _, copy := range []Track{highMP3, flac} {
		if err := f.catalog.AddToEntry(f.ctx, copy.ID, entryID, []byte{1, 2, 3, 4}, nil); err != nil {
			t.Fatal(err)
		}
	}
	listed := f.listed(StoreQuery{})
	if len(listed) != 1 || listed[0].Track.ID != flac.ID || listed[0].Copies != 3 {
		t.Fatalf("listed %+v; want one entry playing the lossless copy", listed)
	}
	if err := f.playlists.ReplaceTracks(f.ctx, bob.ID, bobs.ID, nil); err != nil {
		t.Fatal(err)
	}
	entry, err := f.catalog.StoreEntryByID(f.ctx, entryID, false)
	if err != nil || entry.Track.ID != highMP3.ID || entry.Copies != 2 {
		t.Fatalf("entry = %+v, %v; want the higher-bitrate mp3 once the flac left", entry, err)
	}
	// The entry adopted the first fingerprint it was given.
	var points []byte
	_ = f.catalog.pool.QueryRow(f.ctx, `SELECT points FROM store_entries WHERE id::text = $1`, entryID).Scan(&points)
	if len(points) != 4 {
		t.Fatalf("entry points = %v", points)
	}
	for _, user := range []User{alice, carol, bob} {
		if owns, err := f.catalog.OwnsCopy(f.ctx, entryID, user.ID); err != nil || !owns {
			t.Fatalf("%s owns = %v, %v", user.Email, owns, err)
		}
	}
	dave := f.user("dave@example.com")
	if owns, _ := f.catalog.OwnsCopy(f.ctx, entryID, dave.ID); owns {
		t.Fatal("dave owns a copy")
	}
	// A duplicate attempt to group a copy changes nothing.
	if err := f.catalog.NewEntry(f.ctx, mp3.ID, "again", nil, nil); err != nil {
		t.Fatal(err)
	}
	if got := f.listed(StoreQuery{}); len(got) != 1 {
		t.Fatalf("listed %q", titles(got))
	}
}

func TestStoreSearchFoldsLetterVariants(t *testing.T) {
	f := newCatalogFixture(t)
	alice := f.user("alice@example.com")
	str := func(s string) *string { return &s }
	songs := []NewTrack{
		{Title: "كتاب عشق", Artist: str("علي"), Album: str("یادگار")},
		{Title: "Rain Song", Artist: str("Kayhan"), Album: str("Seasons")},
		{Title: "50% off_", Artist: str("Kayhan"), AlbumArtist: str("Various")},
		{Title: "می‌خواهم", Artist: str("Ali")},
	}
	var ids []string
	for _, song := range songs {
		ids = append(ids, f.track(alice.ID, song).ID)
	}
	f.playlist(alice.ID, true, ids...)
	f.indexAll()
	for search, want := range map[string]string{
		"کتاب":        "كتاب عشق",
		"عشق کتاب":    "كتاب عشق",
		"علی":         "كتاب عشق",
		"یادگار":      "كتاب عشق",
		"RAIN":        "Rain Song",
		"rain winter": "",
		"%":           "50% off_",
		"_":           "50% off_",
		"می خواهم":    "می‌خواهم",
		"میخواهم":     "",
	} {
		if got := titles(f.listed(StoreQuery{Search: search})); got != want {
			t.Errorf("search %q = %q, want %q", search, got, want)
		}
	}
	if got := titles(f.listed(StoreQuery{Artist: "kayhan"})); got != "50% off_,Rain Song" {
		t.Errorf("artist filter = %q", got)
	}
	if got := titles(f.listed(StoreQuery{Artist: "Various"})); got != "50% off_" {
		t.Errorf("album artist filter = %q", got)
	}
	if got := titles(f.listed(StoreQuery{Album: "یادگار"})); got != "كتاب عشق" {
		t.Errorf("album filter = %q", got)
	}
	entries, more, _ := f.catalog.StoreEntries(f.ctx, StoreQuery{Limit: 3})
	if len(entries) != 3 || !more {
		t.Fatalf("first page = %d, more %v", len(entries), more)
	}
	entries, more, _ = f.catalog.StoreEntries(f.ctx, StoreQuery{Limit: 3, Offset: 3})
	if len(entries) != 1 || more {
		t.Fatalf("last page = %d, more %v", len(entries), more)
	}

	artists, _, err := f.catalog.StoreArtists(f.ctx, "", 10, 0)
	if err != nil || len(artists) != 3 {
		t.Fatalf("artists = %+v, %v", artists, err)
	}
	if artists, _, _ := f.catalog.StoreArtists(f.ctx, "KAY", 10, 0); len(artists) != 1 || artists[0].TrackCount != 2 {
		t.Fatalf("artist search = %+v", artists)
	}
	albums, _, err := f.catalog.StoreAlbums(f.ctx, "", "", 10, 0)
	if err != nil || len(albums) != 2 || albums[0].Name != "Seasons" || *albums[0].Artist != "Kayhan" {
		t.Fatalf("albums = %+v, %v", albums, err)
	}
	if albums, _, _ := f.catalog.StoreAlbums(f.ctx, "", "علی", 10, 0); len(albums) != 1 || albums[0].Name != "یادگار" {
		t.Fatalf("one artist's albums = %+v", albums)
	}
}

func TestStoreHidingAndReports(t *testing.T) {
	f := newCatalogFixture(t)
	alice, bob, admin := f.user("alice@example.com"), f.user("bob@example.com"), f.user("admin@example.com")
	song := f.track(alice.ID, NewTrack{Title: "reported"})
	f.playlist(alice.ID, true, song.ID)
	f.indexAll()
	entryID := f.listed(StoreQuery{})[0].ID

	details := "not theirs"
	for range 2 {
		if err := f.catalog.ReportEntry(f.ctx, entryID, bob.ID, "copyright", &details); err != nil {
			t.Fatal(err)
		}
	}
	if err := f.catalog.ReportEntry(f.ctx, entryID, admin.ID, "offensive", nil); err != nil {
		t.Fatal(err)
	}
	if err := f.catalog.ReportEntry(f.ctx, "00000000-0000-0000-0000-000000000000", bob.ID, "other", nil); !errors.Is(err, ErrNotFound) {
		t.Fatalf("reporting an unknown entry = %v", err)
	}
	reports, err := f.catalog.OpenReports(f.ctx, 10)
	if err != nil || len(reports) != 1 || reports[0].Reports != 2 || reports[0].Reason != "copyright" ||
		reports[0].Entry.Track.ID != song.ID {
		t.Fatalf("reports = %+v, %v", reports, err)
	}

	if err := f.catalog.SetHidden(f.ctx, entryID, admin.ID, true); err != nil {
		t.Fatal(err)
	}
	if got := f.listed(StoreQuery{}); len(got) != 0 {
		t.Fatalf("hidden entry listed: %q", titles(got))
	}
	if _, err := f.catalog.StoreEntryByID(f.ctx, entryID, false); !errors.Is(err, ErrNotFound) {
		t.Fatalf("hidden entry found: %v", err)
	}
	if entry, err := f.catalog.StoreEntryByID(f.ctx, entryID, true); err != nil || !entry.Hidden {
		t.Fatalf("admin view = %+v, %v", entry, err)
	}
	if reports, _ := f.catalog.OpenReports(f.ctx, 10); len(reports) != 0 {
		t.Fatalf("hiding left reports open: %+v", reports)
	}
	if err := f.catalog.ReportEntry(f.ctx, entryID, bob.ID, "copyright", nil); !errors.Is(err, ErrNotFound) {
		t.Fatalf("reporting a hidden entry = %v", err)
	}
	// A hidden entry outlives its copies, so the song stays hidden when it
	// comes back.
	if err := f.tracks.Delete(f.ctx, alice.ID, song.ID); err != nil {
		t.Fatal(err)
	}
	_, _ = f.catalog.pool.Exec(f.ctx, `UPDATE store_entries SET created_at = now() - interval '2 minutes'`)
	if _, err := f.catalog.PruneCatalog(f.ctx); err != nil {
		t.Fatal(err)
	}
	if err := f.catalog.SetHidden(f.ctx, entryID, admin.ID, false); err != nil {
		t.Fatalf("the hidden entry was pruned: %v", err)
	}
	if err := f.catalog.SetHidden(f.ctx, "00000000-0000-0000-0000-000000000000", admin.ID, true); !errors.Is(err, ErrNotFound) {
		t.Fatalf("hiding an unknown entry = %v", err)
	}
}

func TestCatalogCandidates(t *testing.T) {
	f := newCatalogFixture(t)
	alice := f.user("alice@example.com")
	a := f.track(alice.ID, NewTrack{Title: "a"})
	b := f.track(alice.ID, NewTrack{Title: "b"})
	f.playlist(alice.ID, true, a.ID, b.ID)
	at := func(s float64) *float64 { return &s }
	if err := f.catalog.NewEntry(f.ctx, a.ID, "a|", []byte{1, 0, 0, 0}, at(200)); err != nil {
		t.Fatal(err)
	}
	if err := f.catalog.NewEntry(f.ctx, b.ID, "b|", nil, at(201)); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		key      string
		duration *float64
		want     string
	}{
		{"a|", nil, "a|"},
		{"b|", at(500), "b|"},
		{"x|", at(202), "a|"}, // a fingerprinted entry of a close length
		{"x|", at(204), ""},
		{"x|", nil, ""},
	} {
		got, err := f.catalog.CatalogCandidates(f.ctx, c.key, c.duration, 3)
		keys := []string{}
		for _, candidate := range got {
			keys = append(keys, candidate.TitleKey)
		}
		if err != nil || strings.Join(keys, ",") != c.want {
			t.Errorf("candidates(%q, %v) = %v, %v; want %q", c.key, c.duration, keys, err, c.want)
		}
	}
}

func TestArtistCountsOnlyIncludeLivePublicCatalog(t *testing.T) {
	f := newCatalogFixture(t)
	u := f.user("artist-counts@example.com")
	artist, album, privateAlbum := "علی", "باران", "private album"
	t1 := f.track(u.ID, NewTrack{Title: "one", Artist: &artist, Album: &album})
	t2 := f.track(u.ID, NewTrack{Title: "two", Artist: &artist})
	private := f.track(u.ID, NewTrack{Title: "private", Artist: &artist, Album: &privateAlbum})
	f.playlist(u.ID, true, t1.ID, t2.ID)
	f.playlist(u.ID, false, private.ID)
	f.indexAll()
	tracks, albums, err := f.catalog.StoreArtistCounts(f.ctx, "علي")
	if err != nil || tracks != 2 || albums != 1 {
		t.Fatalf("counts = %d, %d, %v", tracks, albums, err)
	}
	for _, entry := range f.listed(StoreQuery{Artist: artist}) {
		if err := f.catalog.SetHidden(f.ctx, entry.ID, u.ID, true); err != nil {
			t.Fatal(err)
		}
	}
	tracks, albums, err = f.catalog.StoreArtistCounts(f.ctx, artist)
	if err != nil || tracks != 0 || albums != 0 {
		t.Fatalf("hidden counts = %d, %d, %v", tracks, albums, err)
	}
}
