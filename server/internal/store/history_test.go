package store

import (
	"context"
	"errors"
	"fmt"
	"testing"
)

func TestHistoryRecordsOnlyPlayableTracks(t *testing.T) {
	pool := newTestPool(t)
	ctx := context.Background()
	users := NewUsers(pool)
	tracks := NewTracks(pool)
	playlists := NewPlaylists(pool)
	history := NewHistory(pool)
	alice, _ := users.Create(ctx, "alice@example.com", "hash")
	bob, _ := users.Create(ctx, "bob@example.com", "hash")
	carol, _ := users.Create(ctx, "carol@example.com", "hash")
	add := func(ownerID, title string) Track {
		t.Helper()
		track, err := tracks.Create(ctx, ownerID, NewTrack{Title: title, FileName: title + ".mp3", ContentType: "audio/mpeg", SizeBytes: 1})
		if err != nil {
			t.Fatal(err)
		}
		return track
	}
	aliceTrack := add(alice.ID, "alice")
	bobTrack := add(bob.ID, "bob")
	pending, err := tracks.ReservePending(ctx, alice.ID, NewTrack{Title: "p", FileName: "p.mp3", ContentType: "audio/mpeg", SizeBytes: 1}, 1<<30, 10)
	if err != nil {
		t.Fatal(err)
	}

	// Bob's playlist, which Alice joins and Carol never does.
	together, _ := playlists.Create(ctx, bob.ID, "together")
	if err := playlists.ReplaceTracks(ctx, bob.ID, together.ID, []string{bobTrack.ID}); err != nil {
		t.Fatal(err)
	}
	if _, err := playlists.SetCollabToken(ctx, bob.ID, together.ID, ptr("join")); err != nil {
		t.Fatal(err)
	}
	if _, err := playlists.Join(ctx, alice.ID, "join"); err != nil {
		t.Fatal(err)
	}

	cases := []struct {
		name     string
		user     string
		track    string
		playlist *string
		want     error
	}{
		{"own track", alice.ID, aliceTrack.ID, nil, nil},
		{"own track with a playlist", alice.ID, aliceTrack.ID, ptr(together.ID), nil},
		{"member's track through the playlist", alice.ID, bobTrack.ID, ptr(together.ID), nil},
		{"someone else's track directly", alice.ID, bobTrack.ID, nil, ErrNotFound},
		{"a stranger through the playlist", carol.ID, bobTrack.ID, ptr(together.ID), ErrNotFound},
		{"pending upload", alice.ID, pending.ID, nil, ErrNotFound},
		{"unknown track", alice.ID, "00000000-0000-0000-0000-000000000000", nil, ErrNotFound},
		{"malformed ids", alice.ID, "not-a-uuid", ptr("nope"), ErrNotFound},
	}
	for _, c := range cases {
		if err := history.Record(ctx, c.user, c.track, c.playlist, 200); !errors.Is(err, c.want) {
			t.Errorf("%s: Record = %v, want %v", c.name, err, c.want)
		}
	}

	recent, err := history.Recent(ctx, alice.ID, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(recent) != 2 || recent[0].Track.ID != bobTrack.ID || recent[1].Track.ID != aliceTrack.ID {
		t.Fatalf("recent = %+v", recent)
	}
	if recent[0].PlaylistID == nil || *recent[0].PlaylistID != together.ID || recent[0].OwnerName != "" {
		t.Fatalf("member track context = %+v", recent[0])
	}
	if recent[1].PlaylistID != nil {
		t.Fatalf("own track keeps a playlist: %v", *recent[1].PlaylistID)
	}
	if other, _ := history.Recent(ctx, carol.ID, 50); len(other) != 0 {
		t.Fatalf("carol sees %+v", other)
	}
	if other, _ := history.Recent(ctx, bob.ID, 50); len(other) != 0 {
		t.Fatalf("bob sees alice's history: %+v", other)
	}

	// Leaving the playlist hides Bob's track from Alice's history.
	if err := playlists.RemoveMember(ctx, alice.ID, together.ID, alice.ID); err != nil {
		t.Fatal(err)
	}
	recent, _ = history.Recent(ctx, alice.ID, 50)
	if len(recent) != 1 || recent[0].Track.ID != aliceTrack.ID {
		t.Fatalf("after leaving = %+v", recent)
	}
}

func TestHistoryIsBoundedAndDeduplicated(t *testing.T) {
	pool := newTestPool(t)
	ctx := context.Background()
	users := NewUsers(pool)
	tracks := NewTracks(pool)
	history := NewHistory(pool)
	alice, _ := users.Create(ctx, "alice@example.com", "hash")
	var ids []string
	for i := range 6 {
		track, err := tracks.Create(ctx, alice.ID, NewTrack{Title: fmt.Sprint(i), FileName: "t.mp3", ContentType: "audio/mpeg", SizeBytes: 1})
		if err != nil {
			t.Fatal(err)
		}
		ids = append(ids, track.ID)
	}
	const keep = 4
	// 0 1 2 3 4 5 0: the oldest plays fall out, the replayed 0 comes first.
	for _, i := range []int{0, 1, 2, 3, 4, 5, 0} {
		if err := history.Record(ctx, alice.ID, ids[i], nil, keep); err != nil {
			t.Fatal(err)
		}
	}
	var stored int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM play_history`).Scan(&stored); err != nil {
		t.Fatal(err)
	}
	if stored != keep {
		t.Fatalf("stored %d entries, want %d", stored, keep)
	}
	recent, err := history.Recent(ctx, alice.ID, 10)
	if err != nil {
		t.Fatal(err)
	}
	got := []string{}
	for _, e := range recent {
		got = append(got, e.Track.Title)
	}
	if fmt.Sprint(got) != "[0 5 4 3]" {
		t.Fatalf("recent = %v", got)
	}
	if limited, _ := history.Recent(ctx, alice.ID, 2); len(limited) != 2 {
		t.Fatalf("limit ignored: %d", len(limited))
	}
	// A replay of the same track is listed once.
	_ = history.Record(ctx, alice.ID, ids[0], nil, keep)
	if again, _ := history.Recent(ctx, alice.ID, 10); len(again) != 3 || again[0].Track.Title != "0" {
		t.Fatalf("after replay = %+v", again)
	}
}

func TestHistoryGoesWithTracksPlaylistsAndAccounts(t *testing.T) {
	pool := newTestPool(t)
	ctx := context.Background()
	users := NewUsers(pool)
	tracks := NewTracks(pool)
	playlists := NewPlaylists(pool)
	history := NewHistory(pool)
	alice, _ := users.Create(ctx, "alice@example.com", "hash")
	bob, _ := users.Create(ctx, "bob@example.com", "hash")
	add := func(ownerID, title string) Track {
		t.Helper()
		track, _ := tracks.Create(ctx, ownerID, NewTrack{Title: title, FileName: "t.mp3", ContentType: "audio/mpeg", SizeBytes: 1})
		return track
	}
	kept := add(alice.ID, "kept")
	deleted := add(alice.ID, "deleted")
	bobTrack := add(bob.ID, "bob")
	shared, _ := playlists.Create(ctx, bob.ID, "shared")
	_ = playlists.ReplaceTracks(ctx, bob.ID, shared.ID, []string{bobTrack.ID})
	_, _ = playlists.SetCollabToken(ctx, bob.ID, shared.ID, ptr("join"))
	_, _ = playlists.Join(ctx, alice.ID, "join")
	for _, play := range []struct {
		user, track string
		playlist    *string
	}{
		{alice.ID, kept.ID, nil}, {alice.ID, deleted.ID, nil},
		{alice.ID, bobTrack.ID, ptr(shared.ID)}, {bob.ID, bobTrack.ID, nil},
	} {
		if err := history.Record(ctx, play.user, play.track, play.playlist, 200); err != nil {
			t.Fatal(err)
		}
	}
	count := func(where string, args ...any) int {
		t.Helper()
		var n int
		if err := pool.QueryRow(ctx, `SELECT count(*) FROM play_history WHERE `+where, args...).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}

	if err := tracks.Delete(ctx, alice.ID, deleted.ID); err != nil {
		t.Fatal(err)
	}
	if n := count(`track_id = $1::uuid`, deleted.ID); n != 0 {
		t.Fatalf("deleted track keeps %d history rows", n)
	}

	if err := playlists.Delete(ctx, bob.ID, shared.ID); err != nil {
		t.Fatal(err)
	}
	if n := count(`playlist_id IS NOT NULL`); n != 0 {
		t.Fatalf("deleted playlist keeps %d history rows", n)
	}
	// Bob's own play of his track survives his playlist.
	if n := count(`user_id = $1::uuid`, bob.ID); n != 1 {
		t.Fatalf("bob has %d rows, want 1", n)
	}

	if _, err := users.Delete(ctx, alice.ID, 0); err != nil {
		t.Fatal(err)
	}
	if n := count(`user_id = $1::uuid`, alice.ID); n != 0 {
		t.Fatalf("deleted account keeps %d history rows", n)
	}

	if err := history.Clear(ctx, bob.ID); err != nil {
		t.Fatal(err)
	}
	if n := count(`true`); n != 0 {
		t.Fatalf("clear left %d rows", n)
	}
}
