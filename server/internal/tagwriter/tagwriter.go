// Package tagwriter rewrites the tags embedded in stored audio after a
// metadata edit. Each job streams the current object to a temporary file,
// rewrites its tags without touching the audio, verifies the result, uploads
// it under a new key and only then swaps the track over to it in one database
// transaction. Until that commit the old object stays the one that is played.
package tagwriter

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path"
	"time"

	"github.com/mhdolatabadi/rhythmo/server/internal/audio"
	"github.com/mhdolatabadi/rhythmo/server/internal/store"
	"github.com/mhdolatabadi/rhythmo/server/internal/tags"
)

// Store is the job queue; *store.Tracks implements it.
type Store interface {
	ClaimTagRewrite(ctx context.Context, lease time.Duration, maxAttempts int) (store.Track, bool, error)
	RecordPendingObject(ctx context.Context, track store.Track, key string) error
	ReleaseTagRewrite(ctx context.Context, trackID string) error
	CompleteTagRewrite(ctx context.Context, track store.Track, newKey string, newSize int64, maxOwnerBytes int64, grace time.Duration) error
	FailTagRewrite(ctx context.Context, track store.Track, failure store.TagFailure) error
	CollectGarbage(ctx context.Context, limit int, remove func(context.Context, string) error) (int, error)
}

// CoverStore gives the cover the owner chose for a track, nil when none;
// *store.Tracks implements it. A Store that also implements it gets that
// cover embedded, so downloads carry it.
type CoverStore interface {
	TrackCover(ctx context.Context, trackID string) ([]byte, error)
}

// Objects is the object storage; *storage.Storage implements it.
type Objects interface {
	Open(ctx context.Context, key string) (io.ReadCloser, error)
	Put(ctx context.Context, key string, r io.Reader, size int64, contentType string) error
	Size(ctx context.Context, key string) (int64, error)
	Remove(ctx context.Context, key string) error
}

type Config struct {
	// Workers is how many rewrites run at once; each needs up to twice the
	// file size in TempDir.
	Workers int
	TempDir string
	// Lease is how long a claimed job is reserved; a job takes at most a
	// little less, so a crashed worker's job is picked up after it.
	Lease       time.Duration
	MaxAttempts int
	// RetryDelay is multiplied by the attempt number between attempts.
	RetryDelay time.Duration
	// Grace keeps a replaced object readable this long, so playback that
	// already has a presigned URL for it can finish.
	Grace         time.Duration
	PollEvery     time.Duration
	MaxOwnerBytes int64
	GarbageBatch  int
}

func (c Config) withDefaults() Config {
	if c.Workers <= 0 {
		c.Workers = 1
	}
	if c.Lease <= 0 {
		c.Lease = 30 * time.Minute
	}
	if c.MaxAttempts <= 0 {
		c.MaxAttempts = 3
	}
	if c.RetryDelay <= 0 {
		c.RetryDelay = time.Minute
	}
	if c.PollEvery <= 0 {
		c.PollEvery = 30 * time.Second
	}
	if c.GarbageBatch <= 0 {
		c.GarbageBatch = 100
	}
	return c
}

type Writer struct {
	store   Store
	objects Objects
	config  Config
	wake    chan struct{}
}

func New(s Store, objects Objects, config Config) *Writer {
	config = config.withDefaults()
	return &Writer{store: s, objects: objects, config: config, wake: make(chan struct{}, config.Workers)}
}

// Notify starts a waiting worker now instead of at its next poll.
func (w *Writer) Notify() {
	select {
	case w.wake <- struct{}{}:
	default:
	}
}

// Run works through the queue until ctx is done.
func (w *Writer) Run(ctx context.Context) {
	done := make(chan struct{})
	for range w.config.Workers {
		go func() {
			defer func() { done <- struct{}{} }()
			w.work(ctx)
		}()
	}
	ticker := time.NewTicker(w.config.PollEvery)
	defer ticker.Stop()
	for {
		w.collectGarbage(ctx)
		select {
		case <-ctx.Done():
			for range w.config.Workers {
				<-done
			}
			return
		case <-ticker.C:
		}
	}
}

func (w *Writer) work(ctx context.Context) {
	ticker := time.NewTicker(w.config.PollEvery)
	defer ticker.Stop()
	for {
		for {
			worked, err := w.RunOnce(ctx)
			if err != nil && ctx.Err() == nil {
				slog.Error("tag rewrite queue failed", "error", err)
			}
			if !worked || ctx.Err() != nil {
				break
			}
		}
		select {
		case <-ctx.Done():
			return
		case <-w.wake:
		case <-ticker.C:
		}
	}
}

