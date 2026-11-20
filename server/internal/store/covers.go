package store

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"
)

// SetTrackCover stores the owner's chosen cover for a ready track and counts
// it as a metadata edit: the version goes up and, when tagStatus is
// TagPending, the tag writer embeds the cover so downloads carry it.
func (t *Tracks) SetTrackCover(
	ctx context.Context,
	ownerID, trackID string,
	expectedVersion int64,
	image []byte,
	tagStatus TagStatus,
) (Track, error) {
	if tagStatus != TagPending && tagStatus != TagUnsupported {
		return Track{}, errors.New("cover edit needs a tag status")
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
		if _, err := tx.Exec(ctx, `
			INSERT INTO track_covers (track_id, image) VALUES ($1::uuid, $2)
			ON CONFLICT (track_id) DO UPDATE SET image = EXCLUDED.image, updated_at = now()
		`, trackID, image); err != nil {
			return err
		}
		updated, err = scanTrack(tx.QueryRow(ctx,
			`UPDATE tracks SET
				metadata_version = metadata_version + 1, metadata_updated_at = now(),
				tag_status = $3, tag_error = NULL, tag_attempts = 0, tag_not_before = NULL
			 WHERE id::text = $1 AND owner_id::text = $2
			 RETURNING `+trackColumns,
			trackID, ownerID, string(tagStatus)))
		return err
	})
	return updated, err
}

// TrackCover returns the cover the owner chose for a track, or nil when the
// track shows its embedded artwork.
func (t *Tracks) TrackCover(ctx context.Context, trackID string) ([]byte, error) {
	var image []byte
	err := t.pool.QueryRow(ctx,
		`SELECT image FROM track_covers WHERE track_id::text = $1`, trackID).Scan(&image)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	return image, err
}
