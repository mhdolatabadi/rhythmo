package store

import (
	"errors"
	"testing"
	"time"
)

func TestPublishingOneTrackListsItInTheStore(t *testing.T) {
	f := newCatalogFixture(t)
	alice, bob := f.user("alice@example.com"), f.user("bob@example.com")
	solo := f.track(alice.ID, NewTrack{Title: "solo"})
	inPlaylist := f.track(alice.ID, NewTrack{Title: "in playlist"})
	f.playlist(alice.ID, true, inPlaylist.ID)
	if _, err := f.tracks.ReservePending(f.ctx, alice.ID, NewTrack{Title: "uploading", FileName: "u.mp3", ContentType: "audio/mpeg", SizeBytes: 1}, 1<<30, 10); err != nil {
		t.Fatal(err)
	}

	if _, err := f.tracks.SetPublished(f.ctx, bob.ID, solo.ID, true, true); !errors.Is(err, ErrNotFound) {
		t.Fatalf("bob publishing alice's track = %v", err)
	}
	published, err := f.tracks.SetPublished(f.ctx, alice.ID, solo.ID, true, true)
	if err != nil || published.PublishedAt == nil {
		t.Fatalf("publish = %+v, %v", published.PublishedAt, err)
	}
	again, _ := f.tracks.SetPublished(f.ctx, alice.ID, solo.ID, true, true)
	if !again.PublishedAt.Equal(*published.PublishedAt) {
		t.Fatal("publishing again moved the publish time")
	}
	f.indexAll()
	if got := titles(f.listed(StoreQuery{})); got != "in playlist,solo" {
		t.Fatalf("listed %q", got)
	}

	// Unpublishing takes the solo track out at once; a track still in a
	// public playlist stays.
	for _, track := range []Track{solo, inPlaylist} {
		if _, err := f.tracks.SetPublished(f.ctx, alice.ID, track.ID, track.ID == inPlaylist.ID, true); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := f.tracks.SetPublished(f.ctx, alice.ID, inPlaylist.ID, false, true); err != nil {
		t.Fatal(err)
	}
	if got := titles(f.listed(StoreQuery{})); got != "in playlist" {
		t.Fatalf("after unpublishing, listed %q", got)
	}
	tracks, _ := f.tracks.ListForOwner(f.ctx, alice.ID)
	for _, track := range tracks {
		if track.PublishedAt != nil {
			t.Fatalf("%s is still published", track.Title)
		}
	}
}

func TestLikes(t *testing.T) {
	f := newCatalogFixture(t)
	likes := NewTrackLikes(f.catalog.pool)
	alice, bob, carol := f.user("alice@example.com"), f.user("bob@example.com"), f.user("carol@example.com")
	duration := int32(200_000)
	// One song in two copies: alice's mp3 and carol's better flac.
	aliceCopy := f.track(alice.ID, NewTrack{Title: "song", SizeBytes: 3_000_000, DurationMS: &duration})
	carolCopy := f.track(carol.ID, NewTrack{Title: "song", FileName: "s.flac", ContentType: "audio/flac", SizeBytes: 9_000_000, DurationMS: &duration})
	private := f.track(carol.ID, NewTrack{Title: "private"})
	f.playlist(alice.ID, true, aliceCopy.ID)
	f.playlist(carol.ID, true, carolCopy.ID)
	if err := f.catalog.NewEntry(f.ctx, aliceCopy.ID, "song|", nil, nil); err != nil {
		t.Fatal(err)
	}
	entryID := f.listed(StoreQuery{})[0].ID
	if err := f.catalog.AddToEntry(f.ctx, carolCopy.ID, entryID, nil, nil); err != nil {
		t.Fatal(err)
	}

	// Own tracks are liked directly; anyone else's only through the store.
	if _, err := likes.SetOwnLike(f.ctx, bob.ID, private.ID, true); !errors.Is(err, ErrNotFound) {
		t.Fatalf("liking someone else's private track = %v", err)
	}
	if _, err := likes.SetOwnLike(f.ctx, bob.ID, carolCopy.ID, true); !errors.Is(err, ErrNotFound) {
		t.Fatalf("liking someone else's track directly = %v", err)
	}
	state, err := likes.SetOwnLike(f.ctx, alice.ID, aliceCopy.ID, true)
	if err != nil || state != (LikeState{Count: 1, Liked: true}) {
		t.Fatalf("alice likes her copy = %+v, %v", state, err)
	}

	for range 2 {
		state, err = likes.SetStoreLike(f.ctx, bob.ID, entryID, true)
		if err != nil || state != (LikeState{Count: 2, Liked: true}) {
			t.Fatalf("bob likes the song = %+v, %v; want idempotent", state, err)
		}
	}
	// Alice already likes a copy, so liking the song changes nothing.
	if state, _ := likes.SetStoreLike(f.ctx, alice.ID, entryID, true); state != (LikeState{Count: 2, Liked: true}) {
		t.Fatalf("alice likes the song = %+v", state)
	}
	states, _ := likes.EntryStates(f.ctx, "", []string{entryID})
	if states[entryID] != (LikeState{Count: 2}) {
		t.Fatalf("a visitor sees %+v", states[entryID])
	}

	// Carol, whose copy plays, sees both likes on her copy; so does alice.
	for _, owner := range []User{alice, carol} {
		owned, err := likes.OwnerStates(f.ctx, owner.ID)
		if err != nil {
			t.Fatal(err)
		}
		copyID := aliceCopy.ID
		if owner.ID == carol.ID {
			copyID = carolCopy.ID
		}
		if owned[copyID].Count != 2 || owned[copyID].Liked != (owner.ID == alice.ID) || len(owned) != 1 {
			t.Fatalf("%s's counts = %+v", owner.Email, owned)
		}
	}

	// «پسندیده‌ها»: alice's own track, bob's store song.
	liked, more, err := likes.Liked(f.ctx, alice.ID, 10, 0)
	if err != nil || more || len(liked) != 1 || liked[0].Entry != nil || liked[0].Track.ID != aliceCopy.ID {
		t.Fatalf("alice's liked = %+v, %v", liked, err)
	}
	liked, _, _ = likes.Liked(f.ctx, bob.ID, 10, 0)
	if len(liked) != 1 || liked[0].Entry == nil || liked[0].Entry.ID != entryID || liked[0].Track.ID != carolCopy.ID {
		t.Fatalf("bob's liked = %+v", liked)
	}

	// Unliking the song drops bob's like on every copy.
	if _, err := f.catalog.pool.Exec(f.ctx, `INSERT INTO track_likes (user_id, track_id) VALUES ($1::text::uuid, $2::text::uuid)`, bob.ID, aliceCopy.ID); err != nil {
		t.Fatal(err)
	}
	state, err = likes.SetStoreLike(f.ctx, bob.ID, entryID, false)
	if err != nil || state != (LikeState{Count: 1}) {
		t.Fatalf("bob unlikes = %+v, %v", state, err)
	}
	if liked, _, _ := likes.Liked(f.ctx, bob.ID, 10, 0); len(liked) != 0 {
		t.Fatalf("bob still likes %+v", liked)
	}

	// A song that leaves the store leaves «پسندیده‌ها» of listeners who
	// don't own it, and can't be liked.
	_, _ = likes.SetStoreLike(f.ctx, bob.ID, entryID, true)
	if err := f.catalog.SetHidden(f.ctx, entryID, carol.ID, true); err != nil {
		t.Fatal(err)
	}
	if liked, _, _ := likes.Liked(f.ctx, bob.ID, 10, 0); len(liked) != 0 {
		t.Fatalf("a hidden song is still liked: %+v", liked)
	}
	if _, err := likes.SetStoreLike(f.ctx, bob.ID, entryID, true); !errors.Is(err, ErrNotFound) {
		t.Fatalf("liking a hidden song = %v", err)
	}
	// Likes go with the account.
	if _, err := f.catalog.pool.Exec(f.ctx, `DELETE FROM users WHERE id::text = $1`, bob.ID); err != nil {
		t.Fatal(err)
	}
	if owned, _ := likes.OwnerStates(f.ctx, carol.ID); owned[carolCopy.ID].Count != 1 {
		t.Fatalf("after bob left, carol sees %+v", owned)
	}
}

func TestLikedSongsAreNewestFirstAndPaged(t *testing.T) {
	f := newCatalogFixture(t)
	likes := NewTrackLikes(f.catalog.pool)
	alice := f.user("alice@example.com")
	var ids []string
	for _, title := range []string{"one", "two", "three"} {
		track := f.track(alice.ID, NewTrack{Title: title})
		ids = append(ids, track.ID)
		if _, err := likes.SetOwnLike(f.ctx, alice.ID, track.ID, true); err != nil {
			t.Fatal(err)
		}
	}
	for i, id := range ids {
		at := time.Now().Add(time.Duration(i) * time.Minute)
		_, _ = f.catalog.pool.Exec(f.ctx, `UPDATE track_likes SET created_at = $2 WHERE track_id::text = $1`, id, at)
	}
	page, more, _ := likes.Liked(f.ctx, alice.ID, 2, 0)
	if len(page) != 2 || !more || page[0].Track.Title != "three" || page[1].Track.Title != "two" {
		t.Fatalf("first page = %+v, %v", page, more)
	}
	page, more, _ = likes.Liked(f.ctx, alice.ID, 2, 2)
	if len(page) != 1 || more || page[0].Track.Title != "one" {
		t.Fatalf("second page = %+v, %v", page, more)
	}
	if page, _, _ := likes.Liked(f.ctx, alice.ID, 2, 9); len(page) != 0 {
		t.Fatalf("past the end = %+v", page)
	}
}
