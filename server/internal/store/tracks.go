package store

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/mhdolatabadi/rhythmo/server/internal/audio"
)

type TrackStatus string

const (
	TrackPending TrackStatus = "pending"
	TrackReady   TrackStatus = "ready"
)

var (
	ErrQuotaExceeded  = errors.New("storage quota exceeded")
	ErrTooManyPending = errors.New("too many pending uploads")
	// ErrVersionConflict means the track's metadata changed since the version
	// the caller edited.
	ErrVersionConflict = errors.New("track metadata version conflict")
)

type Track struct {
	ID          string
	OwnerID     string
	Status      TrackStatus
	Title       string
	Artist      *string
	Album       *string
	AlbumArtist *string
	Composer    *string
	Genre       *string
	Year        *int32
	TrackNumber *int32
	DiscNumber  *int32
	Comment     *string
	DurationMS  *int32
	FileName    string
	StorageKey  string
	ContentType string
	SizeBytes   int64
	// Source is "upload" for the app, or the bot provider that imported it.
	Source    string
	CreatedAt time.Time
	// MetadataVersion increases with every metadata edit.
	MetadataVersion int64
	// TagStatus says whether the stored object's embedded tags match the
	// metadata; TagVersion is the metadata version they were written from.
	TagStatus  TagStatus
	TagVersion *int64
	TagError   *string
	// TagAttempts counts rewrite attempts since the last edit.
	TagAttempts int32
	// PendingStorageKey is an uploaded rewrite not yet swapped in.
	PendingStorageKey *string
	// Loudness is the ReplayGain the file's tags carry (#253).
	Loudness Loudness
	// PublishedAt is when the owner published the track on its own, which
	// lists it in the store (#284); nil while it is private.
	PublishedAt *time.Time
	// PublishReview is ReviewPending while an unverified owner's request to
	// publish waits for an admin (#322), ReviewRejected after an admin
	// turned it down, and nil otherwise.
	PublishReview *string
}

// Loudness is ReplayGain as stored: gains in dB re -18 LUFS, peaks as
// linear amplitude. Nil means unknown.
type Loudness struct {
	TrackGainDB *float64
	TrackPeak   *float64
	AlbumGainDB *float64
	AlbumPeak   *float64
}

// NewTrack is what a caller supplies; the ID is chosen by the store so the
// storage key can include it.
type NewTrack struct {
	Title       string
	Artist      *string
	Album       *string
	AlbumArtist *string
	Composer    *string
	Genre       *string
	Year        *int32
	TrackNumber *int32
	DiscNumber  *int32
	Comment     *string
	DurationMS  *int32
	FileName    string
	ContentType string
	SizeBytes   int64
	// Source defaults to "upload".
	Source string
}

// TrackMetadata is the editable identity shown in the app. FileName is the
// display and download name; the storage key keeps its own ASCII-safe name.
type TrackMetadata struct {
	FileName    string
	Title       string
	Artist      *string
	Album       *string
	AlbumArtist *string
	Composer    *string
	Genre       *string
	Year        *int32
	TrackNumber *int32
	DiscNumber  *int32
	Comment     *string
	// TagStatus is TagPending when the stored file's tags will be rewritten
	// to match, or TagUnsupported when its format has no tag writer.
	TagStatus TagStatus
}

// StorageKey is the owner-scoped object path for a track. The object name is
// always reduced to safe ASCII, whatever the display file name is.
func StorageKey(ownerID, trackID, fileName string) string {
	return fmt.Sprintf("users/%s/tracks/%s/%s", ownerID, trackID, audio.SafeFileName(fileName))
}

// Tracks always filters by owner: there is deliberately no method that reads
// a track without one.
type Tracks struct {
	pool *pgxpool.Pool
}

func NewTracks(pool *pgxpool.Pool) *Tracks {
	return &Tracks{pool: pool}
}

const (
	// pendingCleanupLock serializes cleaners across API instances while leaving
	// ordinary track reads and writes unaffected.
	pendingCleanupLock int64 = 7_310_076
)

// trackColumnNames is the one list of columns scanTrack reads, in order.
var trackColumnNames = []string{
	"id::text", "owner_id::text", "status", "title", "artist", "album", "album_artist",
	"composer", "genre", "year", "track_number", "disc_number", "comment", "duration_ms",
	"file_name", "storage_key", "content_type", "size_bytes", "source", "created_at",
	"metadata_version", "tag_status", "tag_version", "tag_error", "tag_attempts",
	"pending_storage_key", "replaygain_track_gain_db", "replaygain_track_peak",
	"replaygain_album_gain_db", "replaygain_album_peak", "published_at", "publish_review",
}

var trackColumns = strings.Join(trackColumnNames, ", ")

// qualifiedTrackColumns is trackColumns for a query that joins tracks with
// other tables, each column prefixed with the table name.
func qualifiedTrackColumns(table string) string {
	return qualifyColumns(table, trackColumnNames)
}

func qualifyColumns(table string, names []string) string {
	qualified := make([]string, len(names))
	for i, name := range names {
		qualified[i] = table + "." + name
	}
	return strings.Join(qualified, ", ")
}

