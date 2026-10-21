package store

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// TagStatus is how a track's stored object relates to its edited metadata.
type TagStatus string

const (
	// TagOriginal means the uploaded file's tags were never rewritten.
	TagOriginal TagStatus = "original"
	// TagPending means an edit is waiting for its tags to be written.
	TagPending TagStatus = "pending"
	// TagWritten means the object's tags match metadata version TagVersion.
	TagWritten TagStatus = "written"
	// TagFailed means rewriting gave up; the old object is still served.
	TagFailed TagStatus = "failed"
	// TagUnsupported means the file's format has no safe tag writer.
	TagUnsupported TagStatus = "unsupported"
)

// garbageCollectionLock serializes garbage collection across API instances.
const garbageCollectionLock int64 = 7_310_077

// ClaimTagRewrite leases the next track waiting for a tag rewrite to the
// caller for lease. A track that already used maxAttempts is marked failed
// instead. An object left by an attempt that crashed before swapping it in
// is queued for deletion first. ok is false when nothing is waiting.
func (t *Tracks) ClaimTagRewrite(ctx context.Context, lease time.Duration, maxAttempts int) (Track, bool, error) {
	var claimed Track
	var found bool
	err := pgx.BeginFunc(ctx, t.pool, func(tx pgx.Tx) error {
		track, err := scanTrack(tx.QueryRow(ctx, `
			SELECT `+trackColumns+` FROM tracks
			WHERE tag_status = 'pending' AND status = 'ready'
			  AND (tag_claimed_until IS NULL OR tag_claimed_until < now())
			  AND (tag_not_before IS NULL OR tag_not_before <= now())
			ORDER BY metadata_updated_at NULLS FIRST, id
			LIMIT 1
			FOR UPDATE SKIP LOCKED
		`))
		if errors.Is(err, pgx.ErrNoRows) {
			return nil
		}
		if err != nil {
			return err
		}
		if track.PendingStorageKey != nil {
			if err := queueGarbage(ctx, tx, *track.PendingStorageKey, "abandoned_rewrite", 0); err != nil {
				return err
			}
		}
		if int(track.TagAttempts) >= maxAttempts {
			_, err := tx.Exec(ctx, `
				UPDATE tracks SET tag_status = 'failed', pending_storage_key = NULL,
					tag_claimed_until = NULL, tag_error = COALESCE(tag_error, 'too_many_attempts')
				WHERE id = $1
			`, track.ID)
			return err
		}
		claimed, err = scanTrack(tx.QueryRow(ctx, `
			UPDATE tracks SET tag_attempts = tag_attempts + 1, pending_storage_key = NULL,
				tag_claimed_until = now() + $2::interval
			WHERE id = $1
			RETURNING `+trackColumns,
			track.ID, lease.String()))
		found = err == nil
		return err
	})
	return claimed, found, err
}

// RecordPendingObject notes that a rewrite of track is about to upload key, so
// the object can be found and removed if the process dies before the swap.
// It is ErrVersionConflict when the metadata changed or the track is gone.
func (t *Tracks) RecordPendingObject(ctx context.Context, track Track, key string) error {
	tag, err := t.pool.Exec(ctx, `
		UPDATE tracks SET pending_storage_key = $3
		WHERE id = $1 AND metadata_version = $2 AND tag_status = 'pending'
	`, track.ID, track.MetadataVersion, key)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrVersionConflict
	}
	return nil
}

// ReleaseTagRewrite gives up the lease without recording an attempt result,
// for example because a newer edit superseded the claimed one.
func (t *Tracks) ReleaseTagRewrite(ctx context.Context, trackID string) error {
	_, err := t.pool.Exec(ctx,
		`UPDATE tracks SET tag_claimed_until = NULL WHERE id = $1`, trackID)
	return err
}

// CompleteTagRewrite swaps the verified object newKey in for the object track
// was claimed with, in one transaction, and queues the old object for deletion
// after grace so playback already under way can finish.
//
// Nothing is swapped, and newKey is queued for deletion instead, when the
// track was deleted (ErrNotFound), edited again or its object replaced
// (ErrVersionConflict, leaving the newer edit pending), or the new object
// would take the owner over maxOwnerBytes (ErrQuotaExceeded, marked failed).
func (t *Tracks) CompleteTagRewrite(
	ctx context.Context,
	track Track,
	newKey string,
	newSize int64,
	maxOwnerBytes int64,
	grace time.Duration,
) error {
	var outcome error
	err := pgx.BeginFunc(ctx, t.pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx,
			`SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`, track.OwnerID,
		); err != nil {
			return err
		}
		var version int64
		var storageKey string
		var status TagStatus
		var size int64
		err := tx.QueryRow(ctx, `
			SELECT metadata_version, storage_key, tag_status, size_bytes FROM tracks
			WHERE id = $1 AND owner_id = $2::uuid
			FOR UPDATE
		`, track.ID, track.OwnerID).Scan(&version, &storageKey, &status, &size)
		if errors.Is(err, pgx.ErrNoRows) {
			outcome = ErrNotFound
			return queueGarbage(ctx, tx, newKey, "track_deleted", 0)
		}
		if err != nil {
			return err
		}
		if version != track.MetadataVersion || storageKey != track.StorageKey || status != TagPending {
			outcome = ErrVersionConflict
			if err := queueGarbage(ctx, tx, newKey, "superseded_rewrite", 0); err != nil {
				return err
			}
			_, err := tx.Exec(ctx, `
				UPDATE tracks SET pending_storage_key = NULL, tag_claimed_until = NULL
				WHERE id = $1 AND pending_storage_key = $2
			`, track.ID, newKey)
			return err
		}
		if newSize > size {
			quota, quotaErr := effectiveQuota(ctx, tx, track.OwnerID, maxOwnerBytes)
			if quotaErr != nil {
				return quotaErr
			}
			maxOwnerBytes = quota

			var used int64
			if err := tx.QueryRow(ctx,
				`SELECT COALESCE(SUM(size_bytes), 0)::bigint FROM tracks WHERE owner_id = $1::uuid`,
				track.OwnerID,
			).Scan(&used); err != nil {
				return err
			}
			if used-size+newSize > maxOwnerBytes {
				outcome = ErrQuotaExceeded
				if err := queueGarbage(ctx, tx, newKey, "over_quota_rewrite", 0); err != nil {
					return err
				}
				_, err := tx.Exec(ctx, `
					UPDATE tracks SET tag_status = 'failed', tag_error = 'quota_exceeded',
						pending_storage_key = NULL, tag_claimed_until = NULL
					WHERE id = $1
				`, track.ID)
				return err
			}
		}
		if err := queueGarbage(ctx, tx, storageKey, "replaced_by_rewrite", grace); err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `
			UPDATE tracks SET storage_key = $2, size_bytes = $3, tag_status = 'written',
				tag_version = metadata_version, tag_error = NULL, pending_storage_key = NULL,
				tag_claimed_until = NULL, tag_not_before = NULL
			WHERE id = $1
		`, track.ID, newKey, newSize)
		return err
	})
	if err != nil {
		return err
	}
	return outcome
}

