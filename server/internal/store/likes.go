package store

import (
	"context"
	"errors"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// SetPublished publishes the owner's ready track on its own, which lists
// it in the store (#284), or makes it private again. Unpublishing leaves it
// in the store while a public playlist still holds it. Without direct (an
// owner who is neither verified nor an admin, #322), publishing only asks
// for an admin's approval: the track stays private with a pending review.
// Unpublishing also withdraws such a request. ErrNotFound unless ownerID
// owns a ready track with that id.
func (t *Tracks) SetPublished(ctx context.Context, ownerID, trackID string, published, direct bool) (Track, error) {
	track, err := scanTrack(t.pool.QueryRow(ctx, `
		UPDATE tracks SET
			published_at = CASE WHEN $3 AND ($4 OR published_at IS NOT NULL) THEN COALESCE(published_at, now()) END,
			publish_review = CASE WHEN $3 AND NOT $4 AND published_at IS NULL THEN 'pending' END,
			publish_review_at = CASE WHEN $3 AND NOT $4 AND published_at IS NULL
				THEN CASE WHEN publish_review = 'pending' THEN publish_review_at ELSE now() END END
		WHERE id::text = $1 AND owner_id::text = $2 AND status = 'ready'
		RETURNING `+trackColumns, trackID, ownerID, published, direct))
	if errors.Is(err, pgx.ErrNoRows) {
		return Track{}, ErrNotFound
	}
	return track, err
}

// LikeState is how many listeners like a song and whether the viewer does.
type LikeState struct {
	Count int
	Liked bool
}

// TrackLikes keeps likes on tracks (#284). A listener likes their own
// tracks directly and a store song through one of its copies; a song's
// count is the distinct listeners who liked any of its copies.
type TrackLikes struct {
	pool *pgxpool.Pool
}

func NewTrackLikes(pool *pgxpool.Pool) *TrackLikes {
	return &TrackLikes{pool: pool}
}

// copiesOf is the tracks that are the same song as track: itself and,
// when it is grouped into a store entry, every other copy in it.
func copiesOf(track string) string {
	return `(SELECT ` + track + ` UNION SELECT et2.track_id FROM store_entry_tracks et1
		JOIN store_entry_tracks et2 ON et2.entry_id = et1.entry_id WHERE et1.track_id = ` + track + `)`
}

// SetOwnLike likes or unlikes one of userID's own ready tracks. Both are
// idempotent. ErrNotFound for anyone else's track: those are liked through
// the store.
func (l *TrackLikes) SetOwnLike(ctx context.Context, userID, trackID string, liked bool) (LikeState, error) {
	var exists bool
	if err := l.pool.QueryRow(ctx, `
		SELECT EXISTS (SELECT 1 FROM tracks WHERE id::text = $1 AND owner_id::text = $2 AND status = 'ready')
	`, trackID, userID).Scan(&exists); err != nil {
		return LikeState{}, err
	}
	if !exists {
		return LikeState{}, ErrNotFound
	}
	if err := l.set(ctx, userID, []string{trackID}, trackID, liked); err != nil {
		return LikeState{}, err
	}
	return l.trackState(ctx, userID, trackID)
}

// set likes target for userID, or removes their likes on every track in
// copies, in one statement each.
func (l *TrackLikes) set(ctx context.Context, userID string, copies []string, target string, liked bool) error {
	var err error
	if liked {
		_, err = l.pool.Exec(ctx, `
			INSERT INTO track_likes (user_id, track_id) VALUES ($1::text::uuid, $2::text::uuid)
			ON CONFLICT DO NOTHING
		`, userID, target)
	} else {
		_, err = l.pool.Exec(ctx, `
			DELETE FROM track_likes WHERE user_id::text = $1 AND track_id::text = ANY($2)
		`, userID, copies)
	}
	return ignoreDeletedTrack(err)
}

func (l *TrackLikes) trackState(ctx context.Context, userID, trackID string) (LikeState, error) {
	var state LikeState
	err := l.pool.QueryRow(ctx, `
		SELECT count(DISTINCT user_id)::int, COALESCE(bool_or(user_id::text = $2), false)
		FROM track_likes WHERE track_id IN `+copiesOf("$1::text::uuid")+`
	`, trackID, userID).Scan(&state.Count, &state.Liked)
	return state, err
}

// SetStoreLike likes a listed store song (through its best copy, unless
// userID already likes one of its copies) or unlikes it (every copy).
// ErrNotFound when the entry isn't listed.
func (l *TrackLikes) SetStoreLike(ctx context.Context, userID, entryID string, liked bool) (LikeState, error) {
	entry, err := NewCatalog(l.pool).StoreEntryByID(ctx, entryID, false)
	if err != nil {
		return LikeState{}, err
	}
	copies, err := l.entryCopies(ctx, entryID)
	if err != nil {
		return LikeState{}, err
	}
	if liked {
		states, err := l.EntryStates(ctx, userID, []string{entryID})
		if err != nil {
			return LikeState{}, err
		}
		if states[entryID].Liked {
			return states[entryID], nil
		}
	}
	if err := l.set(ctx, userID, copies, entry.Track.ID, liked); err != nil {
		return LikeState{}, err
	}
	states, err := l.EntryStates(ctx, userID, []string{entryID})
	return states[entryID], err
}

func (l *TrackLikes) entryCopies(ctx context.Context, entryID string) ([]string, error) {
	rows, err := l.pool.Query(ctx, `SELECT track_id::text FROM store_entry_tracks WHERE entry_id::text = $1`, entryID)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowTo[string])
}

