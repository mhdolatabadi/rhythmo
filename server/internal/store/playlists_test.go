package store

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"testing"
)

func TestPlaylistListsItsReadyTracksInOrder(t *testing.T) {
	pool := newTestPool(t)
	ctx := context.Background()
	user, _ := NewUsers(pool).Create(ctx, "playlist@example.com", "hash")
	tracks := NewTracks(pool)
	playlists := NewPlaylists(pool)

	first, _ := tracks.Create(ctx, user.ID, NewTrack{Title: "first", FileName: "a.mp3", ContentType: "audio/mpeg", SizeBytes: 1})
	second, _ := tracks.Create(ctx, user.ID, NewTrack{Title: "second", FileName: "b.mp3", ContentType: "audio/mpeg", SizeBytes: 1, Source: "bale"})
	playlist, err := playlists.Create(ctx, user.ID, "mix")
	if err != nil {
		t.Fatal(err)
	}
	if err := playlists.ReplaceTracks(ctx, user.ID, playlist.ID, []string{second.ID, first.ID}); err != nil {
		t.Fatal(err)
	}

	got, err := playlists.ForUser(ctx, user.ID, playlist.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Tracks) != 2 || got.Tracks[0].ID != second.ID || got.Tracks[0].Source != "bale" || got.Tracks[1].ID != first.ID {
		t.Fatalf("tracks = %+v", got.Tracks)
	}
}

