package store

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Fingerprints keeps each track's acoustic fingerprint and finds the
// fingerprints a user may match against.
type Fingerprints struct {
	pool *pgxpool.Pool
}

func NewFingerprints(pool *pgxpool.Pool) *Fingerprints {
	return &Fingerprints{pool: pool}
}

// ClaimFingerprintJobs leases up to limit ready tracks that have no
// fingerprint yet, newest first: new uploads and imports, and every older
// track until the backfill is done. A track whose fingerprint failed
// maxAttempts times is left alone.
func (f *Fingerprints) ClaimFingerprintJobs(ctx context.Context, limit, maxAttempts int, lease time.Duration) ([]Track, error) {
	rows, err := f.pool.Query(ctx, `
		WITH due AS (
			SELECT tracks.id FROM tracks
			LEFT JOIN track_fingerprints fp ON fp.track_id = tracks.id
			WHERE tracks.status = 'ready' AND (fp.track_id IS NULL OR (
				fp.points IS NULL AND fp.attempts < $2
				AND COALESCE(fp.not_before, '-infinity') <= now()
				AND COALESCE(fp.claimed_until, '-infinity') <= now()))
			ORDER BY tracks.created_at DESC
			LIMIT $1
			FOR UPDATE OF tracks SKIP LOCKED
		), claimed AS (
			INSERT INTO track_fingerprints (track_id, attempts, claimed_until)
			SELECT id, 1, now() + $3::interval FROM due
			ON CONFLICT (track_id) DO UPDATE SET
				attempts = track_fingerprints.attempts + 1,
				claimed_until = EXCLUDED.claimed_until, updated_at = now()
			RETURNING track_id
		)
		SELECT `+qualifiedTrackColumns("tracks")+`
		FROM claimed JOIN tracks ON tracks.id = claimed.track_id
	`, limit, maxAttempts, lease.String())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var jobs []Track
	for rows.Next() {
		track, err := scanTrack(rows)
		if err != nil {
			return nil, err
		}
		jobs = append(jobs, track)
	}
	return jobs, rows.Err()
}

// SaveFingerprint stores a track's fingerprint, packed by the caller. A
// track deleted meanwhile is not an error.
func (f *Fingerprints) SaveFingerprint(ctx context.Context, trackID string, points []byte, duration time.Duration) error {
	if len(points) == 0 {
		return errors.New("empty fingerprint")
	}
	_, err := f.pool.Exec(ctx, `
		INSERT INTO track_fingerprints (track_id, points, duration_seconds, attempts)
		VALUES ($1::text::uuid, $2, $3, 1)
		ON CONFLICT (track_id) DO UPDATE SET points = EXCLUDED.points,
			duration_seconds = EXCLUDED.duration_seconds, error = NULL,
			claimed_until = NULL, not_before = NULL, updated_at = now()
	`, trackID, points, duration.Seconds())
	return ignoreDeletedTrack(err)
}

// FingerprintFailed records why a track couldn't be fingerprinted; it is
// tried again after retryAfter, while attempts remain.
func (f *Fingerprints) FingerprintFailed(ctx context.Context, trackID, reason string, retryAfter time.Duration) error {
	_, err := f.pool.Exec(ctx, `
		UPDATE track_fingerprints SET error = $2, claimed_until = NULL,
			not_before = now() + $3::interval, updated_at = now()
		WHERE track_id::text = $1
	`, trackID, truncateText(reason, 500), retryAfter.String())
	return err
}

func ignoreDeletedTrack(err error) error {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "23503" {
		return nil
	}
	return err
}

func truncateText(s string, max int) string {
	runes := []rune(s)
	if len(runes) > max {
		return string(runes[:max])
	}
	return s
}

// MatchSource says how the user may reach a matched track: their own
// library, a collaborative playlist they belong to, or a public playlist.
type MatchSource struct {
	// PlaylistID is set for a track in a collaborative playlist the user
	// owns or joined.
	PlaylistID *string
	// ShareToken is set for a track in a public playlist.
	ShareToken *string
	// StoreEntryID is set for a song matched in the public store, for
	// listeners without an account.
	StoreEntryID *string
}

// Matchable is a fingerprinted track the user may play.
type Matchable struct {
	Track      Track
	OwnerEmail string
	Source     MatchSource
	Points     []byte
}