// TagFailure describes a rewrite attempt that did not swap an object in.
type TagFailure struct {
	// Code is a short machine-readable reason, shown to the owner's app.
	Code string
	// RetryAfter delays the next attempt; zero gives up and marks the track
	// failed (or unsupported, see Unsupported).
	RetryAfter time.Duration
	// Unsupported marks the file as having no safe tag writer.
	Unsupported bool
	// UploadedKey is an object the attempt uploaded, now queued for deletion.
	UploadedKey string
}

// FailTagRewrite records a failed attempt for track. If the track was edited
// again meanwhile, only the uploaded object is cleaned up: the newer edit
// already reset the attempt count and stays pending.
func (t *Tracks) FailTagRewrite(ctx context.Context, track Track, failure TagFailure) error {
	return pgx.BeginFunc(ctx, t.pool, func(tx pgx.Tx) error {
		if failure.UploadedKey != "" {
			if err := queueGarbage(ctx, tx, failure.UploadedKey, "failed_rewrite", 0); err != nil {
				return err
			}
		}
		status := TagPending
		switch {
		case failure.Unsupported:
			status = TagUnsupported
		case failure.RetryAfter <= 0:
			status = TagFailed
		}
		_, err := tx.Exec(ctx, `
			UPDATE tracks SET tag_status = $3, tag_error = $4, pending_storage_key = NULL,
				tag_claimed_until = NULL,
				tag_not_before = CASE WHEN $3 = 'pending' THEN now() + $5::interval END
			WHERE id = $1 AND metadata_version = $2 AND tag_status = 'pending'
		`, track.ID, track.MetadataVersion, string(status), failure.Code, failure.RetryAfter.String())
		return err
	})
}

// QueueGarbage schedules key for deletion after delay.
func (t *Tracks) QueueGarbage(ctx context.Context, key, reason string, delay time.Duration) error {
	return queueGarbage(ctx, t.pool, key, reason, delay)
}

type execer interface {
	Exec(context.Context, string, ...any) (pgconn.CommandTag, error)
}

func queueGarbage(ctx context.Context, db execer, key, reason string, delay time.Duration) error {
	_, err := db.Exec(ctx, `
		INSERT INTO storage_garbage (key, reason, delete_after)
		VALUES ($1, $2, now() + $3::interval)
		ON CONFLICT (key) DO UPDATE SET delete_after = LEAST(storage_garbage.delete_after, EXCLUDED.delete_after)
	`, key, reason, delay.String())
	return err
}

// CollectGarbage deletes one bounded batch of objects whose time has come. A
// key that a track still uses (a retried rewrite can upload to a key queued
// earlier) is dropped from the queue without deleting the object. As with
// CleanupStalePending, a storage error rolls the batch back for a later run.
func (t *Tracks) CollectGarbage(ctx context.Context, limit int, remove func(context.Context, string) error) (int, error) {
	removed := 0
	err := pgx.BeginFunc(ctx, t.pool, func(tx pgx.Tx) error {
		var acquired bool
		if err := tx.QueryRow(ctx,
			`SELECT pg_try_advisory_xact_lock($1)`, garbageCollectionLock,
		).Scan(&acquired); err != nil || !acquired {
			return err
		}
		rows, err := tx.Query(ctx, `
			SELECT g.key, EXISTS (
				SELECT 1 FROM tracks
				WHERE tracks.storage_key = g.key OR tracks.pending_storage_key = g.key
			)
			FROM storage_garbage g
			WHERE g.delete_after <= now()
			ORDER BY g.delete_after, g.key
			LIMIT $1
			FOR UPDATE OF g SKIP LOCKED
		`, limit)
		if err != nil {
			return err
		}
		type item struct {
			key   string
			inUse bool
		}
		var due []item
		for rows.Next() {
			var it item
			if err := rows.Scan(&it.key, &it.inUse); err != nil {
				rows.Close()
				return err
			}
			due = append(due, it)
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return err
		}
		for _, it := range due {
			if !it.inUse {
				if err := remove(ctx, it.key); err != nil {
					return fmt.Errorf("remove garbage object: %w", err)
				}
				removed++
			}
			if _, err := tx.Exec(ctx, `DELETE FROM storage_garbage WHERE key = $1`, it.key); err != nil {
				return err
			}
		}
		return nil
	})
	return removed, err
}
