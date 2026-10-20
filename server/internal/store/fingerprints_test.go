package store

import (
	"context"
	"errors"
	"sort"
	"testing"
	"time"
)

func TestFingerprintJobs(t *testing.T) {
	pool := newTestPool(t)
	ctx := context.Background()
	alice, _ := NewUsers(pool).Create(ctx, "alice@example.com", "hash")
	tracks := NewTracks(pool)
	fps := NewFingerprints(pool)
	older, _ := tracks.Create(ctx, alice.ID, NewTrack{Title: "older", FileName: "o.mp3", ContentType: "audio/mpeg", SizeBytes: 1})
	newer, _ := tracks.Create(ctx, alice.ID, NewTrack{Title: "newer", FileName: "n.mp3", ContentType: "audio/mpeg", SizeBytes: 1})
	if _, err := tracks.ReservePending(ctx, alice.ID, NewTrack{Title: "p", FileName: "p.mp3", ContentType: "audio/mpeg", SizeBytes: 1}, 1<<30, 10); err != nil {
		t.Fatal(err)
	}

	jobs, err := fps.ClaimFingerprintJobs(ctx, 1, 3, time.Minute)
	if err != nil || len(jobs) != 1 || jobs[0].ID != newer.ID {
		t.Fatalf("first claim = %v, %v; want the newest ready track", jobs, err)
	}
	jobs, _ = fps.ClaimFingerprintJobs(ctx, 10, 3, time.Minute)
	if len(jobs) != 1 || jobs[0].ID != older.ID || jobs[0].StorageKey == "" {
		t.Fatalf("second claim = %v; want the backfill of the older track, not the leased or pending ones", jobs)
	}

	if err := fps.SaveFingerprint(ctx, newer.ID, []byte{1, 2, 3, 4}, 3*time.Minute); err != nil {
		t.Fatal(err)
	}
	// A failure is retried after its delay, and given up after max attempts.
	if err := fps.FingerprintFailed(ctx, older.ID, "fpcalc exited with 3", time.Hour); err != nil {
		t.Fatal(err)
	}
	if jobs, _ := fps.ClaimFingerprintJobs(ctx, 10, 3, time.Minute); len(jobs) != 0 {
		t.Fatalf("claimed %v before the retry delay", jobs)
	}
	_, _ = pool.Exec(ctx, "UPDATE track_fingerprints SET not_before = now() - interval '1 second'")
	if jobs, _ := fps.ClaimFingerprintJobs(ctx, 10, 3, time.Minute); len(jobs) != 1 || jobs[0].ID != older.ID {
		t.Fatalf("retry = %v", jobs)
	}
	_ = fps.FingerprintFailed(ctx, older.ID, "again", 0)
	_, _ = pool.Exec(ctx, "UPDATE track_fingerprints SET not_before = now() - interval '1 second'")
	_, _ = fps.ClaimFingerprintJobs(ctx, 10, 3, time.Minute)
	_ = fps.FingerprintFailed(ctx, older.ID, "and again", 0)
	_, _ = pool.Exec(ctx, "UPDATE track_fingerprints SET not_before = now() - interval '1 second'")
	if jobs, _ := fps.ClaimFingerprintJobs(ctx, 10, 3, time.Minute); len(jobs) != 0 {
		t.Fatalf("claimed %v after three attempts", jobs)
	}

	// Fingerprints go with their track; saving after a delete is a no-op.
	if err := tracks.Delete(ctx, alice.ID, newer.ID); err != nil {
		t.Fatal(err)
	}
	if err := fps.SaveFingerprint(ctx, newer.ID, []byte{1, 2, 3, 4}, time.Minute); err != nil {
		t.Fatalf("saving for a deleted track = %v", err)
	}
	var rows int
	_ = pool.QueryRow(ctx, "SELECT count(*) FROM track_fingerprints WHERE track_id::text = $1", newer.ID).Scan(&rows)
	if rows != 0 {
		t.Fatal("the fingerprint outlived its track")
	}
}