// EntryStates is the like state of each store entry for viewerID ("" for a
// visitor, who likes nothing). Entries nobody likes are left out.
func (l *TrackLikes) EntryStates(ctx context.Context, viewerID string, entryIDs []string) (map[string]LikeState, error) {
	states := map[string]LikeState{}
	if len(entryIDs) == 0 {
		return states, nil
	}
	rows, err := l.pool.Query(ctx, `
		SELECT et.entry_id::text, count(DISTINCT tl.user_id)::int, COALESCE(bool_or(tl.user_id::text = $2), false)
		FROM store_entry_tracks et JOIN track_likes tl ON tl.track_id = et.track_id
		WHERE et.entry_id::text = ANY($1)
		GROUP BY et.entry_id
	`, entryIDs, viewerID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var id string
		var state LikeState
		if err := rows.Scan(&id, &state.Count, &state.Liked); err != nil {
			return nil, err
		}
		states[id] = state
	}
	return states, rows.Err()
}

// OwnerStates is the like state of each of ownerID's tracks that anyone
// likes: the distinct listeners who liked it or any copy of the same song
// in the store, and whether the owner does. Only the owner ever sees these
// per-track counts.
func (l *TrackLikes) OwnerStates(ctx context.Context, ownerID string) (map[string]LikeState, error) {
	rows, err := l.pool.Query(ctx, `
		SELECT t.id::text, counts.count, counts.liked
		FROM tracks t
		CROSS JOIN LATERAL (
			SELECT count(DISTINCT tl.user_id)::int AS count,
				COALESCE(bool_or(tl.user_id = t.owner_id AND tl.track_id = t.id), false) AS liked
			FROM track_likes tl WHERE tl.track_id IN `+copiesOf("t.id")+`
		) counts
		WHERE t.owner_id::text = $1 AND counts.count > 0
	`, ownerID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	states := map[string]LikeState{}
	for rows.Next() {
		var id string
		var state LikeState
		if err := rows.Scan(&id, &state.Count, &state.Liked); err != nil {
			return nil, err
		}
		states[id] = state
	}
	return states, rows.Err()
}

// LikedSong is one of the listener's «پسندیده‌ها»: their own track, or a
// store song (Entry set).
type LikedSong struct {
	LikedAt time.Time
	Track   Track
	Entry   *StoreEntry
}

// maxLiked caps how many likes one listing reads.
const maxLiked = 2000

// Liked lists the songs userID liked that they can still play, most
// recently liked first: their own ready tracks, and store songs still
// listed (each once, however many of its copies they liked). Songs that
// left the store and aren't theirs are left out.
func (l *TrackLikes) Liked(ctx context.Context, userID string, limit, offset int) ([]LikedSong, bool, error) {
	var songs []LikedSong
	rows, err := l.pool.Query(ctx, `
		SELECT tl.created_at, `+qualifiedTrackColumns("tracks")+`
		FROM track_likes tl JOIN tracks ON tracks.id = tl.track_id
		WHERE tl.user_id::text = $1 AND tracks.owner_id = tl.user_id AND tracks.status = 'ready'
		ORDER BY tl.created_at DESC LIMIT $2
	`, userID, maxLiked)
	if err != nil {
		return nil, false, err
	}
	for rows.Next() {
		var song LikedSong
		if err := rows.Scan(append([]any{&song.LikedAt}, trackDestinations(&song.Track)...)...); err != nil {
			rows.Close()
			return nil, false, err
		}
		songs = append(songs, song)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, false, err
	}

	rows, err = l.pool.Query(ctx, `
		WITH `+liveEntries+`, liked AS (
			SELECT et.entry_id::text AS entry_id, max(tl.created_at) AS liked_at
			FROM track_likes tl
			JOIN tracks lt ON lt.id = tl.track_id
			JOIN store_entry_tracks et ON et.track_id = tl.track_id
			WHERE tl.user_id::text = $2 AND lt.owner_id::text <> $2
			GROUP BY et.entry_id
		)
		SELECT liked.liked_at, live.entry_id, live.copies, live.hidden_at IS NOT NULL, `+liveTrackColumns+`
		FROM liked JOIN live ON live.entry_id = liked.entry_id
		ORDER BY liked.liked_at DESC LIMIT $3
	`, false, userID, maxLiked)
	if err != nil {
		return nil, false, err
	}
	for rows.Next() {
		var song LikedSong
		entry := StoreEntry{}
		dest := append([]any{&song.LikedAt, &entry.ID, &entry.Copies, &entry.Hidden}, trackDestinations(&entry.Track)...)
		if err := rows.Scan(dest...); err != nil {
			rows.Close()
			return nil, false, err
		}
		song.Track, song.Entry = entry.Track, &entry
		songs = append(songs, song)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, false, err
	}

	sort.SliceStable(songs, func(i, j int) bool { return songs[i].LikedAt.After(songs[j].LikedAt) })
	if offset >= len(songs) {
		return []LikedSong{}, false, nil
	}
	songs = songs[offset:]
	if len(songs) > limit {
		return songs[:limit], true, nil
	}
	return songs, false, nil
}
