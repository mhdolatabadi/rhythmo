package store

import (
	"context"
	"errors"
	"testing"
)

func TestBaleTopicIdentityOrderingRetryAndPrivacy(t *testing.T) {
	ctx := context.Background()
	pool := newTestPool(t)
	b := NewBaleImports(pool)
	tracks := NewTracks(pool)
	owner, _ := NewUsers(pool).Create(ctx, "admin@example.com", "hash")
	lecture := func(id, topic string, n int) BaleLecture {
		return BaleLecture{MessageID: id, FileName: "lecture.mp3", Title: topic, Topic: topic, TopicKey: topic, Date: int64(n) * 1000, Session: n, SourceURL: "https://ble.ir/kashani1395/" + id, DurationMS: 10000}
	}
	first, err := b.QueueBale(ctx, owner.ID, lecture("13", "مهدویت", 13), 5)
	if err != nil {
		t.Fatal(err)
	}
	duplicate, err := b.QueueBale(ctx, owner.ID, lecture("13", "مهدویت", 13), 5)
	if err != nil || duplicate.ID != first.ID {
		t.Fatalf("duplicate %+v %v", duplicate, err)
	}
	second, err := b.QueueBale(ctx, owner.ID, lecture("2", "مهدویت", 2), 5)
	if err != nil {
		t.Fatal(err)
	}
	other, err := b.QueueBale(ctx, owner.ID, lecture("1", "فاطمیه", 1), 5)
	if err != nil {
		t.Fatal(err)
	}
	if *first.PlaylistID != *second.PlaylistID || *first.PlaylistID == *other.PlaylistID {
		t.Fatal("wrong topic grouping")
	}
	if _, err := b.QueueBale(ctx, owner.ID, lecture("3", "مهدویت", 3), 3); !errors.Is(err, ErrArchiveBusy) {
		t.Fatalf("queue limit %v", err)
	}
	var ids []string
	for _, job := range []BotImport{first, second} {
		tr, err := tracks.Create(ctx, owner.ID, NewTrack{Title: "lecture", FileName: "lecture.mp3", ContentType: "audio/mpeg", SizeBytes: 100})
		if err != nil {
			t.Fatal(err)
		}
		if err = b.FinishImport(ctx, job.ID, &tr.ID, nil); err != nil {
			t.Fatal(err)
		}
		ids = append(ids, tr.ID)
	}
	// Finishing twice cannot duplicate playlist entries or alter ordering.
	if err = b.FinishImport(ctx, first.ID, &ids[0], nil); err != nil {
		t.Fatal(err)
	}
	rows, err := pool.Query(ctx, `SELECT track_id::text FROM playlist_tracks WHERE playlist_id::text=$1 ORDER BY position`, *first.PlaylistID)
	if err != nil {
		t.Fatal(err)
	}
	var ordered []string
	for rows.Next() {
		var id string
		rows.Scan(&id)
		ordered = append(ordered, id)
	}
	rows.Close()
	if len(ordered) != 2 || ordered[0] != ids[1] || ordered[1] != ids[0] {
		t.Fatalf("order %v", ordered)
	}
	tr, err := tracks.ForOwner(ctx, owner.ID, ids[0])
	if err != nil || tr.Album == nil || *tr.Album != "مهدویت" || tr.Comment == nil || *tr.Comment != "https://ble.ir/kashani1395/13" {
		t.Fatalf("metadata %+v %v", tr, err)
	}
	var public bool
	var token *string
	if err = pool.QueryRow(ctx, `SELECT is_public,share_token FROM playlists WHERE id::text=$1`, *first.PlaylistID).Scan(&public, &token); err != nil || public || token != nil {
		t.Fatal("archive published without owner action", err)
	}
	reason := "quota_exceeded"
	if err = b.FinishImport(ctx, other.ID, nil, &reason); err != nil {
		t.Fatal(err)
	}
	retried, err := b.QueueBale(ctx, owner.ID, lecture("1", "فاطمیه", 1), 5)
	if err != nil || retried.ID != other.ID || retried.State != ImportQueued {
		t.Fatalf("retry %+v %v", retried, err)
	}
	done, err := b.QueueBale(ctx, owner.ID, lecture("13", "مهدویت", 13), 5)
	if err != nil || done.TrackID == nil || *done.TrackID != ids[0] {
		t.Fatalf("done duplicate %+v %v", done, err)
	}
}