func TestMatchableTracksAreOnlyThoseTheUserMayPlay(t *testing.T) {
	pool := newTestPool(t)
	ctx := context.Background()
	users := NewUsers(pool)
	tracks := NewTracks(pool)
	playlists := NewPlaylists(pool)
	fps := NewFingerprints(pool)
	alice, _ := users.Create(ctx, "alice@example.com", "hash")
	bob, _ := users.Create(ctx, "bob@example.com", "hash")
	carol, _ := users.Create(ctx, "carol@example.com", "hash")
	add := func(owner, title string) Track {
		t.Helper()
		track, err := tracks.Create(ctx, owner, NewTrack{Title: title, FileName: title + ".mp3", ContentType: "audio/mpeg", SizeBytes: 10})
		if err != nil {
			t.Fatal(err)
		}
		if err := fps.SaveFingerprint(ctx, track.ID, []byte{1, 0, 0, 0}, time.Minute); err != nil {
			t.Fatal(err)
		}
		return track
	}
	add(alice.ID, "alice-own")
	bobPrivate := add(bob.ID, "bob-private")
	bobCollab := add(bob.ID, "bob-collab")
	bobPublic := add(bob.ID, "bob-public")
	bobLinkOnly := add(bob.ID, "bob-link-only")
	carolCollab := add(carol.ID, "carol-collab")
	unfingerprinted, _ := tracks.Create(ctx, alice.ID, NewTrack{Title: "unfingerprinted", FileName: "u.mp3", ContentType: "audio/mpeg", SizeBytes: 1})
	_ = unfingerprinted

	together, _ := playlists.Create(ctx, bob.ID, "together")
	_, _ = playlists.SetCollabToken(ctx, bob.ID, together.ID, ptr("join"))
	_, _ = playlists.Join(ctx, alice.ID, "join")
	_, _ = playlists.Join(ctx, carol.ID, "join")
	if err := playlists.ReplaceTracks(ctx, bob.ID, together.ID, []string{bobCollab.ID}); err != nil {
		t.Fatal(err)
	}
	if err := playlists.ReplaceTracks(ctx, carol.ID, together.ID, []string{bobCollab.ID, carolCollab.ID}); err != nil {
		t.Fatal(err)
	}
	public, _ := playlists.Create(ctx, bob.ID, "public")
	_ = playlists.ReplaceTracks(ctx, bob.ID, public.ID, []string{bobPublic.ID})
	yes, no := true, false
	_, _ = playlists.Share(ctx, bob.ID, public.ID, "public-token", &yes, true)
	linkOnly, _ := playlists.Create(ctx, bob.ID, "link only")
	_ = playlists.ReplaceTracks(ctx, bob.ID, linkOnly.ID, []string{bobLinkOnly.ID})
	_, _ = playlists.Share(ctx, bob.ID, linkOnly.ID, "link-token", &no, true)

	matchable := func(userID string) map[string]Matchable {
		t.Helper()
		found := map[string]Matchable{}
		if err := fps.EachMatchable(ctx, userID, func(m Matchable) error {
			if _, dup := found[m.Track.Title]; dup {
				t.Fatalf("%s reported twice", m.Track.Title)
			}
			found[m.Track.Title] = m
			return nil
		}); err != nil {
			t.Fatal(err)
		}
		return found
	}
	titles := func(found map[string]Matchable) []string {
		var out []string
		for title := range found {
			out = append(out, title)
		}
		sort.Strings(out)
		return out
	}

	forAlice := matchable(alice.ID)
	if got := titles(forAlice); !equalStrings(got, []string{"alice-own", "bob-collab", "bob-public", "carol-collab"}) {
		t.Fatalf("alice may match %v", got)
	}
	if s := forAlice["alice-own"].Source; s.PlaylistID != nil || s.ShareToken != nil {
		t.Fatalf("own track source = %+v", s)
	}
	if s := forAlice["bob-collab"].Source; s.PlaylistID == nil || *s.PlaylistID != together.ID || s.ShareToken != nil {
		t.Fatalf("collab track source = %+v", s)
	}
	if s := forAlice["bob-public"].Source; s.ShareToken == nil || *s.ShareToken != "public-token" || s.PlaylistID != nil {
		t.Fatalf("public track source = %+v", s)
	}
	if forAlice["bob-collab"].OwnerEmail != "bob@example.com" || len(forAlice["alice-own"].Points) != 4 {
		t.Fatalf("details = %+v", forAlice["bob-collab"])
	}

	// A stranger only reaches what is public; Bob reaches all of his own.
	stranger, _ := users.Create(ctx, "dave@example.com", "hash")
	if got := titles(matchable(stranger.ID)); !equalStrings(got, []string{"bob-public"}) {
		t.Fatalf("a stranger may match %v", got)
	}
	if got := titles(matchable(bob.ID)); !equalStrings(got, []string{"bob-collab", "bob-link-only", "bob-private", "bob-public", "carol-collab"}) {
		t.Fatalf("bob may match %v", got)
	}

	// Leaving the playlist takes its tracks out of reach.
	if err := playlists.RemoveMember(ctx, alice.ID, together.ID, alice.ID); err != nil {
		t.Fatal(err)
	}
	if got := titles(matchable(alice.ID)); !equalStrings(got, []string{"alice-own", "bob-public"}) {
		t.Fatalf("after leaving, alice may match %v", got)
	}
	_ = bobPrivate

	stop := errors.New("stop")
	if err := fps.EachMatchable(ctx, bob.ID, func(Matchable) error { return stop }); !errors.Is(err, stop) {
		t.Fatalf("callback error = %v", err)
	}
}