func scanTrack(row pgx.Row) (Track, error) {
	var t Track
	err := row.Scan(trackDestinations(&t)...)
	return t, err
}

// trackDestinations are where scanTrack reads trackColumnNames into, for a
// query that selects more columns after them.
func trackDestinations(t *Track) []any {
	return []any{&t.ID, &t.OwnerID, &t.Status, &t.Title, &t.Artist, &t.Album, &t.AlbumArtist,
		&t.Composer, &t.Genre, &t.Year, &t.TrackNumber, &t.DiscNumber, &t.Comment, &t.DurationMS,
		&t.FileName, &t.StorageKey, &t.ContentType, &t.SizeBytes, &t.Source, &t.CreatedAt,
		&t.MetadataVersion, &t.TagStatus, &t.TagVersion, &t.TagError, &t.TagAttempts,
		&t.PendingStorageKey, &t.Loudness.TrackGainDB, &t.Loudness.TrackPeak,
		&t.Loudness.AlbumGainDB, &t.Loudness.AlbumPeak, &t.PublishedAt, &t.PublishReview}
}

// ReservePending atomically checks the owner's total reserved bytes and active
// pending count before inserting a track. The owner-scoped advisory lock makes
// concurrent API instances unable to race past either limit.
func (t *Tracks) ReservePending(
	ctx context.Context,
	ownerID string,
	track NewTrack,
	maxOwnerBytes int64,
	maxPending int,
) (Track, error) {
	var reserved Track
	err := pgx.BeginFunc(ctx, t.pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx,
			`SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`, ownerID,
		); err != nil {
			return err
		}
		var usedBytes int64
		var pending int
		if err := tx.QueryRow(ctx, `
			SELECT COALESCE(SUM(size_bytes), 0)::bigint,
			       COUNT(*) FILTER (WHERE status = 'pending')::integer
			FROM tracks
			WHERE owner_id::text = $1
		`, ownerID).Scan(&usedBytes, &pending); err != nil {
			return err
		}
		if pending >= maxPending {
			return ErrTooManyPending
		}
		if usedBytes > maxOwnerBytes || track.SizeBytes > maxOwnerBytes-usedBytes {
			return ErrQuotaExceeded
		}
		var err error
		reserved, err = createTrack(ctx, tx, ownerID, track, TrackPending)
		return err
	})
	return reserved, err
}

// Create inserts a track whose object is already in storage.
func (t *Tracks) Create(ctx context.Context, ownerID string, track NewTrack) (Track, error) {
	return createTrack(ctx, t.pool, ownerID, track, TrackReady)
}

type rowQuerier interface {
	QueryRow(context.Context, string, ...any) pgx.Row
}

func createTrack(ctx context.Context, query rowQuerier, ownerID string, track NewTrack, status TrackStatus) (Track, error) {
	source := track.Source
	if source == "" {
		source = "upload"
	}
	return scanTrack(query.QueryRow(ctx, `
		WITH new_id AS (SELECT gen_random_uuid() AS id)
		INSERT INTO tracks (
			id, owner_id, status, title, artist, album, album_artist, composer, genre,
			year, track_number, disc_number, comment, duration_ms, file_name,
			storage_key, content_type, size_bytes, source
		)
		SELECT new_id.id, $1::uuid, $16, $2, $3, $4, $5, $6, $7,
		       $8, $9, $10, $11, $12, $13,
		       'users/' || $1::text || '/tracks/' || new_id.id::text || '/' || $18::text, $14, $15, $17
		FROM new_id
		RETURNING `+trackColumns,
		ownerID, track.Title, track.Artist, track.Album, track.AlbumArtist, track.Composer, track.Genre,
		track.Year, track.TrackNumber, track.DiscNumber, track.Comment, track.DurationMS,
		track.FileName, track.ContentType, track.SizeBytes, string(status), source,
		audio.SafeFileName(track.FileName),
	))
}

// UsageForOwner returns all bytes reserved by ready and pending tracks.
// It intentionally matches the quota calculation in ReservePending.
func (t *Tracks) UsageForOwner(ctx context.Context, ownerID string) (int64, error) {
	var usedBytes int64
	err := t.pool.QueryRow(ctx, `
		SELECT COALESCE(SUM(size_bytes), 0)::bigint
		FROM tracks
		WHERE owner_id::text = $1
	`, ownerID).Scan(&usedBytes)
	return usedBytes, err
}

