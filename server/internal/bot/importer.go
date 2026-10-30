package bot

import (
	"bytes"
	"context"
	"errors"
	"io"
	"log/slog"
	"path"
	"strings"
	"time"

	"github.com/mhdolatabadi/rhythmo/server/internal/audio"
	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

// Import failure reasons. They are stored with the import and chosen so the
// chat can be told exactly what went wrong.
const (
	ReasonUnsupported = "unsupported_format"
	ReasonTooLarge    = "too_large"
	ReasonQuota       = "quota_exceeded"
	ReasonPending     = "too_many_pending_uploads"
	ReasonDisabled    = "uploads_disabled"
	ReasonInvalid     = "invalid_audio"
	ReasonFailed      = "import_failed"
)

type ImportStore interface {
	AddImport(ctx context.Context, i store.BotImport) (store.BotImport, error)
	StartImport(ctx context.Context, id string, staleBefore time.Time) (store.BotImport, bool, error)
	FinishImport(ctx context.Context, id string, trackID, reason *string) error
	RequeueImport(ctx context.Context, id string) error
	UnfinishedImports(ctx context.Context, limit int) ([]store.BotImport, error)
}

type TrackStore interface {
	ReservePending(ctx context.Context, ownerID string, track store.NewTrack, maxOwnerBytes int64, maxPending int) (store.Track, error)
	MarkReady(ctx context.Context, ownerID, trackID string) (store.Track, error)
	Delete(ctx context.Context, ownerID, trackID string) error
}

type ObjectStore interface {
	Put(ctx context.Context, key string, r io.Reader, size int64, contentType string) error
	Remove(ctx context.Context, key string) error
}

// UploadPolicy is the same policy direct uploads enforce.
type UploadPolicy struct {
	Enabled       bool
	MaxFileBytes  int64
	MaxOwnerBytes int64
	MaxPending    int
}

// Importer turns a messenger file into a ready track: it reserves the track
// under the owner's quota, streams the download straight into storage,
// checks the bytes really are the claimed audio format, then marks it ready.
// Anything that fails after the reservation removes the track and object.
type Importer struct {
	imports     ImportStore
	tracks      TrackStore
	objects     ObjectStore
	policy      UploadPolicy
	maxAttempts int
	retryDelay  time.Duration
	// staleAfter is how long a download may run before it counts as
	// interrupted and may be claimed again.
	staleAfter time.Duration
	now        func() time.Time
}

func NewImporter(imports ImportStore, tracks TrackStore, objects ObjectStore, policy UploadPolicy) *Importer {
	return &Importer{
		imports: imports, tracks: tracks, objects: objects, policy: policy,
		maxAttempts: 3, retryDelay: 30 * time.Second, staleAfter: 30 * time.Minute, now: time.Now,
	}
}

// Check applies the upload policy to what the message declares, before any
// download. It returns a failure reason, or "" if the file may be imported.
func (im *Importer) Check(p Provider, f File) string {
	if _, ok := audio.ContentType(FileName(f)); !ok {
		return ReasonUnsupported
	}
	if !im.policy.Enabled {
		return ReasonDisabled
	}
	if f.SizeBytes > im.policy.MaxFileBytes || f.SizeBytes > p.MaxDownloadBytes() {
		return ReasonTooLarge
	}
	return ""
}

// Queue records the import; ErrDuplicateImport means the message was already
// queued by an earlier delivery. A post in a synced channel names the
// playlist the track then joins.
func (im *Importer) Queue(ctx context.Context, p Provider, u Update, userID string, playlistID *string) (store.BotImport, error) {
	f := u.File
	return im.imports.AddImport(ctx, store.BotImport{
		Provider: p.Name(), ChatID: u.ChatID, MessageID: u.MessageID, UserID: userID,
		FileID: f.ID, FileName: FileName(*f), Title: nonEmpty(f.Title), Artist: nonEmpty(f.Performer),
		SizeBytes: f.SizeBytes, PlaylistID: playlistID,
	})
}

// Result is a finished import.
type Result struct {
	Import store.BotImport
	Track  *store.Track
	Reason string
}

// Run imports one queued file, retrying passing failures a bounded number of
// times. ok is false when another worker already has the import. interrupted
// marks an import found unfinished at startup: nothing in this process is
// working on it, so it is reclaimed even if it looks recently active.
func (im *Importer) Run(ctx context.Context, p Provider, id string, interrupted bool) (Result, bool) {
	staleBefore := im.now().Add(-im.staleAfter)
	if interrupted {
		staleBefore = im.now()
	}
	for {
		job, claimed, err := im.imports.StartImport(ctx, id, staleBefore)
		if err != nil {
			slog.Error("claim bot import", "provider", p.Name(), "import", id, "error", err)
			return Result{}, false
		}
		if !claimed {
			return Result{}, false
		}
		track, reason, err := im.importOnce(ctx, p, job)
		if err != nil && job.Attempts < im.maxAttempts && ctx.Err() == nil {
			slog.Warn("bot import failed, retrying", "provider", p.Name(), "import", id, "attempt", job.Attempts, "error", err)
			if err := im.imports.RequeueImport(ctx, id); err != nil {
				slog.Error("requeue bot import", "import", id, "error", err)
				return Result{Import: job, Reason: ReasonFailed}, true
			}
			select {
			case <-time.After(im.retryDelay * time.Duration(job.Attempts)):
				continue
			case <-ctx.Done():
				// Left queued; it resumes on the next start.
				return Result{}, false
			}
		}
		if err != nil {
			slog.Error("bot import failed", "provider", p.Name(), "import", id, "error", err)
			reason = ReasonFailed
		}
		var trackID *string
		if track != nil {
			trackID = &track.ID
		}
		var stored *string
		if reason != "" {
			stored = &reason
		}
		if err := im.imports.FinishImport(context.WithoutCancel(ctx), id, trackID, stored); err != nil {
			slog.Error("finish bot import", "import", id, "error", err)
		}
		return Result{Import: job, Track: track, Reason: reason}, true
	}
}

// importOnce returns a track, or a reason the file is refused, or an error
// worth retrying.
func (im *Importer) importOnce(ctx context.Context, p Provider, job store.BotImport) (*store.Track, string, error) {
	contentType, ok := audio.ContentType(job.FileName)
	if !ok {
		return nil, ReasonUnsupported, nil
	}
	if !im.policy.Enabled {
		return nil, ReasonDisabled, nil
	}
	body, size, err := p.Open(ctx, job.FileID)
	if errors.Is(err, ErrFileTooLarge) {
		return nil, ReasonTooLarge, nil
	}
	if err != nil {
		return nil, "", err
	}
	defer body.Close()
	if size <= 0 || size > im.policy.MaxFileBytes || size > p.MaxDownloadBytes() {
		return nil, ReasonTooLarge, nil
	}

	title := audio.Title(job.FileName)
	if job.Title != nil {
		title = truncate(*job.Title)
	}
	track, err := im.tracks.ReservePending(ctx, job.UserID, store.NewTrack{
		Title: title, Artist: truncatePtr(job.Artist),
		FileName: audio.SafeFileName(job.FileName), ContentType: contentType, SizeBytes: size,
		Source: p.Name(),
	}, im.policy.MaxOwnerBytes, im.policy.MaxPending)
	switch {
	case errors.Is(err, store.ErrQuotaExceeded):
		return nil, ReasonQuota, nil
	case errors.Is(err, store.ErrTooManyPending):
		return nil, ReasonPending, nil
	case err != nil:
		return nil, "", err
	}
	// From here on, a failure must not leave the reservation behind.
	discard := func() {
		cleanup := context.WithoutCancel(ctx)
		if err := im.objects.Remove(cleanup, track.StorageKey); err != nil {
			slog.Error("remove failed bot import object", "track", track.ID, "error", err)
		}
		if err := im.tracks.Delete(cleanup, track.OwnerID, track.ID); err != nil && !errors.Is(err, store.ErrNotFound) {
			slog.Error("delete failed bot import track", "track", track.ID, "error", err)
		}
	}

	header := make([]byte, audio.HeaderBytes)
	n, err := io.ReadFull(body, header)
	if err != nil && !errors.Is(err, io.ErrUnexpectedEOF) && !errors.Is(err, io.EOF) {
		discard()
		return nil, "", err
	}
	header = header[:n]
	if !audio.Matches(job.FileName, header) {
		discard()
		return nil, ReasonInvalid, nil
	}
	if err := im.objects.Put(ctx, track.StorageKey, io.MultiReader(bytes.NewReader(header), body), size, contentType); err != nil {
		discard()
		return nil, "", err
	}
	ready, err := im.tracks.MarkReady(ctx, track.OwnerID, track.ID)
	if err != nil {
		discard()
		return nil, "", err
	}
	return &ready, "", nil
}

// Unfinished lists imports a restart interrupted, so they can be resumed.
func (im *Importer) Unfinished(ctx context.Context) ([]store.BotImport, error) {
	return im.imports.UnfinishedImports(ctx, 100)
}

var extensionsByMIME = map[string]string{
	"audio/mpeg":   ".mp3",
	"audio/mp3":    ".mp3",
	"audio/mp4":    ".m4a",
	"audio/x-m4a":  ".m4a",
	"audio/m4a":    ".m4a",
	"audio/aac":    ".aac",
	"audio/flac":   ".flac",
	"audio/x-flac": ".flac",
	"audio/ogg":    ".ogg",
	"audio/opus":   ".opus",
	"audio/wav":    ".wav",
	"audio/x-wav":  ".wav",
	"audio/wave":   ".wav",
	"audio/webm":   ".webm",
}

// FileName is the file's own name, or one made from its MIME type when the
// messenger sends none or one without a known extension.
func FileName(f File) string {
	if _, ok := audio.ContentType(f.Name); ok {
		return f.Name
	}
	ext, ok := extensionsByMIME[strings.ToLower(strings.TrimSpace(strings.Split(f.MIMEType, ";")[0]))]
	if !ok {
		return f.Name
	}
	stem := strings.TrimSuffix(f.Name, path.Ext(f.Name))
	if stem == "" {
		stem = "track"
	}
	return stem + ext
}

const maxMetadataRunes = 200

func truncate(s string) string {
	s = strings.TrimSpace(s)
	if r := []rune(s); len(r) > maxMetadataRunes {
		return string(r[:maxMetadataRunes])
	}
	return s
}

func truncatePtr(s *string) *string {
	if s == nil {
		return nil
	}
	return nonEmpty(truncate(*s))
}

func nonEmpty(s string) *string {
	if strings.TrimSpace(s) == "" {
		return nil
	}
	return &s
}
