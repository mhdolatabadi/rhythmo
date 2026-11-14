package store

import (
	"context"
	"errors"
	"testing"
)

func TestAudioInfoQueue(t *testing.T) {
	ctx := context.Background()
	pool := newTestPool(t)
	users := NewUsers(pool)
	tracks := NewTracks(pool)
	owner, err := users.Create(ctx, "format@example.com", "hash")
	if err != nil {
		t.Fatal(err)
	}
	ready, err := tracks.Create(ctx, owner.ID, NewTrack{Title: "a", FileName: "a.flac", ContentType: "audio/flac", SizeBytes: 9})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := tracks.ReservePending(ctx, owner.ID, NewTrack{Title: "p", FileName: "p.mp3", ContentType: "audio/mpeg", SizeBytes: 1}, 1<<30, 5); err != nil {
		t.Fatal(err)
	}

	jobs, err := tracks.PendingAudioInfo(ctx, 10)
	if err != nil || len(jobs) != 1 || jobs[0].ID != ready.ID || jobs[0].SizeBytes != 9 || jobs[0].FileName != "a.flac" {
		t.Fatalf("PendingAudioInfo = %+v, %v; only the ready track waits", jobs, err)
	}
	if err := tracks.SetAudioInfo(ctx, ready.ID, "users/other/key", AudioInfo{}, nil); !errors.Is(err, ErrNotFound) {
		t.Fatalf("SetAudioInfo for a changed object = %v", err)
	}
	codec, rate, depth := "FLAC", int32(44100), int32(16)
	length := int32(201000)
	if err := tracks.SetAudioInfo(ctx, ready.ID, ready.StorageKey,
		AudioInfo{Codec: &codec, SampleRate: &rate, BitDepth: &depth}, &length); err != nil {
		t.Fatal(err)
	}
	if jobs, _ := tracks.PendingAudioInfo(ctx, 10); len(jobs) != 0 {
		t.Fatalf("scanned track still queued: %+v", jobs)
	}
	got, err := tracks.ForOwner(ctx, owner.ID, ready.ID)
	if err != nil {
		t.Fatal(err)
	}
	a := got.Audio
	if a.Codec == nil || *a.Codec != "FLAC" || *a.SampleRate != 44100 || *a.BitDepth != 16 || a.BitrateKbps != nil {
		t.Fatalf("stored format = %+v", a)
	}
	if got.DurationMS == nil || *got.DurationMS != length {
		t.Fatalf("length = %v, want it filled in", got.DurationMS)
	}
}
