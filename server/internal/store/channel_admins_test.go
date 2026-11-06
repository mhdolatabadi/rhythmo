package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestChannelAdmins(t *testing.T) {
	pool := newTestPool(t)
	ctx := context.Background()
	users := NewUsers(pool)
	owner, _ := users.Create(ctx, "owner@example.com", "hash")
	admin, _ := users.Create(ctx, "admin@example.com", "hash")
	coAdmin, _ := users.Create(ctx, "coadmin@example.com", "hash")
	member, _ := users.Create(ctx, "member@example.com", "hash")
	stranger, _ := users.Create(ctx, "stranger@example.com", "hash")
	tracks := NewTracks(pool)
	playlists := NewPlaylists(pool)
	add := func(userID, title string) Track {
		t.Helper()
		track, err := tracks.Create(ctx, userID, NewTrack{Title: title, FileName: title + ".mp3", ContentType: "audio/mpeg", SizeBytes: 1})
		if err != nil {
			t.Fatal(err)
		}
		return track
	}
	ownerTrack, memberTrack := add(owner.ID, "owner-song"), add(member.ID, "member-song")
	playlist, _ := playlists.Create(ctx, owner.ID, "channel")
	playlists.SetCollabToken(ctx, owner.ID, playlist.ID, ptr("collab-1"))
	for _, u := range []User{admin, coAdmin, member} {
		if _, err := playlists.Join(ctx, u.ID, "collab-1"); err != nil {
			t.Fatal(err)
		}
	}
	playlists.ReplaceTracks(ctx, owner.ID, playlist.ID, []string{ownerTrack.ID})
	playlists.ReplaceTracks(ctx, member.ID, playlist.ID, []string{ownerTrack.ID, memberTrack.ID})

	// Only the owner sets roles.
	if err := playlists.SetMemberRole(ctx, admin.ID, playlist.ID, admin.ID, RoleAdmin); !errors.Is(err, ErrNotFound) {
		t.Fatalf("member making themselves admin = %v", err)
	}
	if err := playlists.SetMemberRole(ctx, owner.ID, playlist.ID, stranger.ID, RoleAdmin); !errors.Is(err, ErrNotFound) {
		t.Fatalf("making a non-member admin = %v", err)
	}
	for _, u := range []User{admin, coAdmin} {
		if err := playlists.SetMemberRole(ctx, owner.ID, playlist.ID, u.ID, RoleAdmin); err != nil {
			t.Fatal(err)
		}
	}
	got, err := playlists.ForUser(ctx, admin.ID, playlist.ID)
	if err != nil || !got.ViewerAdmin || got.Members[0].Role != RoleAdmin || got.Members[2].Role != RoleMember {
		t.Fatalf("admin's view = %+v, %v", got, err)
	}
	listed, _ := playlists.ListForUser(ctx, admin.ID)
	if len(listed) != 1 || !listed[0].ViewerAdmin {
		t.Fatalf("admin's list = %+v", listed)
	}
	if listed, _ := playlists.ListForUser(ctx, member.ID); listed[0].ViewerAdmin {
		t.Fatal("a plain member is listed as admin")
	}

	// An admin edits the name and description; a member can't.
	description := "best of the 70s"
	if _, err := playlists.Rename(ctx, member.ID, playlist.ID, "taken", &description); !errors.Is(err, ErrNotFound) {
		t.Fatalf("member renaming = %v", err)
	}
	renamed, err := playlists.Rename(ctx, admin.ID, playlist.ID, "golden", &description)
	if err != nil || renamed.Name != "golden" || renamed.Description != description {
		t.Fatalf("admin renaming = %+v, %v", renamed, err)
	}
	if kept, _ := playlists.Rename(ctx, owner.ID, playlist.ID, "golden oldies", nil); kept.Description != description {
		t.Fatalf("renaming without a description cleared it: %+v", kept)
	}

	// An admin may take out anyone's track; a member only their own.
	if err := playlists.ReplaceTracks(ctx, member.ID, playlist.ID, []string{memberTrack.ID}); !errors.Is(err, ErrForbidden) {
		t.Fatalf("member removing the owner's track = %v", err)
	}
	if err := playlists.ReplaceTracks(ctx, admin.ID, playlist.ID, []string{memberTrack.ID}); err != nil {
		t.Fatalf("admin removing the owner's track = %v", err)
	}

	// An admin removes plain members but not other admins.
	if err := playlists.RemoveMember(ctx, admin.ID, playlist.ID, coAdmin.ID); !errors.Is(err, ErrForbidden) {
		t.Fatalf("admin removing an admin = %v", err)
	}
	if err := playlists.RemoveMember(ctx, member.ID, playlist.ID, admin.ID); !errors.Is(err, ErrForbidden) {
		t.Fatalf("member removing an admin = %v", err)
	}
	if err := playlists.RemoveMember(ctx, admin.ID, playlist.ID, stranger.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("admin removing a stranger = %v", err)
	}
	if err := playlists.RemoveMember(ctx, admin.ID, playlist.ID, member.ID); err != nil {
		t.Fatalf("admin removing a member = %v", err)
	}
	if got, _ := playlists.ForUser(ctx, owner.ID, playlist.ID); len(got.Tracks) != 0 || len(got.Members) != 2 {
		t.Fatalf("after removing the member = %+v", got)
	}
	// An admin can still leave, and the owner can demote.
	if err := playlists.SetMemberRole(ctx, owner.ID, playlist.ID, coAdmin.ID, RoleMember); err != nil {
		t.Fatal(err)
	}
	if err := playlists.RemoveMember(ctx, admin.ID, playlist.ID, coAdmin.ID); err != nil {
		t.Fatalf("admin removing a demoted admin = %v", err)
	}
	if err := playlists.RemoveMember(ctx, admin.ID, playlist.ID, admin.ID); err != nil {
		t.Fatalf("admin leaving = %v", err)
	}
}