// EachMatchable calls fn for every fingerprinted ready track userID may
// play, and only those: their own tracks, tracks in collaborative
// playlists they own or have joined, and tracks in public playlists. A
// track is reported once, through the closest way to reach it. Nothing in
// other users' private libraries is ever read. A non-nil error from fn
// stops the walk and is returned.
func (f *Fingerprints) EachMatchable(ctx context.Context, userID string, fn func(Matchable) error) error {
	rows, err := f.pool.Query(ctx, `
		SELECT `+qualifiedTrackColumns("tracks")+`, users.email, via.playlist_id, via.share_token, fp.points
		FROM track_fingerprints fp
		JOIN tracks ON tracks.id = fp.track_id
		JOIN users ON users.id = tracks.owner_id
		LEFT JOIN LATERAL (
			SELECT CASE WHEN `+canEdit("playlists", "$1")+` THEN playlists.id::text END AS playlist_id,
			       CASE WHEN `+canEdit("playlists", "$1")+` THEN NULL ELSE playlists.share_token END AS share_token
			FROM playlist_tracks pt JOIN playlists ON playlists.id = pt.playlist_id
			WHERE pt.track_id = tracks.id AND `+trackBelongs("tracks", "playlists")+`
			  AND (`+canEdit("playlists", "$1")+` OR (playlists.is_public AND playlists.share_token IS NOT NULL))
			ORDER BY `+canEdit("playlists", "$1")+` DESC, playlists.updated_at DESC
			LIMIT 1
		) via ON tracks.owner_id::text <> $1
		WHERE fp.points IS NOT NULL AND tracks.status = 'ready'
		  AND (tracks.owner_id::text = $1 OR via.playlist_id IS NOT NULL OR via.share_token IS NOT NULL)
	`, userID)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var m Matchable
		dest := append(trackDestinations(&m.Track), &m.OwnerEmail, &m.Source.PlaylistID, &m.Source.ShareToken, &m.Points)
		if err := rows.Scan(dest...); err != nil {
			return err
		}
		if err := fn(m); err != nil {
			return err
		}
	}
	return rows.Err()
}

// SaveTrackCopy copies someone else's ready track into userID's library:
// a new track of their own with the same metadata and a copy of the audio,
// within their quota. The original stays untouched.
func (f *Fingerprints) SaveTrackCopy(ctx context.Context, userID string, original Track, maxOwnerBytes int64, objects ObjectCopier) (Track, error) {
	if original.OwnerID == userID {
		return Track{}, ErrOwnPlaylist
	}
	var copied Track
	err := pgx.BeginFunc(ctx, f.pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`, userID); err != nil {
			return err
		}
		quota, quotaErr := effectiveQuota(ctx, tx, userID, maxOwnerBytes)
		if quotaErr != nil {
			return quotaErr
		}
		maxOwnerBytes = quota
		var used int64
		if err := tx.QueryRow(ctx, `
			SELECT COALESCE(SUM(size_bytes), 0)::bigint FROM tracks WHERE owner_id::text = $1
		`, userID).Scan(&used); err != nil {
			return err
		}
		if used > maxOwnerBytes || original.SizeBytes > maxOwnerBytes-used {
			return ErrQuotaExceeded
		}
		var err error
		copied, err = createTrack(ctx, tx, userID, NewTrack{
			Title: original.Title, Artist: original.Artist, Album: original.Album,
			AlbumArtist: original.AlbumArtist, Composer: original.Composer, Genre: original.Genre,
			Year: original.Year, TrackNumber: original.TrackNumber, DiscNumber: original.DiscNumber,
			Comment: original.Comment, DurationMS: original.DurationMS, FileName: original.FileName,
			ContentType: original.ContentType, SizeBytes: original.SizeBytes, Source: "shared",
		}, TrackPending)
		return err
	})
	if err != nil {
		return Track{}, err
	}
	discard := func() {
		cleanup := context.WithoutCancel(ctx)
		_ = objects.Remove(cleanup, copied.StorageKey)
		_, _ = f.pool.Exec(cleanup, `DELETE FROM tracks WHERE id::text = $1 AND status = 'pending'`, copied.ID)
	}
	if err := objects.Copy(ctx, original.StorageKey, copied.StorageKey); err != nil {
		discard()
		return Track{}, fmt.Errorf("copy track audio: %w", err)
	}
	ready, err := scanTrack(f.pool.QueryRow(ctx, `
		UPDATE tracks SET status = 'ready' WHERE id::text = $1 RETURNING `+trackColumns, copied.ID))
	if err != nil {
		discard()
		return Track{}, err
	}
	// The copy is the same audio: reuse the fingerprint rather than
	// computing it again.
	_, _ = f.pool.Exec(ctx, `
		INSERT INTO track_fingerprints (track_id, points, duration_seconds, attempts)
		SELECT $1::text::uuid, points, duration_seconds, 1 FROM track_fingerprints
		WHERE track_id::text = $2 AND points IS NOT NULL
		ON CONFLICT (track_id) DO NOTHING
	`, ready.ID, original.ID)
	return ready, nil
}
