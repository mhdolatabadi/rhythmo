package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestSubscribingToAPublicPlaylist(t *testing.T) {
	pool := newTestPool(t)
	ctx := context.Background()
	users := NewUsers(pool)
	owner, _ := users.Create(ctx, "owner@example.com", "hash")
	fan, _ := users.Create(ctx, "fan@example.com", "hash")
	playlists := NewPlaylists(pool)
	playlist, _ := playlists.Create(ctx, owner.ID, "channel")

	if _, err := playlists.SetSubscription(ctx, fan.ID, "link-1", true); !errors.Is(err, ErrNotFound) {
		t.Fatalf("subscribing to an unshared playlist: %v", err)
	}
	if _, err := playlists.Share(ctx, owner.ID, playlist.ID, "link-1", nil, true); err != nil {
		t.Fatal(err)
	}
	if _, err := playlists.SetSubscription(ctx, fan.ID, "link-1", true); !errors.Is(err, ErrNotFound) {
		t.Fatalf("subscribing to a link-only playlist: %v", err)
	}
	public := true
	playlists.Share(ctx, owner.ID, playlist.ID, "unused", &public, true)
	if _, err := playlists.SetSubscription(ctx, owner.ID, "link-1", true); !errors.Is(err, ErrOwnPlaylist) {
		t.Fatalf("owner subscribing: %v", err)
	}
	for range 2 {
		s, err := playlists.SetSubscription(ctx, fan.ID, "link-1", true)
		if err != nil || s != (Subscription{Count: 1, Subscribed: true}) {
			t.Fatalf("subscribe = %+v, %v", s, err)
		}
	}
	if s, _ := playlists.SubscriptionFor(ctx, playlist.ID, owner.ID); s != (Subscription{Count: 1}) {
		t.Fatalf("owner sees %+v", s)
	}
	listed, err := playlists.Subscribed(ctx, fan.ID)
	if err != nil || len(listed) != 1 || listed[0].ShareToken != "link-1" || listed[0].Name != "channel" {
		t.Fatalf("subscribed = %+v, %v", listed, err)
	}
	if s, err := playlists.SetSubscription(ctx, fan.ID, "link-1", false); err != nil || s != (Subscription{}) {
		t.Fatalf("unsubscribe = %+v, %v", s, err)
	}
}