func TestSharingAPlaylist(t *testing.T) {
	pool := newTestPool(t)
	ctx := context.Background()
	owner, _ := NewUsers(pool).Create(ctx, "owner@example.com", "hash")
	other, _ := NewUsers(pool).Create(ctx, "other@example.com", "hash")
	tracks := NewTracks(pool)
	playlists := NewPlaylists(pool)

	inList, _ := tracks.Create(ctx, owner.ID, NewTrack{Title: "in", FileName: "a.mp3", ContentType: "audio/mpeg", SizeBytes: 1})
	notInList, _ := tracks.Create(ctx, owner.ID, NewTrack{Title: "out", FileName: "b.mp3", ContentType: "audio/mpeg", SizeBytes: 1})
	playlist, _ := playlists.Create(ctx, owner.ID, "mix")
	playlists.ReplaceTracks(ctx, owner.ID, playlist.ID, []string{inList.ID})

	if _, err := playlists.ForShareToken(ctx, "nothing"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("unshared lookup: %v", err)
	}
	if _, err := playlists.Share(ctx, other.ID, playlist.ID, "stolen", nil, true); !errors.Is(err, ErrNotFound) {
		t.Fatalf("sharing someone else's playlist: %v", err)
	}
	shared, err := playlists.Share(ctx, owner.ID, playlist.ID, "token-1", nil, true)
	if err != nil || shared.ShareToken == nil || *shared.ShareToken != "token-1" {
		t.Fatalf("share = %+v, %v", shared, err)
	}
	again, _ := playlists.Share(ctx, owner.ID, playlist.ID, "token-2", nil, true)
	if *again.ShareToken != "token-1" {
		t.Fatalf("sharing again changed the link: %q", *again.ShareToken)
	}

	view, err := playlists.ForShareToken(ctx, "token-1")
	if err != nil || view.Name != "mix" || view.OwnerEmail != "owner@example.com" ||
		len(view.Tracks) != 1 || view.Tracks[0].ID != inList.ID {
		t.Fatalf("shared view = %+v, %v", view, err)
	}
	if got, err := playlists.SharedTrack(ctx, "token-1", inList.ID, false); err != nil || got.ID != inList.ID {
		t.Fatalf("track in the playlist = %+v, %v", got, err)
	}
	if _, err := playlists.SharedTrack(ctx, "token-1", notInList.ID, false); !errors.Is(err, ErrNotFound) {
		t.Fatalf("track outside the playlist: %v", err)
	}

	other2, _ := playlists.Create(ctx, other.ID, "theirs")
	if _, err := playlists.Share(ctx, other.ID, other2.ID, "token-1", nil, true); !errors.Is(err, ErrShareTokenTaken) {
		t.Fatalf("colliding token: %v", err)
	}

	if err := playlists.Unshare(ctx, owner.ID, playlist.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := playlists.ForShareToken(ctx, "token-1"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("after unsharing: %v", err)
	}
	if _, err := playlists.SharedTrack(ctx, "token-1", inList.ID, false); !errors.Is(err, ErrNotFound) {
		t.Fatalf("track after unsharing: %v", err)
	}
	reshared, _ := playlists.Share(ctx, owner.ID, playlist.ID, "token-3", nil, true)
	if *reshared.ShareToken != "token-3" {
		t.Fatalf("resharing reused the old link: %q", *reshared.ShareToken)
	}
}

type memoryObjects struct {
	objects map[string]string
	failAt  int
	copies  int
}

func (m *memoryObjects) Copy(_ context.Context, src, dst string) error {
	m.copies++
	if m.copies == m.failAt {
		return errors.New("minio down")
	}
	m.objects[dst] = m.objects[src]
	return nil
}

func (m *memoryObjects) Remove(_ context.Context, key string) error {
	delete(m.objects, key)
	return nil
}

func TestSavingASharedPlaylistCopiesItIntoTheAccount(t *testing.T) {
	pool := newTestPool(t)
	ctx := context.Background()
	owner, _ := NewUsers(pool).Create(ctx, "owner@example.com", "hash")
	friend, _ := NewUsers(pool).Create(ctx, "friend@example.com", "hash")
	tracks := NewTracks(pool)
	playlists := NewPlaylists(pool)
	objects := &memoryObjects{objects: map[string]string{}}

	artist := "خواننده"
	a, _ := tracks.Create(ctx, owner.ID, NewTrack{Title: "a", Artist: &artist, FileName: "a.mp3", ContentType: "audio/mpeg", SizeBytes: 100})
	b, _ := tracks.Create(ctx, owner.ID, NewTrack{Title: "b", FileName: "b.flac", ContentType: "audio/flac", SizeBytes: 200})
	objects.objects[a.StorageKey], objects.objects[b.StorageKey] = "A", "B"
	playlist, _ := playlists.Create(ctx, owner.ID, "mix")
	playlists.ReplaceTracks(ctx, owner.ID, playlist.ID, []string{b.ID, a.ID})
	playlists.Share(ctx, owner.ID, playlist.ID, "tok", nil, true)

	if _, err := playlists.SaveShared(ctx, owner.ID, "tok", 1000, objects); !errors.Is(err, ErrOwnPlaylist) {
		t.Fatalf("owner saving their own: %v", err)
	}
	if _, err := playlists.SaveShared(ctx, friend.ID, "tok", 250, objects); !errors.Is(err, ErrQuotaExceeded) {
		t.Fatalf("over quota: %v", err)
	}
	if _, err := playlists.SaveShared(ctx, friend.ID, "nope", 1000, objects); !errors.Is(err, ErrNotFound) {
		t.Fatalf("unknown link: %v", err)
	}

	objects.failAt = 2
	if _, err := playlists.SaveShared(ctx, friend.ID, "tok", 1000, objects); err == nil {
		t.Fatal("a failed copy was not reported")
	}
	if usage, _ := tracks.UsageForOwner(ctx, friend.ID); usage != 0 || len(objects.objects) != 2 {
		t.Fatalf("failed save left usage %d, objects %v", usage, objects.objects)
	}

	objects.failAt = 0
	saved, err := playlists.SaveShared(ctx, friend.ID, "tok", 1000, objects)
	if err != nil {
		t.Fatal(err)
	}
	if saved.OwnerID != friend.ID || saved.Name != "mix" || saved.ShareToken != nil || len(saved.Tracks) != 2 {
		t.Fatalf("saved = %+v", saved)
	}
	first := saved.Tracks[0]
	if first.OwnerID != friend.ID || first.Title != "b" || first.Source != "shared" || first.Status != TrackReady ||
		first.ID == b.ID || objects.objects[first.StorageKey] != "B" || saved.Tracks[1].Artist == nil {
		t.Fatalf("copied tracks = %+v", saved.Tracks)
	}
	if list, _ := tracks.ListForOwner(ctx, friend.ID); len(list) != 2 {
		t.Fatalf("friend's library has %d tracks", len(list))
	}

	// The copies are the friend's own: revoking the link or deleting the
	// originals does not touch them.
	playlists.Unshare(ctx, owner.ID, playlist.ID)
	tracks.Delete(ctx, owner.ID, a.ID)
	if again, _ := playlists.ForUser(ctx, friend.ID, saved.ID); len(again.Tracks) != 2 {
		t.Fatalf("saved playlist changed with the original: %+v", again.Tracks)
	}
}

func TestLikingASharedPlaylist(t *testing.T) {
	pool := newTestPool(t)
	ctx := context.Background()
	users := NewUsers(pool)
	owner, _ := users.Create(ctx, "likes-owner@example.com", "hash")
	fan, _ := users.Create(ctx, "fan@example.com", "hash")
	playlists := NewPlaylists(pool)
	playlist, _ := playlists.Create(ctx, owner.ID, "mix")

	if _, err := playlists.SetLike(ctx, fan.ID, "tok", true); !errors.Is(err, ErrNotFound) {
		t.Fatalf("liking an unshared playlist: %v", err)
	}
	playlists.Share(ctx, owner.ID, playlist.ID, "tok", nil, true)

	for range 2 {
		likes, err := playlists.SetLike(ctx, fan.ID, "tok", true)
		if err != nil || likes != (Likes{Count: 1, Liked: true}) {
			t.Fatalf("like = %+v %v", likes, err)
		}
	}
	if likes, _ := playlists.LikesFor(ctx, playlist.ID, owner.ID); likes != (Likes{Count: 1}) {
		t.Fatalf("owner sees %+v", likes)
	}

	// Unsharing hides the likes but keeps them for when it is shared again.
	playlists.Unshare(ctx, owner.ID, playlist.ID)
	if _, err := playlists.SetLike(ctx, fan.ID, "tok", false); !errors.Is(err, ErrNotFound) {
		t.Fatalf("unliking through a revoked link: %v", err)
	}
	playlists.Share(ctx, owner.ID, playlist.ID, "tok2", nil, true)
	if likes, _ := playlists.LikesFor(ctx, playlist.ID, fan.ID); likes != (Likes{Count: 1, Liked: true}) {
		t.Fatalf("after resharing = %+v", likes)
	}

	for range 2 {
		likes, err := playlists.SetLike(ctx, fan.ID, "tok2", false)
		if err != nil || likes != (Likes{}) {
			t.Fatalf("unlike = %+v %v", likes, err)
		}
	}

	// Deleting the playlist or the user takes their likes with it.
	playlists.SetLike(ctx, fan.ID, "tok2", true)
	playlists.Delete(ctx, owner.ID, playlist.ID)
	var left int
	pool.QueryRow(ctx, `SELECT count(*) FROM playlist_likes`).Scan(&left)
	if left != 0 {
		t.Fatalf("%d likes outlived their playlist", left)
	}
}

func TestConcurrentLikesAreCountedOnce(t *testing.T) {
	pool := newTestPool(t)
	ctx := context.Background()
	users := NewUsers(pool)
	owner, _ := users.Create(ctx, "busy-owner@example.com", "hash")
	playlists := NewPlaylists(pool)
	playlist, _ := playlists.Create(ctx, owner.ID, "hit")
	playlists.Share(ctx, owner.ID, playlist.ID, "tok", nil, true)

	var fans []User
	for i := range 5 {
		fan, err := users.Create(ctx, fmt.Sprintf("fan%d@example.com", i), "hash")
		if err != nil {
			t.Fatal(err)
		}
		fans = append(fans, fan)
	}
	var wg sync.WaitGroup
	for _, fan := range fans {
		for range 4 {
			wg.Add(1)
			go func() {
				defer wg.Done()
				if _, err := playlists.SetLike(ctx, fan.ID, "tok", true); err != nil {
					t.Error(err)
				}
			}()
		}
	}
	wg.Wait()
	if likes, _ := playlists.LikesFor(ctx, playlist.ID, fans[0].ID); likes != (Likes{Count: 5, Liked: true}) {
		t.Fatalf("likes = %+v", likes)
	}
	pool.Exec(ctx, `DELETE FROM users WHERE id::text = $1`, fans[0].ID)
	if likes, _ := playlists.LikesFor(ctx, playlist.ID, owner.ID); likes.Count != 4 {
		t.Fatalf("after a fan is deleted = %+v", likes)
	}
}

func TestOnlyPublicPlaylistsAreListedMostLikedFirst(t *testing.T) {
	pool := newTestPool(t)
	ctx := context.Background()
	users := NewUsers(pool)
	owner, _ := users.Create(ctx, "lister@example.com", "hash")
	fan, _ := users.Create(ctx, "listener@example.com", "hash")
	other, _ := users.Create(ctx, "other-listener@example.com", "hash")
	tracks := NewTracks(pool)
	playlists := NewPlaylists(pool)
	public, private := true, false

	song, _ := tracks.Create(ctx, owner.ID, NewTrack{Title: "s", FileName: "a.mp3", ContentType: "audio/mpeg", SizeBytes: 1})
	quiet, _ := playlists.Create(ctx, owner.ID, "quiet")
	loved, _ := playlists.Create(ctx, owner.ID, "loved")
	linkOnly, _ := playlists.Create(ctx, owner.ID, "link only")
	unshared, _ := playlists.Create(ctx, owner.ID, "unshared")
	playlists.ReplaceTracks(ctx, owner.ID, loved.ID, []string{song.ID})
	playlists.Share(ctx, owner.ID, quiet.ID, "quiet", &public, true)
	playlists.Share(ctx, owner.ID, loved.ID, "loved", &public, true)
	playlists.Share(ctx, owner.ID, linkOnly.ID, "link", &private, true)
	playlists.Share(ctx, owner.ID, unshared.ID, "gone", &public, true)
	playlists.Unshare(ctx, owner.ID, unshared.ID)
	for _, u := range []User{fan, other} {
		playlists.SetLike(ctx, u.ID, "loved", true)
		playlists.SetLike(ctx, u.ID, "link", true)
	}

	listed, err := playlists.Popular(ctx, fan.ID, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(listed) != 2 || listed[0].Name != "loved" || listed[1].Name != "quiet" {
		t.Fatalf("listed = %+v", listed)
	}
	if first := listed[0]; first.Likes != (Likes{Count: 2, Liked: true}) || first.TrackCount != 1 ||
		first.ShareToken != "loved" || first.OwnerEmail != owner.Email {
		t.Fatalf("most liked = %+v", first)
	}
	if limited, _ := playlists.Popular(ctx, fan.ID, 1); len(limited) != 1 {
		t.Fatalf("limit ignored: %d", len(limited))
	}

	// An admin takes a playlist out of the list and puts it back; its link
	// keeps working, and each change is audited once.
	if err := playlists.SetPopularHidden(ctx, "missing", other.ID, true); !errors.Is(err, ErrNotFound) {
		t.Fatalf("hiding an unknown link: %v", err)
	}
	for range 2 {
		if err := playlists.SetPopularHidden(ctx, "loved", other.ID, true); err != nil {
			t.Fatal(err)
		}
	}
	if hidden, _ := playlists.Popular(ctx, fan.ID, 10); len(hidden) != 1 || hidden[0].Name != "quiet" {
		t.Fatalf("hidden playlist still listed: %+v", hidden)
	}
	if _, err := playlists.ForShareToken(ctx, "loved"); err != nil {
		t.Fatalf("hidden playlist's link: %v", err)
	}
	if err := playlists.SetPopularHidden(ctx, "loved", other.ID, false); err != nil {
		t.Fatal(err)
	}
	if restored, _ := playlists.Popular(ctx, fan.ID, 10); len(restored) != 2 || restored[0].Name != "loved" {
		t.Fatalf("restored = %+v", restored)
	}
	var audited int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM popular_playlist_audit WHERE actor_id::text = $1`, other.ID).Scan(&audited); err != nil || audited != 2 {
		t.Fatalf("audit rows = %d, %v", audited, err)
	}

	// Visitors without an account reach only public playlists' tracks.
	if _, err := playlists.SharedTrack(ctx, "loved", song.ID, true); err != nil {
		t.Fatalf("public track for a visitor: %v", err)
	}
	linkSong, _ := tracks.Create(ctx, owner.ID, NewTrack{Title: "l", FileName: "l.mp3", ContentType: "audio/mpeg", SizeBytes: 1})
	playlists.ReplaceTracks(ctx, owner.ID, linkOnly.ID, []string{linkSong.ID})
	if _, err := playlists.SharedTrack(ctx, "link", linkSong.ID, true); !errors.Is(err, ErrNotFound) {
		t.Fatalf("link-only track for a visitor: %v", err)
	}
	if _, err := playlists.SharedTrack(ctx, "link", linkSong.ID, false); err != nil {
		t.Fatalf("link-only track for someone with the link: %v", err)
	}

	// Sharing again without saying keeps it public; unsharing resets it.
	again, _ := playlists.Share(ctx, owner.ID, quiet.ID, "x", nil, true)
	if !again.IsPublic {
		t.Fatal("resharing made it link-only")
	}
	playlists.Unshare(ctx, owner.ID, quiet.ID)
	reshared, _ := playlists.Share(ctx, owner.ID, quiet.ID, "y", nil, true)
	if reshared.IsPublic {
		t.Fatal("a reshared playlist is public by default")
	}

	// An admin deletes someone's public playlist: it is gone with its likes,
	// its tracks stay in the owner's library, and the deletion is on record.
	if err := playlists.DeleteShared(ctx, "missing", other.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("deleting an unknown link: %v", err)
	}
	if err := playlists.DeleteShared(ctx, "loved", other.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := playlists.ForShareToken(ctx, "loved"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("deleted playlist's link: %v", err)
	}
	if _, err := playlists.ForUser(ctx, owner.ID, loved.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("deleted playlist for its owner: %v", err)
	}
	if _, err := tracks.ForOwner(ctx, owner.ID, song.ID); err != nil {
		t.Fatalf("the owner's track went with the playlist: %v", err)
	}
	if left, _ := playlists.Popular(ctx, fan.ID, 10); len(left) != 0 {
		t.Fatalf("after deletion = %+v", left)
	}
	var name, owned string
	if err := pool.QueryRow(ctx, `SELECT name, owner_id::text FROM playlist_deletion_audit WHERE actor_id::text = $1`, other.ID).Scan(&name, &owned); err != nil || name != "loved" || owned != owner.ID {
		t.Fatalf("deletion audit = %q %q, %v", name, owned, err)
	}
}
