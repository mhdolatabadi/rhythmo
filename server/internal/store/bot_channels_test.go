package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestSyncingAMessengerChannel(t *testing.T) {
	pool := newTestPool(t)
	ctx := context.Background()
	users := NewUsers(pool)
	owner, _ := users.Create(ctx, "owner@example.com", "hash")
	admin, _ := users.Create(ctx, "admin@example.com", "hash")
	stranger, _ := users.Create(ctx, "stranger@example.com", "hash")
	fan, _ := users.Create(ctx, "fan@example.com", "hash")
	playlists := NewPlaylists(pool)
	bots := NewBots(pool)
	tracks := NewTracks(pool)
	notifications := NewNotifications(pool)
	playlist, _ := playlists.Create(ctx, owner.ID, "channel")
	public := true
	playlists.Share(ctx, owner.ID, playlist.ID, "link-1", &public, true)
	playlists.SetCollabToken(ctx, owner.ID, playlist.ID, ptr("collab-1"))
	playlists.Join(ctx, admin.ID, "collab-1")
	playlists.SetMemberRole(ctx, owner.ID, playlist.ID, admin.ID, RoleAdmin)
	playlists.SetSubscription(ctx, fan.ID, "link-1", true)
	now := time.Now()

	// Only the owner and admins get channel codes.
	if err := bots.CreateChannelCode(ctx, stranger.ID, playlist.ID, []byte("x"), now.Add(time.Minute)); !errors.Is(err, ErrNotFound) {
		t.Fatalf("stranger's code = %v", err)
	}
	if err := bots.CreateChannelCode(ctx, admin.ID, playlist.ID, []byte("channel"), now.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	// A private chat code and a channel code don't stand in for each other,
	// and a private code doesn't replace a channel one.
	if err := bots.CreateLinkCode(ctx, admin.ID, []byte("private"), now.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	if _, err := bots.RedeemLinkCode(ctx, "bale", "42", []byte("channel"), now, 5, time.Hour); !errors.Is(err, ErrCodeInvalid) {
		t.Fatalf("channel code in a private chat = %v", err)
	}
	if _, err := bots.RedeemChannelCode(ctx, "bale", "-1001", "Golden", []byte("private"), now, 5, time.Hour); !errors.Is(err, ErrCodeInvalid) {
		t.Fatalf("private code in a channel = %v", err)
	}
	link, err := bots.RedeemChannelCode(ctx, "bale", "-1001", "Golden", []byte("channel"), now, 5, time.Hour)
	if err != nil || link.PlaylistID != playlist.ID || link.UserID != admin.ID || link.Title != "Golden" {
		t.Fatalf("link = %+v, %v", link, err)
	}
	if _, err := bots.RedeemChannelCode(ctx, "bale", "-1002", "Other", []byte("channel"), now, 5, time.Hour); !errors.Is(err, ErrCodeInvalid) {
		t.Fatalf("reused channel code = %v", err)
	}
	if userID, err := bots.RedeemLinkCode(ctx, "bale", "42", []byte("private"), now, 5, time.Hour); err != nil || userID != admin.ID {
		t.Fatalf("private code after a channel code = %q, %v", userID, err)
	}
	if got, err := bots.ChannelFor(ctx, "bale", "-1001"); err != nil || got.PlaylistID != playlist.ID {
		t.Fatalf("ChannelFor = %+v, %v", got, err)
	}
	if listed, err := bots.PlaylistChannels(ctx, owner.ID, playlist.ID); err != nil || len(listed) != 1 || listed[0].ChatID != "-1001" {
		t.Fatalf("owner's list = %+v, %v", listed, err)
	}
	if _, err := bots.PlaylistChannels(ctx, stranger.ID, playlist.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("stranger's list = %v", err)
	}

	// A post becomes the admin's track, added at the end, and notifies.
	first, _ := tracks.Create(ctx, owner.ID, NewTrack{Title: "first", FileName: "1.mp3", ContentType: "audio/mpeg", SizeBytes: 1})
	playlists.ReplaceTracks(ctx, owner.ID, playlist.ID, []string{first.ID})
	notifications.MarkRead(ctx, fan.ID, nil, "")
	posted, _ := tracks.Create(ctx, admin.ID, NewTrack{Title: "posted", FileName: "2.mp3", ContentType: "audio/mpeg", SizeBytes: 1})
	if err := playlists.AppendSyncedTrack(ctx, stranger.ID, playlist.ID, posted.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("stranger appending = %v", err)
	}
	ownersOther, _ := tracks.Create(ctx, owner.ID, NewTrack{Title: "other", FileName: "3.mp3", ContentType: "audio/mpeg", SizeBytes: 1})
	if err := playlists.AppendSyncedTrack(ctx, admin.ID, playlist.ID, ownersOther.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("appending someone else's track = %v", err)
	}
	for range 2 {
		if err := playlists.AppendSyncedTrack(ctx, admin.ID, playlist.ID, posted.ID); err != nil {
			t.Fatal(err)
		}
	}
	got, _ := playlists.ForUser(ctx, owner.ID, playlist.ID)
	if len(got.Tracks) != 2 || got.Tracks[1].ID != posted.ID {
		t.Fatalf("tracks after the post = %+v", got.Tracks)
	}
	if list, unread, _ := notifications.List(ctx, fan.ID, 10); unread != 1 || *list[0].TrackTitle != "posted" || list[0].TrackCount != 1 {
		t.Fatalf("fan's inbox = %+v, %d", list, unread)
	}
	if name, err := playlists.Name(ctx, playlist.ID); err != nil || name != "channel" {
		t.Fatalf("Name = %q, %v", name, err)
	}

	// An import remembers its channel.
	queued, err := bots.AddImport(ctx, BotImport{Provider: "bale", ChatID: "-1001", MessageID: "9", UserID: admin.ID,
		FileID: "f", FileName: "a.mp3", SizeBytes: 1, PlaylistID: &playlist.ID})
	if err != nil || queued.PlaylistID == nil || *queued.PlaylistID != playlist.ID {
		t.Fatalf("queued import = %+v, %v", queued, err)
	}

	// Once the admin is demoted, the link is dropped.
	playlists.SetMemberRole(ctx, owner.ID, playlist.ID, admin.ID, RoleMember)
	if _, err := bots.ChannelFor(ctx, "bale", "-1001"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("link of a demoted admin = %v", err)
	}
	if listed, _ := bots.PlaylistChannels(ctx, owner.ID, playlist.ID); len(listed) != 0 {
		t.Fatalf("stale link listed: %+v", listed)
	}

	// The owner links and removes one from the app.
	bots.CreateChannelCode(ctx, owner.ID, playlist.ID, []byte("again"), now.Add(time.Minute))
	if _, err := bots.RedeemChannelCode(ctx, "telegram", "-5", "T", []byte("again"), now, 5, time.Hour); err != nil {
		t.Fatal(err)
	}
	if err := bots.RemovePlaylistChannel(ctx, stranger.ID, playlist.ID, "telegram", "-5"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("stranger removing = %v", err)
	}
	if err := bots.RemovePlaylistChannel(ctx, owner.ID, playlist.ID, "telegram", "-5"); err != nil {
		t.Fatal(err)
	}
	if _, err := bots.ChannelFor(ctx, "telegram", "-5"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("removed link = %v", err)
	}

	// A code whose maker lost admin before it was used links nothing.
	playlists.SetMemberRole(ctx, owner.ID, playlist.ID, admin.ID, RoleAdmin)
	bots.CreateChannelCode(ctx, admin.ID, playlist.ID, []byte("late"), now.Add(time.Minute))
	playlists.SetMemberRole(ctx, owner.ID, playlist.ID, admin.ID, RoleMember)
	if _, err := bots.RedeemChannelCode(ctx, "bale", "-7", "Late", []byte("late"), now, 5, time.Hour); !errors.Is(err, ErrNotFound) {
		t.Fatalf("code of a demoted admin = %v", err)
	}
}
