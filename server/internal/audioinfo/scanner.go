package audioinfo

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"time"

	"github.com/mhdolatabadi/rhythmo/server/internal/storage"
	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

// Store is the queue of tracks to read; *store.Tracks implements it.
type Store interface {
	PendingAudioInfo(ctx context.Context, limit int) ([]store.AudioInfoJob, error)
	SetAudioInfo(ctx context.Context, trackID, storageKey string, info store.AudioInfo, durationMS *int32) error
}

// Objects reads stored files by range; *storage.Storage implements it.
type Objects interface {
	ReadRange(ctx context.Context, key string, offset, size int64) ([]byte, error)
}

// Scanner reads the format of new uploads and, the first time it runs, of
// every track uploaded before it existed.
type Scanner struct {
	store    Store
	objects  Objects
	interval time.Duration
	batch    int
	timeout  time.Duration
}

func NewScanner(s Store, objects Objects, interval time.Duration, batch int) *Scanner {
	return &Scanner{store: s, objects: objects, interval: interval, batch: batch, timeout: 30 * time.Second}
}

// Run scans until ctx ends.
func (s *Scanner) Run(ctx context.Context) {
	ticker := time.NewTicker(s.interval)
	defer ticker.Stop()
	for {
		for {
			scanned, err := s.ScanOnce(ctx)
			if err != nil {
				slog.Warn("audio format scan failed", "error", err)
				break
			}
			if scanned < s.batch {
				break
			}
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

// ScanOnce reads one batch and returns how many tracks it settled. A file
// that can't be read for now is left for a later batch; an unrecognised
// one is settled with an unknown format.
func (s *Scanner) ScanOnce(ctx context.Context) (int, error) {
	jobs, err := s.store.PendingAudioInfo(ctx, s.batch)
	if err != nil {
		return 0, err
	}
	settled := 0
	for _, job := range jobs {
		if ctx.Err() != nil {
			return settled, ctx.Err()
		}
		info, err := s.read(ctx, job)
		if err != nil {
			slog.Warn("audio format: track left for later", "track", job.ID, "error", err)
			continue
		}
		stored, duration := ToStore(info)
		err = s.store.SetAudioInfo(ctx, job.ID, job.StorageKey, stored, duration)
		if err != nil && !errors.Is(err, store.ErrNotFound) {
			return settled, err
		}
		settled++
	}
	return settled, nil
}

func (s *Scanner) read(ctx context.Context, job store.AudioInfoJob) (Info, error) {
	ctx, cancel := context.WithTimeout(ctx, s.timeout)
	defer cancel()
	r := &rangeReader{ctx: ctx, objects: s.objects, key: job.StorageKey, size: job.SizeBytes}
	info, err := Probe(r, job.SizeBytes, job.FileName)
	switch {
	case errors.Is(err, storage.ErrObjectMissing), errors.Is(err, ErrUnknown):
		if r.err != nil && !errors.Is(r.err, storage.ErrObjectMissing) {
			return Info{}, r.err
		}
		return Info{}, nil
	case err != nil:
		return Info{}, err
	}
	if r.err != nil {
		return Info{}, r.err
	}
	return info, nil
}

// ToStore turns info into stored columns and a length in milliseconds.
func ToStore(info Info) (store.AudioInfo, *int32) {
	var out store.AudioInfo
	if info.Codec != "" {
		out.Codec = &info.Codec
	}
	positive := func(v int) *int32 {
		if v <= 0 || v > 1<<30 {
			return nil
		}
		n := int32(v)
		return &n
	}
	out.BitrateKbps = positive(info.BitrateKbps)
	out.SampleRate = positive(info.SampleRate)
	out.BitDepth = positive(info.BitDepth)
	var duration *int32
	if ms := info.Duration.Milliseconds(); ms > 0 && ms < 1<<31-1 {
		d := int32(ms)
		duration = &d
	}
	return out, duration
}

// rangeReader reads a stored object by ranges, remembering the first
// storage error so a passing outage is not taken for an unknown format.
type rangeReader struct {
	ctx     context.Context
	objects Objects
	key     string
	size    int64
	err     error
}

func (r *rangeReader) ReadAt(p []byte, offset int64) (int, error) {
	if offset < 0 || offset >= r.size || len(p) == 0 {
		return 0, io.EOF
	}
	n := min(int64(len(p)), r.size-offset)
	data, err := r.objects.ReadRange(r.ctx, r.key, offset, n)
	if err != nil {
		if r.err == nil {
			r.err = err
		}
		return 0, err
	}
	copied := copy(p, data)
	if copied < len(p) {
		return copied, io.EOF
	}
	return copied, nil
}
