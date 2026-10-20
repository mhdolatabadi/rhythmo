package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestDeleteAccountCascadesAndQueuesObjects(t *testing.T) {
	pool := newTestPool(t)
	ctx := context.Background()
	users := NewUsers(pool)
	tracks := NewTracks(pool)
	playlists := NewPlaylists(pool)

	gone, _ := users.Create(ctx, "gone@example.com", "hash")
	kept, _ := users.Create(ctx, "kept@example.com", "hash")
	add := func(userID, title string) Track {
		t.Helper()
		track, err := tracks.Create(ctx, userID, NewTrack{Title: title, FileName: title + ".mp3", ContentType: "audio/mpeg", SizeBytes: 1})
		if err != nil {
			t.Fatal(err)
		}
		return track
	}
	goneTrack := add(gone.ID, "gone-song")
	keptTrack := add(kept.ID, "kept-song")
	if _, err := tracks.ReservePending(ctx, gone.ID, NewTrack{Title: "p", FileName: "p.mp3", ContentType: "audio/mpeg", SizeBytes: 1}, 1<<30, 3); err != nil {
		t.Fatal(err)
	}

	// The deleted user's own playlist, shared and liked by the other user.
	goneList, _ := playlists.Create(ctx, gone.ID, "mine")
	if err := playlists.ReplaceTracks(ctx, gone.ID, goneList.ID, []string{goneTrack.ID}); err != nil {
		t.Fatal(err)
	}
	if _, err := playlists.Share(ctx, gone.ID, goneList.ID, "gone-share", nil, true); err != nil {
		t.Fatal(err)
	}
	if _, err := playlists.SetLike(ctx, kept.ID, "gone-share", true); err != nil {
		t.Fatal(err)
	}
	// The other user's collaborative playlist the deleted user joined, added
	// a track to, and liked.
	keptList, _ := playlists.Create(ctx, kept.ID, "together")
	collab := "kept-collab"
	if _, err := playlists.SetCollabToken(ctx, kept.ID, keptList.ID, &collab); err != nil {
		t.Fatal(err)
	}
	if _, err := playlists.Join(ctx, gone.ID, collab); err != nil {
		t.Fatal(err)
	}
	if err := playlists.ReplaceTracks(ctx, gone.ID, keptList.ID, []string{goneTrack.ID}); err != nil {
		t.Fatal(err)
	}
	if err := playlists.ReplaceTracks(ctx, kept.ID, keptList.ID, []string{goneTrack.ID, keptTrack.ID}); err != nil {
		t.Fatal(err)
	}
	if _, err := playlists.Share(ctx, kept.ID, keptList.ID, "kept-share", nil, true); err != nil {
		t.Fatal(err)
	}
	if _, err := playlists.SetLike(ctx, gone.ID, "kept-share", true); err != nil {
		t.Fatal(err)
	}
	// Bot link, link code, an import and a messenger file ID.
	for _, statement := range []string{
		`INSERT INTO bot_chats (provider, chat_id, user_id, linked_at) VALUES ('bale', 'c1', $1::uuid, now())`,
		`INSERT INTO bot_link_codes (code_hash, user_id, expires_at) VALUES ('\x01', $1::uuid, now() + interval '1 hour')`,
		`INSERT INTO bot_imports (provider, chat_id, message_id, user_id, file_id, file_name, size_bytes) VALUES ('bale', 'c1', 'm1', $1::uuid, 'f', 'a.mp3', 1)`,
	} {
		if _, err := pool.Exec(ctx, statement, gone.ID); err != nil {
			t.Fatal(err)
		}
	}
	if err := (&Bots{pool: pool}).SaveTrackFileID(ctx, "bale", goneTrack.ID, "file"); err != nil {
		t.Fatal(err)
	}

	deletion, err := users.Delete(ctx, gone.ID, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if deletion.UserID != gone.ID || deletion.ObjectPrefix != "users/"+gone.ID+"/" ||
		deletion.ObjectPrefix != UserObjectPrefix(gone.ID) || !deletion.PurgeAfter.After(deletion.DeletedAt.Add(59*time.Minute)) {
		t.Fatalf("deletion = %+v", deletion)
	}

	for table, column := range map[string]string{
		"users": "id", "tracks": "owner_id", "playlists": "owner_id", "playlist_members": "user_id",
		"playlist_likes": "user_id", "bot_chats": "user_id", "bot_link_codes": "user_id", "bot_imports": "user_id",
	} {
		var count int
		if err := pool.QueryRow(ctx, `SELECT count(*) FROM `+table+` WHERE `+column+`::text = $1`, gone.ID).Scan(&count); err != nil {
			t.Fatal(err)
		}
		if count != 0 {
			t.Errorf("%d rows of %s still belong to the deleted user", count, table)
		}
	}
	var leftovers int
	if err := pool.QueryRow(ctx, `
		SELECT (SELECT count(*) FROM playlist_tracks WHERE track_id::text = $1)
		     + (SELECT count(*) FROM playlist_likes WHERE playlist_id::text = $2)
		     + (SELECT count(*) FROM bot_track_files WHERE track_id::text = $1)`,
		goneTrack.ID, goneList.ID).Scan(&leftovers); err != nil {
		t.Fatal(err)
	}
	if leftovers != 0 {
		t.Fatalf("%d playlist entries, likes or file IDs outlived the account", leftovers)
	}

	// The other user keeps their account, playlist and own track in it.
	if _, err := users.ByID(ctx, kept.ID); err != nil {
		t.Fatal(err)
	}
	remaining, err := playlists.ForUser(ctx, kept.ID, keptList.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(remaining.Tracks) != 1 || remaining.Tracks[0].ID != keptTrack.ID {
		t.Fatalf("kept playlist tracks = %+v", remaining.Tracks)
	}

	// The account can't sign in, and deleting it again finds nothing.
	if _, _, err := users.ByEmail(ctx, "gone@example.com"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("ByEmail after delete: %v", err)
	}
	if _, err := users.Delete(ctx, gone.ID, time.Hour); !errors.Is(err, ErrNotFound) {
		t.Fatalf("second delete: %v", err)
	}
	if _, err := users.Delete(ctx, "not-a-uuid", time.Hour); !errors.Is(err, ErrNotFound) {
		t.Fatalf("malformed ID: %v", err)
	}
	// The address is free to register again, as a new account.
	again, err := users.Create(ctx, "gone@example.com", "hash")
	if err != nil || again.ID == gone.ID {
		t.Fatalf("re-register = %+v, %v", again, err)
	}
}

func TestAccountPurgeQueue(t *testing.T) {
	pool := newTestPool(t)
	ctx := context.Background()
	users := NewUsers(pool)
	waiting, _ := users.Create(ctx, "waiting@example.com", "hash")
	ready, _ := users.Create(ctx, "ready@example.com", "hash")
	if _, err := users.Delete(ctx, waiting.ID, time.Hour); err != nil {
		t.Fatal(err)
	}
	if _, err := users.Delete(ctx, ready.ID, 0); err != nil {
		t.Fatal(err)
	}

	pending, err := users.PendingAccountPurges(ctx, 10)
	if err != nil || len(pending) != 2 || pending[0].UserID != waiting.ID || pending[1].UserID != ready.ID {
		t.Fatalf("pending = %+v, %v", pending, err)
	}
	if limited, _ := users.PendingAccountPurges(ctx, 1); len(limited) != 1 {
		t.Fatalf("limit ignored: %+v", limited)
	}

	// Uploads handed out before the deletion may still arrive.
	if purged, err := users.MarkAccountPurged(ctx, waiting.ID); err != nil || purged {
		t.Fatalf("purged inside the grace period: %v %v", purged, err)
	}
	if purged, err := users.MarkAccountPurged(ctx, ready.ID); err != nil || !purged {
		t.Fatalf("not purged after the grace period: %v %v", purged, err)
	}
	if purged, _ := users.MarkAccountPurged(ctx, ready.ID); purged {
		t.Fatal("purged twice")
	}
	pending, _ = users.PendingAccountPurges(ctx, 10)
	if len(pending) != 1 || pending[0].UserID != waiting.ID {
		t.Fatalf("pending after purge = %+v", pending)
	}
	// The audit row stays.
	var rows int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM account_deletions`).Scan(&rows); err != nil || rows != 2 {
		t.Fatalf("audit rows = %d, %v", rows, err)
	}
}