func (w *Writer) collectGarbage(ctx context.Context) {
	removed, err := w.store.CollectGarbage(ctx, w.config.GarbageBatch, w.objects.Remove)
	if err != nil && ctx.Err() == nil {
		slog.Error("storage garbage collection failed", "error", err)
	}
	if removed > 0 {
		slog.Info("storage garbage collected", "removed", removed)
	}
}

// RunOnce claims and processes one job. It reports whether there was one.
func (w *Writer) RunOnce(ctx context.Context) (bool, error) {
	track, ok, err := w.store.ClaimTagRewrite(ctx, w.config.Lease, w.config.MaxAttempts)
	if err != nil || !ok {
		return false, err
	}
	jobCtx, cancel := context.WithTimeout(ctx, w.config.Lease*9/10)
	defer cancel()
	failure := w.process(jobCtx, track)
	// Record the outcome even if the job ran out of time.
	record := context.WithoutCancel(ctx)
	switch {
	case failure == nil:
		return true, nil
	case failure.superseded:
		return true, w.store.ReleaseTagRewrite(record, track.ID)
	default:
		if failure.Code != "" {
			slog.Warn("tag rewrite failed", "track", track.ID, "code", failure.Code, "error", failure.err)
		}
		if failure.RetryAfter > 0 {
			failure.RetryAfter = w.config.RetryDelay * time.Duration(track.TagAttempts)
			if int(track.TagAttempts) >= w.config.MaxAttempts {
				failure.RetryAfter = 0
			}
		}
		return true, w.store.FailTagRewrite(record, track, failure.TagFailure)
	}
}

type jobFailure struct {
	store.TagFailure
	err error
	// superseded means a newer edit replaced the claimed one.
	superseded bool
}

func retry(code string, err error, uploaded string) *jobFailure {
	return &jobFailure{TagFailure: store.TagFailure{Code: code, RetryAfter: 1, UploadedKey: uploaded}, err: err}
}

func final(code string, err error) *jobFailure {
	return &jobFailure{TagFailure: store.TagFailure{Code: code}, err: err}
}

// Metadata is the embedded metadata a track's edited fields describe.
func Metadata(t store.Track) tags.Metadata {
	text := func(s *string) string {
		if s == nil {
			return ""
		}
		return *s
	}
	number := func(n *int32) int {
		if n == nil {
			return 0
		}
		return int(*n)
	}
	return tags.Metadata{
		Title: t.Title, Artist: text(t.Artist), Album: text(t.Album), AlbumArtist: text(t.AlbumArtist),
		Composer: text(t.Composer), Genre: text(t.Genre), Comment: text(t.Comment),
		Year: number(t.Year), TrackNumber: number(t.TrackNumber), DiscNumber: number(t.DiscNumber),
	}
}

// RevisionKey is where the object rewritten for a track's metadata version
// is stored: under the track's own prefix, so it stays owner-scoped and
// account deletion removes it, with a fresh name per attempt so a retry
// never overwrites an object an earlier attempt may still reference.
func RevisionKey(t store.Track) string {
	return fmt.Sprintf("users/%s/tracks/%s/v%d-%d/%s",
		t.OwnerID, t.ID, t.MetadataVersion, t.TagAttempts, audio.SafeFileName(t.FileName))
}

