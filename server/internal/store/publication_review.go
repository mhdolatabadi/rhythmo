package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Review states of a request to list a playlist publicly or publish a track
// (#322). An unverified owner's request is pending until an admin decides.
const (
	ReviewPending  = "pending"
	ReviewRejected = "rejected"
)

// Kinds of content an admin reviews before it is published.
const (
	PublicationPlaylist = "playlist"
	PublicationTrack    = "track"
)

// ErrNotPending means the playlist or track has no request waiting for an
// admin: it was withdrawn, decided already, or never made.
var ErrNotPending = errors.New("no pending publication request")

// PendingPublication is one request waiting for an admin.
type PendingPublication struct {
	Kind string
	ID   string
	// Title is the playlist's name or the track's title; Artist is only set
	// for a track.
	Title  string
	Artist string
	// ShareToken opens a playlist for review; TrackCount counts its ready
	// tracks.
	ShareToken  *string
	TrackCount  int
	OwnerID     string
	OwnerEmail  string
	RequestedAt time.Time
}

// Publications keeps admin review of what unverified owners publish.
type Publications struct {
	pool *pgxpool.Pool
}

func NewPublications(pool *pgxpool.Pool) *Publications {
	return &Publications{pool: pool}
}

// Pending lists up to limit open requests, oldest first, so the queue is
// worked through in order.
func (p *Publications) Pending(ctx context.Context, limit int) ([]PendingPublication, error) {
	rows, err := p.pool.Query(ctx, `
		SELECT 'playlist', playlists.id::text, playlists.name, '', playlists.share_token,
			(SELECT count(*)::int FROM playlist_tracks pt JOIN tracks ON tracks.id = pt.track_id
			 WHERE pt.playlist_id = playlists.id AND `+trackBelongs("tracks", "playlists")+`
			   AND tracks.status = 'ready'),
			playlists.owner_id::text, users.email, playlists.public_review_at
		FROM playlists JOIN users ON users.id = playlists.owner_id
		WHERE playlists.public_review = 'pending' AND playlists.share_token IS NOT NULL
		UNION ALL
		SELECT 'track', tracks.id::text, tracks.title, COALESCE(tracks.artist, ''), NULL, 0,
			tracks.owner_id::text, users.email, tracks.publish_review_at
		FROM tracks JOIN users ON users.id = tracks.owner_id
		WHERE tracks.publish_review = 'pending' AND tracks.status = 'ready'
		ORDER BY 9, 2
		LIMIT $1
	`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	pending := []PendingPublication{}
	for rows.Next() {
		var item PendingPublication
		if err := rows.Scan(&item.Kind, &item.ID, &item.Title, &item.Artist, &item.ShareToken,
			&item.TrackCount, &item.OwnerID, &item.OwnerEmail, &item.RequestedAt); err != nil {
			return nil, err
		}
		pending = append(pending, item)
	}
	return pending, rows.Err()
}

// PendingTrack returns a track waiting for review, so an admin can listen
// to it first, or ErrNotPending.
func (p *Publications) PendingTrack(ctx context.Context, trackID string) (Track, error) {
	track, err := scanTrack(p.pool.QueryRow(ctx, `
		SELECT `+trackColumns+` FROM tracks
		WHERE id::text = $1 AND publish_review = 'pending' AND status = 'ready'
	`, trackID))
	if errors.Is(err, pgx.ErrNoRows) {
		return Track{}, ErrNotPending
	}
	return track, err
}

// ReviewPlaylist approves a pending request to list the playlist publicly,
// which lists it, or rejects it, which the owner then sees. The decision
// and its admin actorID are audited in the same transaction.
func (p *Publications) ReviewPlaylist(ctx context.Context, playlistID, actorID string, approve bool) error {
	return p.review(ctx, PublicationPlaylist, `
		UPDATE playlists SET
			is_public = $2,
			public_review = CASE WHEN $2 THEN NULL ELSE 'rejected' END,
			public_review_at = CASE WHEN $2 THEN NULL ELSE now() END
		WHERE id::text = $1 AND public_review = 'pending' AND share_token IS NOT NULL
		RETURNING id::text
	`, playlistID, actorID, approve)
}

// ReviewTrack approves a pending request to publish the track, which lists
// it in the store, or rejects it. The decision is audited.
func (p *Publications) ReviewTrack(ctx context.Context, trackID, actorID string, approve bool) error {
	return p.review(ctx, PublicationTrack, `
		UPDATE tracks SET
			published_at = CASE WHEN $2 THEN now() END,
			publish_review = CASE WHEN $2 THEN NULL ELSE 'rejected' END,
			publish_review_at = CASE WHEN $2 THEN NULL ELSE now() END
		WHERE id::text = $1 AND publish_review = 'pending' AND status = 'ready'
		RETURNING id::text
	`, trackID, actorID, approve)
}

func (p *Publications) review(ctx context.Context, kind, update, id, actorID string, approve bool) error {
	return pgx.BeginFunc(ctx, p.pool, func(tx pgx.Tx) error {
		var subjectID string
		err := tx.QueryRow(ctx, update, id, approve).Scan(&subjectID)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotPending
		}
		if err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `
			INSERT INTO publication_review_audit (kind, subject_id, actor_id, approved)
			VALUES ($1, $2::uuid, $3::uuid, $4)
		`, kind, subjectID, actorID, approve)
		return err
	})
}