func TestMutingAChannel(t *testing.T) {
	pool := newTestPool(t)
	ctx := context.Background()
	users := NewUsers(pool)
	owner, _ := users.Create(ctx, "owner@example.com", "hash")
	fan, _ := users.Create(ctx, "fan@example.com", "hash")
	tracks := NewTracks(pool)
	playlists := NewPlaylists(pool)
	notifications := NewNotifications(pool)
	first, _ := tracks.Create(ctx, owner.ID, NewTrack{Title: "first", FileName: "1.mp3", ContentType: "audio/mpeg", SizeBytes: 1})
	second, _ := tracks.Create(ctx, owner.ID, NewTrack{Title: "second", FileName: "2.mp3", ContentType: "audio/mpeg", SizeBytes: 1})
	playlist, _ := playlists.Create(ctx, owner.ID, "channel")
	public := true
	playlists.Share(ctx, owner.ID, playlist.ID, "link-1", &public, true)

	if _, err := playlists.SetMuted(ctx, fan.ID, "link-1", true); !errors.Is(err, ErrNotFound) {
		t.Fatalf("muting without subscribing = %v", err)
	}
	playlists.SetSubscription(ctx, fan.ID, "link-1", true)
	s, err := playlists.SetMuted(ctx, fan.ID, "link-1", true)
	if err != nil || !s.Muted || !s.Subscribed || s.Count != 1 {
		t.Fatalf("mute = %+v, %v", s, err)
	}
	if again, _ := playlists.SetMuted(ctx, fan.ID, "link-1", true); !again.Muted {
		t.Fatal("muting twice unmuted")
	}

	since := time.Now().Add(-time.Hour)
	playlists.ReplaceTracks(ctx, owner.ID, playlist.ID, []string{first.ID})
	if list, unread, _ := notifications.List(ctx, fan.ID, 10); len(list) != 1 || unread != 0 {
		t.Fatalf("muted inbox = %+v, %d unread", list, unread)
	}
	if pending, _ := notifications.PendingPushes(ctx, since, 10); len(pending) != 0 {
		t.Fatalf("muted notice is pending a push: %+v", pending)
	}
	if listed, _ := playlists.Subscribed(ctx, fan.ID); len(listed) != 1 || !listed[0].Muted || listed[0].Unread != 1 {
		t.Fatalf("muted subscription = %+v", listed)
	}

	// Unmuting counts it again, but what came while muted isn't pushed late.
	if s, _ := playlists.SetMuted(ctx, fan.ID, "link-1", false); s.Muted {
		t.Fatal("still muted")
	}
	if unread, _ := notifications.UnreadCount(ctx, fan.ID); unread != 1 {
		t.Fatalf("unread after unmuting = %d", unread)
	}
	if pending, _ := notifications.PendingPushes(ctx, since, 10); len(pending) != 0 {
		t.Fatalf("backlog pushed after unmuting: %+v", pending)
	}
	time.Sleep(10 * time.Millisecond)
	playlists.ReplaceTracks(ctx, owner.ID, playlist.ID, []string{first.ID, second.ID})
	if pending, _ := notifications.PendingPushes(ctx, since, 10); len(pending) != 1 {
		t.Fatalf("new addition after unmuting isn't pending: %+v", pending)
	}
	if s, _ := playlists.SubscriptionFor(ctx, playlist.ID, fan.ID); s.Muted || !s.Subscribed {
		t.Fatalf("subscription = %+v", s)
	}
}