func TestAddingTracksNotifiesSubscribers(t *testing.T) {
	pool := newTestPool(t)
	ctx := context.Background()
	users := NewUsers(pool)
	owner, _ := users.Create(ctx, "owner@example.com", "hash")
	member, _ := users.Create(ctx, "member@example.com", "hash")
	fan, _ := users.Create(ctx, "fan@example.com", "hash")
	tracks := NewTracks(pool)
	playlists := NewPlaylists(pool)
	notifications := NewNotifications(pool)
	newTrack := func(ownerID, title string) Track {
		track, err := tracks.Create(ctx, ownerID, NewTrack{Title: title, FileName: title + ".mp3", ContentType: "audio/mpeg", SizeBytes: 1})
		if err != nil {
			t.Fatal(err)
		}
		return track
	}
	first, second, third := newTrack(owner.ID, "first"), newTrack(owner.ID, "second"), newTrack(member.ID, "third")
	playlist, _ := playlists.Create(ctx, owner.ID, "channel")
	public := true
	playlists.Share(ctx, owner.ID, playlist.ID, "link-1", &public, true)
	playlists.SetCollabToken(ctx, owner.ID, playlist.ID, ptr("collab-1"))
	playlists.Join(ctx, member.ID, "collab-1")
	playlists.SetSubscription(ctx, fan.ID, "link-1", true)
	playlists.SetSubscription(ctx, member.ID, "link-1", true)

	inbox := func(userID string) ([]Notification, int) {
		t.Helper()
		list, unread, err := notifications.List(ctx, userID, 10)
		if err != nil {
			t.Fatal(err)
		}
		return list, unread
	}

	if err := playlists.ReplaceTracks(ctx, owner.ID, playlist.ID, []string{first.ID}); err != nil {
		t.Fatal(err)
	}
	list, unread := inbox(fan.ID)
	if unread != 1 || len(list) != 1 || list[0].TrackCount != 1 || *list[0].TrackTitle != "first" || list[0].ShareToken != "link-1" {
		t.Fatalf("fan inbox = %+v, %d unread", list, unread)
	}

	// More while it is unread update the same notice; the adder is skipped.
	if err := playlists.ReplaceTracks(ctx, member.ID, playlist.ID, []string{first.ID, third.ID}); err != nil {
		t.Fatal(err)
	}
	list, unread = inbox(fan.ID)
	if unread != 1 || len(list) != 1 || list[0].TrackCount != 2 || *list[0].TrackTitle != "third" {
		t.Fatalf("fan inbox after second add = %+v, %d unread", list, unread)
	}
	if list, _ := inbox(member.ID); len(list) != 1 || list[0].TrackCount != 1 {
		t.Fatalf("member was notified of their own track: %+v", list)
	}

	// Reordering and removing tell nobody.
	if err := playlists.ReplaceTracks(ctx, owner.ID, playlist.ID, []string{third.ID}); err != nil {
		t.Fatal(err)
	}
	if list, _ := inbox(fan.ID); list[0].TrackCount != 2 {
		t.Fatalf("removal changed the notice: %+v", list)
	}

	// Once read, the next addition is a new notice.
	if err := notifications.MarkRead(ctx, fan.ID, nil, "link-1"); err != nil {
		t.Fatal(err)
	}
	if _, unread := inbox(fan.ID); unread != 0 {
		t.Fatalf("unread after reading = %d", unread)
	}
	playlists.ReplaceTracks(ctx, owner.ID, playlist.ID, []string{third.ID, second.ID})
	list, unread = inbox(fan.ID)
	if unread != 1 || len(list) != 2 || list[0].TrackCount != 1 || list[0].ReadAt != nil || list[1].ReadAt == nil {
		t.Fatalf("inbox after reading and a new add = %+v, %d unread", list, unread)
	}

	// Someone else's IDs are ignored.
	notifications.MarkRead(ctx, owner.ID, []string{list[0].ID}, "")
	if _, unread := inbox(fan.ID); unread != 1 {
		t.Fatalf("another user marked the fan's notice read")
	}

	// Pushes: each change is pushed once.
	since := time.Now().Add(-time.Hour)
	pending, err := notifications.PendingPushes(ctx, since, 10)
	if err != nil || len(pending) != 2 {
		t.Fatalf("pending = %+v, %v", pending, err)
	}
	for _, n := range pending {
		notifications.MarkPushed(ctx, n.ID, n.UpdatedAt)
	}
	if pending, _ := notifications.PendingPushes(ctx, since, 10); len(pending) != 0 {
		t.Fatalf("pushed notices are still pending: %+v", pending)
	}

	// A playlist that stops being public hides its notices and notifies nobody.
	link := false
	playlists.Share(ctx, owner.ID, playlist.ID, "unused", &link, true)
	if list, unread := inbox(fan.ID); len(list) != 0 || unread != 0 {
		t.Fatalf("link-only playlist's notices are visible: %+v", list)
	}
	if listed, _ := playlists.Subscribed(ctx, fan.ID); len(listed) != 0 {
		t.Fatalf("link-only playlist is listed: %+v", listed)
	}
	playlists.ReplaceTracks(ctx, owner.ID, playlist.ID, []string{third.ID, second.ID, first.ID})
	playlists.Share(ctx, owner.ID, playlist.ID, "unused", &public, true)
	if list, _ := inbox(fan.ID); list[0].TrackCount != 1 {
		t.Fatalf("an addition while link-only notified: %+v", list)
	}

	// Unsubscribing clears the notices.
	playlists.SetSubscription(ctx, fan.ID, "link-1", false)
	if list, _ := inbox(fan.ID); len(list) != 0 {
		t.Fatalf("notices remain after unsubscribing: %+v", list)
	}
}
