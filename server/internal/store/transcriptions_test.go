package store

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/mhdolatabadi/rhythmo/server/internal/transcription"
)

func TestTranscriptionQueue(t *testing.T) {
	pool := newTestPool(t)
	ctx := context.Background()
	users := NewUsers(pool)
	tracks := NewTracks(pool)
	jobs := NewTranscriptions(pool)
	alice, _ := users.Create(ctx, "alice@example.com", "hash")
	bob, _ := users.Create(ctx, "bob@example.com", "hash")
	makeTrack := func() Track {
		t.Helper()
		r, err := tracks.Create(ctx, alice.ID, NewTrack{Title: "مداحی", FileName: "a.mp3", ContentType: "audio/mpeg", SizeBytes: 5})
		if err != nil {
			t.Fatal(err)
		}
		return r
	}
	first, second, third := makeTrack(), makeTrack(), makeTrack()
	if err := jobs.Queue(ctx, bob.ID, first.ID); err != nil {
		t.Fatal(err)
	}
	if r, _ := jobs.Status(ctx, first.ID); r.State != "idle" {
		t.Fatal("another owner queued track")
	}
	for _, id := range []string{first.ID, first.ID, second.ID} {
		if err := jobs.Queue(ctx, alice.ID, id); err != nil {
			t.Fatal(err)
		}
	}
	health, err := jobs.QueueHealth(ctx)
	if err != nil || health.Queued != 2 || health.Processing != 0 || health.Failed != 0 {
		t.Fatalf("queued health = %+v err %v", health, err)
	}
	if err := jobs.Queue(ctx, alice.ID, third.ID); !errors.Is(err, transcription.ErrBusy) {
		t.Fatalf("limit: %v", err)
	}
	j, ok, err := jobs.Claim(ctx, time.Hour)
	if err != nil || !ok {
		t.Fatalf("claim: %v", err)
	}
	health, err = jobs.QueueHealth(ctx)
	if err != nil || health.Queued != 1 || health.Processing != 1 ||
		health.OldestPendingSeconds < 0 {
		t.Fatalf("processing health = %+v err %v", health, err)
	}
	late := j
	late.Lease = late.Lease.Add(-time.Second)
	if err := jobs.Finish(ctx, late, transcription.Result{State: "done", Plain: "wrong"}); err != nil {
		t.Fatal(err)
	}
	if r, _ := jobs.Status(ctx, j.ID); r.State != "processing" {
		t.Fatal("stale lease saved")
	}
	if err := jobs.Finish(ctx, j, transcription.Result{State: "failed"}); err != nil {
		t.Fatal(err)
	}
	if err := jobs.Queue(ctx, alice.ID, j.ID); err != nil {
		t.Fatal(err)
	}
	j, ok, err = jobs.Claim(ctx, time.Hour)
	if err != nil || !ok {
		t.Fatal(err)
	}
	if err := tracks.Delete(ctx, alice.ID, j.ID); err != nil {
		t.Fatal(err)
	}
	if err := jobs.Finish(ctx, j, transcription.Result{State: "done", Plain: "یا حسین"}); err != nil {
		t.Fatal(err)
	}
	if r, _ := jobs.Status(ctx, j.ID); r.State != "idle" {
		t.Fatal("deleted track resurrected")
	}
}