func (w *Writer) process(ctx context.Context, track store.Track) *jobFailure {
	if !tags.Supported(track.FileName) {
		return &jobFailure{TagFailure: store.TagFailure{Code: "unsupported_format", Unsupported: true}}
	}
	desired := Metadata(track)
	var cover []byte
	if covers, ok := w.store.(CoverStore); ok {
		var err error
		if cover, err = covers.TrackCover(ctx, track.ID); err != nil {
			return retry("cover_failed", err, "")
		}
	}

	source, err := w.download(ctx, track)
	if err != nil {
		return retry("download_failed", err, "")
	}
	defer removeTemp(source)

	before, err := tags.Inspect(bufio.NewReader(source), track.FileName)
	switch {
	case errors.Is(err, tags.ErrUnsupported):
		return &jobFailure{TagFailure: store.TagFailure{Code: "unsupported_layout", Unsupported: true}, err: err}
	case errors.Is(err, tags.ErrMalformed):
		return final("malformed_audio", err)
	case err != nil:
		return retry("read_failed", err, "")
	}

	rewritten, err := w.temp()
	if err != nil {
		return retry("temp_failed", err, "")
	}
	defer removeTemp(rewritten)
	if _, err := source.Seek(0, io.SeekStart); err != nil {
		return retry("read_failed", err, "")
	}
	buffered := bufio.NewWriter(rewritten)
	if _, err := tags.RewriteWithCover(buffered, bufio.NewReader(source), track.FileName, desired, cover); err != nil {
		if errors.Is(err, tags.ErrUnsupported) {
			return &jobFailure{TagFailure: store.TagFailure{Code: "unsupported_layout", Unsupported: true}, err: err}
		}
		return retry("rewrite_failed", err, "")
	}
	if err := buffered.Flush(); err != nil {
		return retry("rewrite_failed", err, "")
	}
	size, err := w.verify(rewritten, track, before, desired, cover)
	if err != nil {
		return final("verification_failed", err)
	}

	key := RevisionKey(track)
	if err := w.store.RecordPendingObject(ctx, track, key); errors.Is(err, store.ErrVersionConflict) {
		return &jobFailure{superseded: true}
	} else if err != nil {
		return retry("record_failed", err, "")
	}
	if _, err := rewritten.Seek(0, io.SeekStart); err != nil {
		return retry("upload_failed", err, key)
	}
	if err := w.objects.Put(ctx, key, rewritten, size, track.ContentType); err != nil {
		return retry("upload_failed", err, key)
	}
	if stored, err := w.objects.Size(ctx, key); err != nil || stored != size {
		return retry("upload_unverified", fmt.Errorf("stored %d bytes of %d: %v", stored, size, err), key)
	}
	err = w.store.CompleteTagRewrite(context.WithoutCancel(ctx), track, key, size, w.config.MaxOwnerBytes, w.config.Grace)
	switch {
	case err == nil, errors.Is(err, store.ErrQuotaExceeded):
		// Done; an over-quota result is already marked failed and cleaned up.
		return nil
	case errors.Is(err, store.ErrNotFound), errors.Is(err, store.ErrVersionConflict):
		return &jobFailure{superseded: true}
	default:
		// The swap may or may not have committed. Garbage collection never
		// deletes a key a track still uses, so queueing it is safe either way.
		return retry("swap_failed", err, key)
	}
}

// download copies the track's object to a temporary file, refusing anything
// but exactly the recorded size.
func (w *Writer) download(ctx context.Context, track store.Track) (*os.File, error) {
	object, err := w.objects.Open(ctx, track.StorageKey)
	if err != nil {
		return nil, err
	}
	defer object.Close()
	file, err := w.temp()
	if err != nil {
		return nil, err
	}
	n, err := io.Copy(file, io.LimitReader(object, track.SizeBytes+1))
	if err == nil && n != track.SizeBytes {
		err = fmt.Errorf("object has %d bytes, expected %d", n, track.SizeBytes)
	}
	if err == nil {
		_, err = file.Seek(0, io.SeekStart)
	}
	if err != nil {
		removeTemp(file)
		return nil, err
	}
	return file, nil
}

// verify re-reads the rewritten file from disk: it must still look like its
// format, carry exactly the desired tags, and hold byte-identical audio.
func (w *Writer) verify(file *os.File, track store.Track, before tags.Info, desired tags.Metadata, cover []byte) (int64, error) {
	info, err := file.Stat()
	if err != nil {
		return 0, err
	}
	header := make([]byte, audio.HeaderBytes)
	if _, err := file.ReadAt(header, 0); err != nil || !audio.Matches(track.FileName, header) {
		return 0, fmt.Errorf("rewritten file does not look like %s", path.Ext(track.FileName))
	}
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		return 0, err
	}
	after, err := tags.Inspect(bufio.NewReader(file), track.FileName)
	if err != nil {
		return 0, fmt.Errorf("rewritten file does not parse: %w", err)
	}
	if after.Metadata != desired {
		return 0, errors.New("rewritten tags do not match the metadata")
	}
	if after.PayloadSHA256 != before.PayloadSHA256 || after.PayloadBytes != before.PayloadBytes {
		return 0, errors.New("rewriting changed the audio")
	}
	if cover != nil {
		embedded, err := tags.Cover(file, info.Size())
		if err != nil || !bytes.Equal(embedded, cover) {
			return 0, fmt.Errorf("rewritten file does not carry the chosen cover: %v", err)
		}
	}
	return info.Size(), nil
}

func (w *Writer) temp() (*os.File, error) {
	return os.CreateTemp(w.config.TempDir, "rhythmo-retag-*")
}

func removeTemp(file *os.File) {
	name := file.Name()
	_ = file.Close()
	_ = os.Remove(name)
}
