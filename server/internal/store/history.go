package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// HistoryEntry is a track the user played recently, as they may still
// play it now.
type HistoryEntry struct {
	Track Track
	// PlaylistID is the collaborative playlist someone else's track was
	// played through; nil for the user's own tracks.
	PlaylistID *string
	// OwnerEmail is whoever owns the track.
	OwnerEmail string
	PlayedAt   time.Time
}

// History is each user's recently played tracks. Every read and write is
// scoped to one user, and a track is only ever returned while that user
// can still play it.
type History struct {
	pool *pgxpool.Pool
}

func NewHistory(pool *pgxpool.Pool) *History {
	return &History{pool: pool}
}

// playable is true when user $N may play track t, as recorded in history
// row h: their own ready track, or a ready track still in a playlist
// (pl, left joined on h.playlist_id) that they own or have joined.
func playable(h, t, pl, user string) string {
	return `(` + t + `.status = 'ready' AND (` + t + `.owner_id::text = ` + user + ` OR (
		` + pl + `.id IS NOT NULL AND ` + canEdit(pl, user) + ` AND ` + trackBelongs(t, pl) + `
		AND EXISTS (SELECT 1 FROM playlist_tracks pt WHERE pt.playlist_id = ` + h + `.playlist_id AND pt.track_id = ` + t + `.id))))`
}

// Record adds a play of trackID for userID and keeps only the newest keep
// entries. playlistID names the playlist someone else's track was played
// through; it is ignored for the user's own tracks. A track the user can't
// play is ErrNotFound, whoever owns it.
func (h *History) Record(ctx context.Context, userID, trackID string, playlistID *string, keep int) error {
	return pgx.BeginFunc(ctx, h.pool, func(tx pgx.Tx) error {
		// One writer per user at a time, so trimming can't race inserting.
		if _, err := tx.Exec(ctx,
			`SELECT pg_advisory_xact_lock(hashtextextended('history:' || $1, 0))`, userID,
		); err != nil {
			return err
		}
		var via *string
		err := tx.QueryRow(ctx, `
			SELECT CASE WHEN tracks.owner_id::text = $1 THEN NULL ELSE playlists.id::text END
			FROM tracks
			LEFT JOIN playlists ON playlists.id::text = $3
			CROSS JOIN LATERAL (SELECT playlists.id AS playlist_id) h
			WHERE tracks.id::text = $2 AND `+playable("h", "tracks", "playlists", "$1")+`
		`, userID, trackID, playlistID).Scan(&via)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `
			INSERT INTO play_history (user_id, track_id, playlist_id)
			VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid)
		`, userID, trackID, via); err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `
			DELETE FROM play_history
			WHERE user_id = $1::text::uuid AND id NOT IN (
				SELECT id FROM play_history WHERE user_id = $1::text::uuid
				ORDER BY played_at DESC, id DESC
				LIMIT $2
			)
		`, userID, keep)
		return err
	})
}

// Recent lists up to limit tracks the user played, each once at its latest
// play, most recent first. Tracks deleted since, or no longer playable
// because the user left or was removed from the playlist, are left out.
func (h *History) Recent(ctx context.Context, userID string, limit int) ([]HistoryEntry, error) {
	rows, err := h.pool.Query(ctx, `
		SELECT `+qualifiedTrackColumns("tracks")+`, latest.playlist_id::text, users.email, latest.played_at
		FROM (
			SELECT DISTINCT ON (h.track_id) h.id, h.track_id, h.playlist_id, h.played_at
			FROM play_history h
			JOIN tracks ON tracks.id = h.track_id
			LEFT JOIN playlists ON playlists.id = h.playlist_id
			WHERE h.user_id = $1::text::uuid AND `+playable("h", "tracks", "playlists", "$1")+`
			ORDER BY h.track_id, h.played_at DESC, h.id DESC
		) latest
		JOIN tracks ON tracks.id = latest.track_id
		JOIN users ON users.id = tracks.owner_id
		ORDER BY latest.played_at DESC, latest.id DESC
		LIMIT $2
	`, userID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	entries := []HistoryEntry{}
	for rows.Next() {
		var e HistoryEntry
		dest := append(trackDestinations(&e.Track), &e.PlaylistID, &e.OwnerEmail, &e.PlayedAt)
		if err := rows.Scan(dest...); err != nil {
			return nil, err
		}
		entries = append(entries, e)
	}
	return entries, rows.Err()
}

// PlayRecord is one play of one of the user's own tracks.
type PlayRecord struct {
	TrackID  string
	PlayedAt time.Time
}

// OwnPlays lists userID's plays of their own ready tracks, the signal «برای
// تو» is built from (#226). Plays through someone else's playlist are left
// out.
func (h *History) OwnPlays(ctx context.Context, userID string) ([]PlayRecord, error) {
	rows, err := h.pool.Query(ctx, `
		SELECT h.track_id::text, h.played_at FROM play_history h
		JOIN tracks t ON t.id = h.track_id
		WHERE h.user_id = $1::text::uuid AND t.owner_id = h.user_id AND t.status = 'ready'
		ORDER BY h.played_at, h.id
	`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	plays := []PlayRecord{}
	for rows.Next() {
		var p PlayRecord
		if err := rows.Scan(&p.TrackID, &p.PlayedAt); err != nil {
			return nil, err
		}
		plays = append(plays, p)
	}
	return plays, rows.Err()
}

// Clear forgets everything the user played.
func (h *History) Clear(ctx context.Context, userID string) error {
	_, err := h.pool.Exec(ctx, `DELETE FROM play_history WHERE user_id = $1::text::uuid`, userID)
	return err
}