func TestSaveTrackCopy(t *testing.T) {
	pool := newTestPool(t)
	ctx := context.Background()
	users := NewUsers(pool)
	tracks := NewTracks(pool)
	fps := NewFingerprints(pool)
	bob, _ := users.Create(ctx, "bob@example.com", "hash")
	alice, _ := users.Create(ctx, "alice@example.com", "hash")
	original, _ := tracks.Create(ctx, bob.ID, NewTrack{Title: "song", Artist: ptr("band"), FileName: "s.mp3", ContentType: "audio/mpeg", SizeBytes: 100})
	_ = fps.SaveFingerprint(ctx, original.ID, []byte{9, 9, 9, 9}, time.Minute)
	objects := &memoryObjects{objects: map[string]string{original.StorageKey: "audio"}}

	if _, err := fps.SaveTrackCopy(ctx, alice.ID, original, 99, objects); !errors.Is(err, ErrQuotaExceeded) {
		t.Fatalf("over quota = %v", err)
	}
	if _, err := fps.SaveTrackCopy(ctx, bob.ID, original, 1000, objects); !errors.Is(err, ErrOwnPlaylist) {
		t.Fatalf("own track = %v", err)
	}
	copied, err := fps.SaveTrackCopy(ctx, alice.ID, original, 1000, objects)
	if err != nil {
		t.Fatal(err)
	}
	if copied.OwnerID != alice.ID || copied.Status != TrackReady || copied.Title != "song" || *copied.Artist != "band" ||
		copied.Source != "shared" || objects.objects[copied.StorageKey] != "audio" {
		t.Fatalf("copy = %+v", copied)
	}
	var points []byte
	_ = pool.QueryRow(ctx, "SELECT points FROM track_fingerprints WHERE track_id::text = $1", copied.ID).Scan(&points)
	if len(points) != 4 || points[0] != 9 {
		t.Fatalf("the copy's fingerprint = %v", points)
	}

	// A failed storage copy leaves nothing behind.
	failing := &memoryObjects{objects: map[string]string{}, failAt: 1}
	if _, err := fps.SaveTrackCopy(ctx, alice.ID, original, 1000, failing); err == nil {
		t.Fatal("a failed copy succeeded")
	}
	list, _ := tracks.ListForOwner(ctx, alice.ID)
	if len(list) != 1 {
		t.Fatalf("alice has %d tracks after a failed copy", len(list))
	}
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