func (t *Tracks) ListForOwner(ctx context.Context, ownerID string) ([]Track, error) {
	rows, err := t.pool.Query(ctx,
		`SELECT `+trackColumns+` FROM tracks WHERE owner_id::text = $1 AND status = 'ready'
		 ORDER BY created_at DESC, id`,
		ownerID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	tracks := []Track{}
	for rows.Next() {
		track, err := scanTrack(rows)
		if err != nil {
			return nil, err
		}
		tracks = append(tracks, track)
	}
	return tracks, rows.Err()
}

// ForOwner returns ErrNotFound both when the track does not exist and when it
// belongs to someone else, so callers cannot probe other users' track IDs.
func (t *Tracks) ForOwner(ctx context.Context, ownerID, trackID string) (Track, error) {
	track, err := scanTrack(t.pool.QueryRow(ctx,
		`SELECT `+trackColumns+` FROM tracks WHERE id::text = $1 AND owner_id::text = $2`,
		trackID, ownerID))
	if errors.Is(err, pgx.ErrNoRows) {
		return Track{}, ErrNotFound
	}
	return track, err
}

// MarkReady flips the owner's pending track to ready.
func (t *Tracks) MarkReady(ctx context.Context, ownerID, trackID string) (Track, error) {
	track, err := scanTrack(t.pool.QueryRow(ctx,
		`UPDATE tracks SET status = 'ready'
		 WHERE id::text = $1 AND owner_id::text = $2
		 RETURNING `+trackColumns,
		trackID, ownerID))
	if errors.Is(err, pgx.ErrNoRows) {
		return Track{}, ErrNotFound
	}
	return track, err
}

// UpdateMetadata changes the display metadata for one ready track owned by the
// caller, if its metadata is still at expectedVersion, and bumps the version.
// Pending uploads cannot be edited because they are not visible yet; they and
// other users' tracks are ErrNotFound. A newer version is ErrVersionConflict.
func (t *Tracks) UpdateMetadata(
	ctx context.Context,
	ownerID, trackID string,
	expectedVersion int64,
	metadata TrackMetadata,
) (Track, error) {
	tagStatus := metadata.TagStatus
	if tagStatus != TagPending && tagStatus != TagUnsupported {
		return Track{}, fmt.Errorf("metadata edit needs a tag status, got %q", tagStatus)
	}
	var updated Track
	err := pgx.BeginFunc(ctx, t.pool, func(tx pgx.Tx) error {
		var current int64
		err := tx.QueryRow(ctx, `
			SELECT metadata_version FROM tracks
			WHERE id::text = $1 AND owner_id::text = $2 AND status = 'ready'
			FOR UPDATE
		`, trackID, ownerID).Scan(&current)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		if current != expectedVersion {
			return ErrVersionConflict
		}
		updated, err = scanTrack(tx.QueryRow(ctx,
			`UPDATE tracks SET
				file_name = $3, title = $4, artist = $5, album = $6, album_artist = $7,
				composer = $8, genre = $9, year = $10, track_number = $11,
				disc_number = $12, comment = $13,
				metadata_version = metadata_version + 1, metadata_updated_at = now(),
				tag_status = $14, tag_error = NULL, tag_attempts = 0, tag_not_before = NULL
			 WHERE id::text = $1 AND owner_id::text = $2
			 RETURNING `+trackColumns,
			trackID, ownerID, metadata.FileName, metadata.Title, metadata.Artist, metadata.Album,
			metadata.AlbumArtist, metadata.Composer, metadata.Genre, metadata.Year,
			metadata.TrackNumber, metadata.DiscNumber, metadata.Comment, string(tagStatus)))
		return err
	})
	return updated, err
}

// Delete removes the owner's track row.
func (t *Tracks) Delete(ctx context.Context, ownerID, trackID string) error {
	tag, err := t.pool.Exec(ctx,
		`DELETE FROM tracks WHERE id::text = $1 AND owner_id::text = $2`, trackID, ownerID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// CleanupStalePending removes one bounded batch of abandoned reservations.
//
// A transaction-scoped advisory lock makes this safe across API instances. The
// object is removed before its row; if storage fails, the transaction rolls
// back and a later run retries the same row. Removing an already-missing object
// must be treated as success by remove.
func (t *Tracks) CleanupStalePending(
	ctx context.Context,
	before time.Time,
	limit int,
	remove func(context.Context, string) error,
) (int, error) {
	removed := 0
	err := pgx.BeginFunc(ctx, t.pool, func(tx pgx.Tx) error {
		var acquired bool
		if err := tx.QueryRow(ctx,
			`SELECT pg_try_advisory_xact_lock($1)`, pendingCleanupLock,
		).Scan(&acquired); err != nil {
			return err
		}
		if !acquired {
			return nil
		}

		rows, err := tx.Query(ctx, `
			SELECT `+trackColumns+`
			FROM tracks
			WHERE status = 'pending' AND created_at < $1
			ORDER BY created_at, id
			FOR UPDATE SKIP LOCKED
			LIMIT $2
		`, before, limit)
		if err != nil {
			return err
		}
		stale := make([]Track, 0, limit)
		for rows.Next() {
			track, err := scanTrack(rows)
			if err != nil {
				rows.Close()
				return err
			}
			stale = append(stale, track)
		}
		if err := rows.Err(); err != nil {
			rows.Close()
			return err
		}
		rows.Close()

		for _, track := range stale {
			if err := remove(ctx, track.StorageKey); err != nil {
				return fmt.Errorf("remove stale upload object: %w", err)
			}
			if _, err := tx.Exec(ctx,
				`DELETE FROM tracks WHERE id = $1 AND status = 'pending'`, track.ID,
			); err != nil {
				return err
			}
			removed++
		}
		return nil
	})
	return removed, err
}
