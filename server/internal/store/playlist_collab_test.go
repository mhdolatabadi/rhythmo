package store

import (
	"context"
	"errors"
	"testing"
)

func TestCollaborativePlaylist(t *testing.T) {
	pool := newTestPool(t)
	ctx := context.Background()
	users := NewUsers(pool)
	owner, _ := users.Create(ctx, "owner@example.com", "hash")
	member, _ := users.Create(ctx, "member@example.com", "hash")
	other, _ := users.Create(ctx, "other@example.com", "hash")
	tracks := NewTracks(pool)
	playlists := NewPlaylists(pool)
	add := func(userID, title string, size int64) Track {
		t.Helper()
		track, err := tracks.Create(ctx, userID, NewTrack{Title: title, FileName: title + ".mp3", ContentType: "audio/mpeg", SizeBytes: size})
		if err != nil {
			t.Fatal(err)
		}
		return track
	}
	ownerTrack := add(owner.ID, "owner-song", 10)
	memberTrack := add(member.ID, "member-song", 20)
	otherTrack := add(other.ID, "other-song", 30)
	playlist, _ := playlists.Create(ctx, owner.ID, "together")
	if err := playlists.ReplaceTracks(ctx, owner.ID, playlist.ID, []string{ownerTrack.ID}); err != nil {
		t.Fatal(err)
	}
	ids := func(list []Track) []string {
		out := []string{}
		for _, track := range list {
			out = append(out, track.ID)
		}
		return out
	}
	tracksOf := func(userID string) []string {
		t.Helper()
		got, err := playlists.ForUser(ctx, userID, playlist.ID)
		if err != nil {
			t.Fatal(err)
		}
		return ids(got.Tracks)
	}
	equal := func(got, want []string) bool {
		if len(got) != len(want) {
			return false
		}
		for i := range got {
			if got[i] != want[i] {
				return false
			}
		}
		return true
	}

	// Before joining, a stranger can't see or change the playlist.
	if _, err := playlists.ForUser(ctx, member.ID, playlist.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("non-member sees the playlist: %v", err)
	}
	if err := playlists.ReplaceTracks(ctx, member.ID, playlist.ID, []string{ownerTrack.ID, memberTrack.ID}); !errors.Is(err, ErrNotFound) {
		t.Fatalf("non-member adds: %v", err)
	}
	if _, err := playlists.SetCollabToken(ctx, member.ID, playlist.ID, ptr("stolen")); !errors.Is(err, ErrNotFound) {
		t.Fatalf("non-owner makes a link: %v", err)
	}
	if _, err := playlists.Join(ctx, member.ID, "nothing"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("join without a link: %v", err)
	}

	// The owner's link lets the member join, once.
	if _, err := playlists.SetCollabToken(ctx, owner.ID, playlist.ID, ptr("link-1")); err != nil {
		t.Fatal(err)
	}
	joined, err := playlists.Join(ctx, member.ID, "link-1")
	if err != nil || joined.ID != playlist.ID || len(joined.Members) != 1 || joined.Members[0].Email != "member@example.com" {
		t.Fatalf("join = %+v, %v", joined, err)
	}
	if _, err := playlists.Join(ctx, member.ID, "link-1"); err != nil {
		t.Fatalf("joining twice: %v", err)
	}
	if own, err := playlists.Join(ctx, owner.ID, "link-1"); err != nil || len(own.Members) != 1 {
		t.Fatalf("owner joining own playlist = %+v, %v", own, err)
	}
	listed, _ := playlists.ListForUser(ctx, member.ID)
	if len(listed) != 1 || listed[0].ID != playlist.ID {
		t.Fatalf("member's playlists = %+v", listed)
	}

	// Members add their own tracks only.
	if err := playlists.ReplaceTracks(ctx, member.ID, playlist.ID, []string{ownerTrack.ID, otherTrack.ID}); !errors.Is(err, ErrNotFound) {
		t.Fatalf("member adds someone else's track: %v", err)
	}
	if err := playlists.ReplaceTracks(ctx, member.ID, playlist.ID, []string{memberTrack.ID, ownerTrack.ID}); err != nil {
		t.Fatalf("member adds own track: %v", err)
	}
	if got := tracksOf(owner.ID); !equal(got, []string{memberTrack.ID, ownerTrack.ID}) {
		t.Fatalf("owner sees %v", got)
	}
	// The owner can't slip in a member's track that isn't in the playlist.
	if err := playlists.ReplaceTracks(ctx, owner.ID, playlist.ID, []string{memberTrack.ID, ownerTrack.ID, otherTrack.ID}); !errors.Is(err, ErrNotFound) {
		t.Fatalf("owner adds a stranger's track: %v", err)
	}

	// Members play each other's tracks through the playlist; others can't.
	if got, err := playlists.PlaylistTrack(ctx, owner.ID, playlist.ID, memberTrack.ID); err != nil || got.ID != memberTrack.ID {
		t.Fatalf("owner plays member's track = %+v, %v", got, err)
	}
	if _, err := playlists.PlaylistTrack(ctx, other.ID, playlist.ID, memberTrack.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("stranger plays member's track: %v", err)
	}

	// A shared collaborative playlist shows and plays everyone's tracks.
	if _, err := playlists.Share(ctx, owner.ID, playlist.ID, "share-1", nil, true); err != nil {
		t.Fatal(err)
	}
	if shared, err := playlists.ForShareToken(ctx, "share-1"); err != nil || len(shared.Tracks) != 2 {
		t.Fatalf("shared = %+v, %v", shared, err)
	}
	if _, err := playlists.SharedTrack(ctx, "share-1", memberTrack.ID, false); err != nil {
		t.Fatalf("shared member track: %v", err)
	}

	// Each track still counts against whoever added it.
	if used, _ := tracks.UsageForOwner(ctx, member.ID); used != 20 {
		t.Fatalf("member usage = %d", used)
	}
	if used, _ := tracks.UsageForOwner(ctx, owner.ID); used != 10 {
		t.Fatalf("owner usage = %d", used)
	}

	// A member can't take out the owner's track; the owner can take out any.
	if err := playlists.ReplaceTracks(ctx, member.ID, playlist.ID, []string{memberTrack.ID}); !errors.Is(err, ErrForbidden) {
		t.Fatalf("member removes owner's track: %v", err)
	}
	if err := playlists.ReplaceTracks(ctx, member.ID, playlist.ID, []string{ownerTrack.ID, memberTrack.ID}); err != nil {
		t.Fatalf("member reorders: %v", err)
	}
	if err := playlists.ReplaceTracks(ctx, member.ID, playlist.ID, []string{ownerTrack.ID}); err != nil {
		t.Fatalf("member removes own track: %v", err)
	}
	playlists.ReplaceTracks(ctx, member.ID, playlist.ID, []string{ownerTrack.ID, memberTrack.ID})
	if err := playlists.ReplaceTracks(ctx, owner.ID, playlist.ID, []string{ownerTrack.ID}); err != nil {
		t.Fatalf("owner removes member's track: %v", err)
	}

	// A new link stops the old one; revoking stops all. Members stay.
	playlists.SetCollabToken(ctx, owner.ID, playlist.ID, ptr("link-2"))
	if _, err := playlists.Join(ctx, other.ID, "link-1"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("old link still joins: %v", err)
	}
	playlists.SetCollabToken(ctx, owner.ID, playlist.ID, nil)
	if _, err := playlists.Join(ctx, other.ID, "link-2"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("revoked link still joins: %v", err)
	}
	if _, err := playlists.ForUser(ctx, member.ID, playlist.ID); err != nil {
		t.Fatalf("member lost access on revoke: %v", err)
	}

	// Members can't remove each other; leaving takes their tracks out.
	playlists.SetCollabToken(ctx, owner.ID, playlist.ID, ptr("link-3"))
	playlists.Join(ctx, other.ID, "link-3")
	if err := playlists.RemoveMember(ctx, member.ID, playlist.ID, other.ID); !errors.Is(err, ErrForbidden) {
		t.Fatalf("member removes member: %v", err)
	}
	playlists.ReplaceTracks(ctx, member.ID, playlist.ID, []string{ownerTrack.ID, memberTrack.ID})
	if err := playlists.RemoveMember(ctx, member.ID, playlist.ID, member.ID); err != nil {
		t.Fatalf("leave: %v", err)
	}
	if got := tracksOf(owner.ID); !equal(got, []string{ownerTrack.ID}) {
		t.Fatalf("after leaving, tracks = %v", got)
	}
	if _, err := playlists.ForUser(ctx, member.ID, playlist.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("left member still sees it: %v", err)
	}
	if err := playlists.RemoveMember(ctx, owner.ID, playlist.ID, member.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("removing a non-member: %v", err)
	}

	// The owner removes a member, with their tracks.
	playlists.ReplaceTracks(ctx, other.ID, playlist.ID, []string{ownerTrack.ID, otherTrack.ID})
	if err := playlists.RemoveMember(ctx, owner.ID, playlist.ID, other.ID); err != nil {
		t.Fatalf("owner removes member: %v", err)
	}
	if got := tracksOf(owner.ID); !equal(got, []string{ownerTrack.ID}) {
		t.Fatalf("after removal, tracks = %v", got)
	}

	// Deleting a member's account or track takes it out of the playlist.
	playlists.Join(ctx, member.ID, "link-3")
	playlists.ReplaceTracks(ctx, member.ID, playlist.ID, []string{ownerTrack.ID, memberTrack.ID})
	if _, err := pool.Exec(ctx, `DELETE FROM users WHERE id = $1::uuid`, member.ID); err != nil {
		t.Fatal(err)
	}
	if got := tracksOf(owner.ID); !equal(got, []string{ownerTrack.ID}) {
		t.Fatalf("after deleting the member, tracks = %v", got)
	}

	// Deleting the playlist removes its memberships.
	playlists.Join(ctx, other.ID, "link-3")
	if err := playlists.Delete(ctx, owner.ID, playlist.ID); err != nil {
		t.Fatal(err)
	}
	var left int
	pool.QueryRow(ctx, `SELECT count(*) FROM playlist_members`).Scan(&left)
	if left != 0 {
		t.Fatalf("memberships left after delete: %d", left)
	}
}

func ptr(s string) *string { return &s }
