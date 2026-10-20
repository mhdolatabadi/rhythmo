package store

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Playlist struct {
	ID      string
	OwnerID string
	Name    string
	// ShareToken is set while the playlist is shared.
	ShareToken *string
	// IsPublic lists a shared playlist for everyone to discover; otherwise
	// only people with its link find it.
	IsPublic bool
	// PublicReview is ReviewPending while an unverified owner's request to
	// list it publicly waits for an admin (#322), ReviewRejected after an
	// admin turned it down, and nil otherwise.
	PublicReview *string
	// CollabToken is set while people can join the playlist by its
	// collaboration link; only the owner ever sees it.
	CollabToken *string
	CreatedAt   time.Time
	UpdatedAt   time.Time
	Tracks      []Track
	TrackCount  int
	// Members are the people besides the owner who can add tracks, and
	// OwnerEmail who owns it. Both are only loaded with the tracks.
	Members    []Member
	OwnerEmail string
}

// Member is someone who joined a playlist by its collaboration link.
type Member struct {
	UserID   string
	Email    string
	JoinedAt time.Time
}

// ErrForbidden means the user may see the playlist but not make the change,
// such as a member removing someone else's track.
var ErrForbidden = errors.New("not allowed")

// ErrShareTokenTaken means a newly drawn share token collided; draw again.
var ErrShareTokenTaken = errors.New("share token is already in use")

// playlistColumnNames is the one list of columns scanPlaylist reads, in order.
var playlistColumnNames = []string{"id::text", "owner_id::text", "name", "share_token", "is_public", "public_review", "collab_token", "created_at", "updated_at"}

var (
	playlistColumns          = strings.Join(playlistColumnNames, ", ")
	qualifiedPlaylistColumns = qualifyColumns("playlists", playlistColumnNames)
)

func scanPlaylist(row pgx.Row) (Playlist, error) {
	var p Playlist
	err := row.Scan(&p.ID, &p.OwnerID, &p.Name, &p.ShareToken, &p.IsPublic, &p.PublicReview, &p.CollabToken, &p.CreatedAt, &p.UpdatedAt)
	return p, err
}

// trackBelongs is true for a track that may be in playlist pl: its owner's,
// or a member's. Tracks of someone who left are removed when they leave;
// this checks it again.
func trackBelongs(tracks, pl string) string {
	return `(` + tracks + `.owner_id = ` + pl + `.owner_id OR EXISTS (
		SELECT 1 FROM playlist_members m WHERE m.playlist_id = ` + pl + `.id AND m.user_id = ` + tracks + `.owner_id))`
}

// canEdit is true when user $N owns playlist pl or is one of its members.
func canEdit(pl, user string) string {
	return `(` + pl + `.owner_id::text = ` + user + ` OR EXISTS (
		SELECT 1 FROM playlist_members m WHERE m.playlist_id = ` + pl + `.id AND m.user_id::text = ` + user + `))`
}

type Playlists struct {
	pool *pgxpool.Pool
}

func NewPlaylists(pool *pgxpool.Pool) *Playlists {
	return &Playlists{pool: pool}
}

// ListForUser lists the playlists the user owns or has joined, most
// recently changed first.
func (p *Playlists) ListForUser(ctx context.Context, userID string) ([]Playlist, error) {
	rows, err := p.pool.Query(ctx, `
		SELECT `+qualifiedPlaylistColumns+`,
			(SELECT count(*)::int
			 FROM playlist_tracks pt
			 JOIN tracks ON tracks.id = pt.track_id
			 WHERE pt.playlist_id = playlists.id
			   AND tracks.status = 'ready'
			   AND `+trackBelongs("tracks", "playlists")+`)
		FROM playlists
		WHERE `+canEdit("playlists", "$1")+`
		ORDER BY updated_at DESC, id
	`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	playlists := []Playlist{}
	for rows.Next() {
		var playlist Playlist
		if err := rows.Scan(
			&playlist.ID,
			&playlist.OwnerID,
			&playlist.Name,
			&playlist.ShareToken,
			&playlist.IsPublic,
			&playlist.PublicReview,
			&playlist.CollabToken,
			&playlist.CreatedAt,
			&playlist.UpdatedAt,
			&playlist.TrackCount,
		); err != nil {
			return nil, err
		}
		playlists = append(playlists, playlist)
	}
	return playlists, rows.Err()
}

// ForUser returns a playlist the user owns or has joined, with its tracks
// and members, or ErrNotFound.
func (p *Playlists) ForUser(ctx context.Context, userID, playlistID string) (Playlist, error) {
	playlist, err := scanPlaylist(p.pool.QueryRow(ctx, `
		SELECT `+qualifiedPlaylistColumns+`
		FROM playlists
		WHERE playlists.id::text = $1 AND `+canEdit("playlists", "$2")+`
	`, playlistID, userID))
	if errors.Is(err, pgx.ErrNoRows) {
		return Playlist{}, ErrNotFound
	}
	if err != nil {
		return Playlist{}, err
	}
	if playlist.Tracks, err = p.tracks(ctx, playlist); err != nil {
		return Playlist{}, err
	}
	if err := p.pool.QueryRow(ctx, `SELECT email FROM users WHERE id = $1::uuid`, playlist.OwnerID).Scan(&playlist.OwnerEmail); err != nil {
		return Playlist{}, err
	}
	playlist.Members, err = p.members(ctx, playlist.ID)
	return playlist, err
}

func (p *Playlists) members(ctx context.Context, playlistID string) ([]Member, error) {
	rows, err := p.pool.Query(ctx, `
		SELECT users.id::text, users.email, m.joined_at
		FROM playlist_members m JOIN users ON users.id = m.user_id
		WHERE m.playlist_id = $1::uuid
		ORDER BY m.joined_at, users.id
	`, playlistID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	members := []Member{}
	for rows.Next() {
		var m Member
		if err := rows.Scan(&m.UserID, &m.Email, &m.JoinedAt); err != nil {
			return nil, err
		}
		members = append(members, m)
	}
	return members, rows.Err()
}

// tracks lists the playlist's ready tracks in order: the owner's and its
// members' own tracks.
func (p *Playlists) tracks(ctx context.Context, playlist Playlist) ([]Track, error) {
	rows, err := p.pool.Query(ctx, `
		SELECT `+qualifiedTrackColumns("tracks")+`
		FROM playlist_tracks pt
		JOIN playlists ON playlists.id = pt.playlist_id
		JOIN tracks ON tracks.id = pt.track_id
		WHERE pt.playlist_id = $1::uuid AND tracks.status = 'ready' AND `+trackBelongs("tracks", "playlists")+`
		ORDER BY pt.position
	`, playlist.ID)
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

func (p *Playlists) Create(ctx context.Context, ownerID, name string) (Playlist, error) {
	return scanPlaylist(p.pool.QueryRow(ctx, `
		INSERT INTO playlists (owner_id, name)
		VALUES ($1::uuid, $2)
		RETURNING `+playlistColumns, ownerID, name))
}

func (p *Playlists) Rename(ctx context.Context, ownerID, playlistID, name string) (Playlist, error) {
	playlist, err := scanPlaylist(p.pool.QueryRow(ctx, `
		UPDATE playlists SET name = $3, updated_at = now()
		WHERE id::text = $1 AND owner_id::text = $2
		RETURNING `+playlistColumns, playlistID, ownerID, name))
	if errors.Is(err, pgx.ErrNoRows) {
		return Playlist{}, ErrNotFound
	}
	return playlist, err
}

// ReplaceTracks sets the playlist's tracks, in order. The owner and members
// may add their own ready tracks and reorder any; a track already in the
// playlist may only be taken out by the owner or by whoever added it.
// ErrNotFound covers a playlist the user can't see and a track they can't
// add; ErrForbidden a track they may not remove.
func (p *Playlists) ReplaceTracks(ctx context.Context, userID, playlistID string, trackIDs []string) error {
	return pgx.BeginFunc(ctx, p.pool, func(tx pgx.Tx) error {
		// Locking the playlist row serializes edits by several members.
		var ownerID string
		err := tx.QueryRow(ctx, `
			SELECT playlists.owner_id::text FROM playlists
			WHERE playlists.id::text = $1 AND `+canEdit("playlists", "$2")+`
			FOR UPDATE
		`, playlistID, userID).Scan(&ownerID)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}

		// Who owns each track the playlist has now.
		current := map[string]string{}
		rows, err := tx.Query(ctx, `
			SELECT pt.track_id::text, tracks.owner_id::text
			FROM playlist_tracks pt JOIN tracks ON tracks.id = pt.track_id
			WHERE pt.playlist_id = $1::uuid
		`, playlistID)
		if err != nil {
			return err
		}
		for rows.Next() {
			var trackID, trackOwner string
			if err := rows.Scan(&trackID, &trackOwner); err != nil {
				rows.Close()
				return err
			}
			current[trackID] = trackOwner
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return err
		}
		kept := make(map[string]bool, len(trackIDs))
		for _, id := range trackIDs {
			kept[id] = true
		}
		for trackID, trackOwner := range current {
			if !kept[trackID] && userID != ownerID && trackOwner != userID {
				return ErrForbidden
			}
		}

		if _, err := tx.Exec(ctx, `DELETE FROM playlist_tracks WHERE playlist_id = $1::uuid`, playlistID); err != nil {
			return err
		}
		for position, trackID := range trackIDs {
			// A track already in the playlist stays whoever added it; a new
			// one must be the caller's own.
			tag, err := tx.Exec(ctx, `
				INSERT INTO playlist_tracks (playlist_id, track_id, position)
				SELECT $1::uuid, id, $4
				FROM tracks
				WHERE id::text = $2 AND status = 'ready'
				  AND (owner_id::text = $3 OR (owner_id::text = $5 AND $6))
			`, playlistID, trackID, userID, position, current[trackID], current[trackID] != "")
			if err != nil {
				return err
			}
			if tag.RowsAffected() == 0 {
				return ErrNotFound
			}
		}
		_, err = tx.Exec(ctx, `UPDATE playlists SET updated_at = now() WHERE id = $1::uuid`, playlistID)
		return err
	})
}

func (p *Playlists) Delete(ctx context.Context, ownerID, playlistID string) error {
	tag, err := p.pool.Exec(ctx, `
		DELETE FROM playlists WHERE id::text = $1 AND owner_id::text = $2
	`, playlistID, ownerID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// Share makes the playlist shared with the given token, or keeps the token
// it already has, so sharing twice gives the same link. A non-nil public
// sets whether it is listed for everyone; nil keeps what it was. Without
// direct (an owner who is neither verified nor an admin, #322), listing a
// playlist that isn't public yet only asks for an admin's approval: it stays
// link-only with a pending review. Making it link-only withdraws a request.
func (p *Playlists) Share(ctx context.Context, ownerID, playlistID, token string, public *bool, direct bool) (Playlist, error) {
	playlist, err := scanPlaylist(p.pool.QueryRow(ctx, `
		UPDATE playlists SET share_token = COALESCE(share_token, $3),
			is_public = CASE WHEN $4::boolean IS NULL THEN is_public WHEN $4 THEN is_public OR $5 ELSE false END,
			public_review = CASE WHEN $4::boolean IS NULL THEN public_review
				WHEN $4 AND NOT $5 AND NOT is_public THEN 'pending' END,
			public_review_at = CASE WHEN $4::boolean IS NULL THEN public_review_at
				WHEN $4 AND NOT $5 AND NOT is_public
				THEN CASE WHEN public_review = 'pending' THEN public_review_at ELSE now() END END
		WHERE id::text = $1 AND owner_id::text = $2
		RETURNING `+playlistColumns, playlistID, ownerID, token, public, direct))
	var pgErr *pgconn.PgError
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		return Playlist{}, ErrNotFound
	case errors.As(err, &pgErr) && pgErr.Code == uniqueViolation:
		return Playlist{}, ErrShareTokenTaken
	}
	return playlist, err
}

// Unshare makes the playlist private; its link stops working for good and
// it is no longer listed, and a request to list it is withdrawn. Its likes
// are kept for if it is shared again.
func (p *Playlists) Unshare(ctx context.Context, ownerID, playlistID string) error {
	tag, err := p.pool.Exec(ctx, `
		UPDATE playlists SET share_token = NULL, is_public = false,
			public_review = NULL, public_review_at = NULL
		WHERE id::text = $1 AND owner_id::text = $2
	`, playlistID, ownerID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// SharedPlaylist is a playlist as someone with its link sees it.
type SharedPlaylist struct {
	Playlist
	OwnerEmail string
}

// ForShareToken returns the shared playlist and its tracks, or ErrNotFound
// when no playlist is shared with that token (never shared, or unshared).
func (p *Playlists) ForShareToken(ctx context.Context, token string) (SharedPlaylist, error) {
	var shared SharedPlaylist
	err := p.pool.QueryRow(ctx, `
		SELECT `+qualifiedPlaylistColumns+`, users.email
		FROM playlists JOIN users ON users.id = playlists.owner_id
		WHERE playlists.share_token = $1
	`, token).Scan(&shared.ID, &shared.OwnerID, &shared.Name, &shared.ShareToken,
		&shared.IsPublic, &shared.PublicReview, &shared.CollabToken, &shared.CreatedAt, &shared.UpdatedAt, &shared.OwnerEmail)
	if errors.Is(err, pgx.ErrNoRows) {
		return SharedPlaylist{}, ErrNotFound
	}
	if err != nil {
		return SharedPlaylist{}, err
	}
	shared.Tracks, err = p.tracks(ctx, shared.Playlist)
	return shared, err
}

// SharedTrack returns a ready track that is in the playlist shared with the
// token, or ErrNotFound. It is what lets someone with the link play it.
// With publicOnly, only a public playlist's tracks are found, for visitors
// without an account.
func (p *Playlists) SharedTrack(ctx context.Context, token, trackID string, publicOnly bool) (Track, error) {
	track, err := scanTrack(p.pool.QueryRow(ctx, `
		SELECT `+qualifiedTrackColumns("tracks")+`
		FROM playlists
		JOIN playlist_tracks pt ON pt.playlist_id = playlists.id
		JOIN tracks ON tracks.id = pt.track_id
		WHERE playlists.share_token = $1 AND tracks.id::text = $2
		  AND `+trackBelongs("tracks", "playlists")+` AND tracks.status = 'ready'
		  AND (playlists.is_public OR NOT $3)
	`, token, trackID, publicOnly))
	if errors.Is(err, pgx.ErrNoRows) {
		return Track{}, ErrNotFound
	}
	return track, err
}

// ErrOwnPlaylist means someone tried to save their own shared playlist.
var ErrOwnPlaylist = errors.New("the playlist is already yours")

// ObjectCopier copies and removes stored audio.
type ObjectCopier interface {
	Copy(ctx context.Context, srcKey, dstKey string) error
	Remove(ctx context.Context, key string) error
}

// SaveShared copies the playlist shared with token into the user's account:
// each of its tracks becomes the user's own track (its audio copied in
// storage), collected in a new playlist with the same name. The copies
// count against the user's quota; if they don't fit, nothing is copied.
// A failure part way removes what was copied so far.
func (p *Playlists) SaveShared(
	ctx context.Context, userID, token string, maxOwnerBytes int64, objects ObjectCopier,
) (Playlist, error) {
	shared, err := p.ForShareToken(ctx, token)
	if err != nil {
		return Playlist{}, err
	}
	if shared.OwnerID == userID {
		return Playlist{}, ErrOwnPlaylist
	}

	// Reserve every copy as pending under the quota, atomically.
	var copies []Track
	err = pgx.BeginFunc(ctx, p.pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`, userID); err != nil {
			return err
		}
		var used, needed int64
		if err := tx.QueryRow(ctx, `
			SELECT COALESCE(SUM(size_bytes), 0)::bigint FROM tracks WHERE owner_id::text = $1
		`, userID).Scan(&used); err != nil {
			return err
		}
		for _, t := range shared.Tracks {
			needed += t.SizeBytes
		}
		if used > maxOwnerBytes || needed > maxOwnerBytes-used {
			return ErrQuotaExceeded
		}
		for _, t := range shared.Tracks {
			copied, err := createTrack(ctx, tx, userID, NewTrack{
				Title: t.Title, Artist: t.Artist, Album: t.Album, DurationMS: t.DurationMS,
				FileName: t.FileName, ContentType: t.ContentType, SizeBytes: t.SizeBytes,
				Source: "shared",
			}, TrackPending)
			if err != nil {
				return err
			}
			copies = append(copies, copied)
		}
		return nil
	})
	if err != nil {
		return Playlist{}, err
	}

	discard := func(done int) {
		cleanup := context.WithoutCancel(ctx)
		for _, c := range copies[:done] {
			_ = objects.Remove(cleanup, c.StorageKey)
		}
		for _, c := range copies {
			_, _ = p.pool.Exec(cleanup, `DELETE FROM tracks WHERE id::text = $1 AND status = 'pending'`, c.ID)
		}
	}
	for i, c := range copies {
		if err := objects.Copy(ctx, shared.Tracks[i].StorageKey, c.StorageKey); err != nil {
			discard(i)
			return Playlist{}, fmt.Errorf("copy track audio: %w", err)
		}
	}

	var saved Playlist
	err = pgx.BeginFunc(ctx, p.pool, func(tx pgx.Tx) error {
		var err error
		saved, err = scanPlaylist(tx.QueryRow(ctx, `
			INSERT INTO playlists (owner_id, name) VALUES ($1::uuid, $2)
			RETURNING `+playlistColumns, userID, shared.Name))
		if err != nil {
			return err
		}
		for i, c := range copies {
			if _, err := tx.Exec(ctx, `UPDATE tracks SET status = 'ready' WHERE id::text = $1`, c.ID); err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, `
				INSERT INTO playlist_tracks (playlist_id, track_id, position) VALUES ($1::uuid, $2::uuid, $3)
			`, saved.ID, c.ID, i); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		discard(len(copies))
		return Playlist{}, err
	}
	saved.Tracks, err = p.tracks(ctx, saved)
	return saved, err
}

// Likes is a shared playlist's like count and whether one user likes it.
type Likes struct {
	Count int
	Liked bool
}

// LikesFor returns the playlist's likes as userID sees them.
func (p *Playlists) LikesFor(ctx context.Context, playlistID, userID string) (Likes, error) {
	var likes Likes
	err := p.pool.QueryRow(ctx, `
		SELECT count(*)::int, COALESCE(bool_or(user_id::text = $2), false)
		FROM playlist_likes WHERE playlist_id = $1::uuid
	`, playlistID, userID).Scan(&likes.Count, &likes.Liked)
	return likes, err
}

// SetLike likes or unlikes the playlist shared with token for the user and
// returns its likes after. Doing it twice is the same as once. It is
// ErrNotFound when no playlist is shared with the token.
func (p *Playlists) SetLike(ctx context.Context, userID, token string, liked bool) (Likes, error) {
	var likes Likes
	err := pgx.BeginFunc(ctx, p.pool, func(tx pgx.Tx) error {
		// Holding the row keeps it shared until the like is in.
		var playlistID string
		err := tx.QueryRow(ctx, `
			SELECT id::text FROM playlists WHERE share_token = $1 FOR SHARE
		`, token).Scan(&playlistID)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		if liked {
			_, err = tx.Exec(ctx, `
				INSERT INTO playlist_likes (playlist_id, user_id) VALUES ($1::uuid, $2::uuid)
				ON CONFLICT DO NOTHING
			`, playlistID, userID)
		} else {
			_, err = tx.Exec(ctx, `
				DELETE FROM playlist_likes WHERE playlist_id = $1::uuid AND user_id::text = $2
			`, playlistID, userID)
		}
		if err != nil {
			return err
		}
		return tx.QueryRow(ctx, `
			SELECT count(*)::int FROM playlist_likes WHERE playlist_id = $1::uuid
		`, playlistID).Scan(&likes.Count)
	})
	likes.Liked = liked
	return likes, err
}

// PublicPlaylist is a public playlist as it is listed for discovery.
type PublicPlaylist struct {
	ShareToken string
	Name       string
	OwnerID    string
	OwnerEmail string
	TrackCount int
	Likes      Likes
	UpdatedAt  time.Time
}

// Popular lists up to limit public shared playlists, most liked first;
// ties go to the most recently updated, then by id, so the order is stable.
// Link-only playlists, and ones an admin took out, are never listed.
func (p *Playlists) Popular(ctx context.Context, userID string, limit int) ([]PublicPlaylist, error) {
	rows, err := p.pool.Query(ctx, `
		SELECT playlists.share_token, playlists.name, playlists.owner_id::text, users.email,
			(SELECT count(*)::int FROM playlist_tracks pt JOIN tracks ON tracks.id = pt.track_id
			 WHERE pt.playlist_id = playlists.id AND `+trackBelongs("tracks", "playlists")+`
			   AND tracks.status = 'ready'),
			likes.count, likes.liked, playlists.updated_at
		FROM playlists
		JOIN users ON users.id = playlists.owner_id
		CROSS JOIN LATERAL (
			SELECT count(*)::int AS count, COALESCE(bool_or(user_id::text = $1), false) AS liked
			FROM playlist_likes WHERE playlist_id = playlists.id
		) likes
		WHERE playlists.is_public AND playlists.share_token IS NOT NULL
		  AND playlists.popular_hidden_at IS NULL
		ORDER BY likes.count DESC, playlists.updated_at DESC, playlists.id
		LIMIT $2
	`, userID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	listed := []PublicPlaylist{}
	for rows.Next() {
		var pp PublicPlaylist
		if err := rows.Scan(&pp.ShareToken, &pp.Name, &pp.OwnerID, &pp.OwnerEmail, &pp.TrackCount,
			&pp.Likes.Count, &pp.Likes.Liked, &pp.UpdatedAt); err != nil {
			return nil, err
		}
		listed = append(listed, pp)
	}
	return listed, rows.Err()
}

// SetPopularHidden takes the public playlist shared with token out of the
// popular list, or puts it back, for the admin actorID. The playlist and its
// link stay as they are. It is ErrNotFound when no playlist is shared with
// token; setting the state it already has changes nothing.
func (p *Playlists) SetPopularHidden(ctx context.Context, token, actorID string, hidden bool) error {
	return pgx.BeginFunc(ctx, p.pool, func(tx pgx.Tx) error {
		var playlistID string
		var wasHidden bool
		err := tx.QueryRow(ctx, `
			SELECT id::text, popular_hidden_at IS NOT NULL FROM playlists
			WHERE share_token = $1 FOR UPDATE
		`, token).Scan(&playlistID, &wasHidden)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil || wasHidden == hidden {
			return err
		}
		if _, err := tx.Exec(ctx, `
			UPDATE playlists SET
				popular_hidden_at = CASE WHEN $2 THEN now() ELSE NULL END,
				popular_hidden_by = CASE WHEN $2 THEN $3::uuid ELSE NULL END
			WHERE id = $1::uuid
		`, playlistID, hidden, actorID); err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `
			INSERT INTO popular_playlist_audit (playlist_id, actor_id, hidden)
			VALUES ($1::uuid, $2::uuid, $3)
		`, playlistID, actorID, hidden)
		return err
	})
}

// DeleteShared deletes the playlist shared with token for the admin
// actorID, whoever owns it, and records what was deleted. The tracks stay
// in their owners' libraries. It is ErrNotFound when no playlist is shared
// with token.
func (p *Playlists) DeleteShared(ctx context.Context, token, actorID string) error {
	return pgx.BeginFunc(ctx, p.pool, func(tx pgx.Tx) error {
		var playlistID, ownerID, name string
		err := tx.QueryRow(ctx, `
			DELETE FROM playlists WHERE share_token = $1
			RETURNING id::text, owner_id::text, name
		`, token).Scan(&playlistID, &ownerID, &name)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `
			INSERT INTO playlist_deletion_audit (playlist_id, owner_id, name, actor_id)
			VALUES ($1::uuid, $2::uuid, $3, $4::uuid)
		`, playlistID, ownerID, name, actorID)
		return err
	})
}

// SetCollabToken turns the playlist's collaboration link on with token, or
// off with nil. Each new token replaces the old one, so an old link stops
// working; members who already joined stay. Only the owner may do it.
func (p *Playlists) SetCollabToken(ctx context.Context, ownerID, playlistID string, token *string) (Playlist, error) {
	playlist, err := scanPlaylist(p.pool.QueryRow(ctx, `
		UPDATE playlists SET collab_token = $3
		WHERE id::text = $1 AND owner_id::text = $2
		RETURNING `+playlistColumns, playlistID, ownerID, token))
	var pgErr *pgconn.PgError
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		return Playlist{}, ErrNotFound
	case errors.As(err, &pgErr) && pgErr.Code == uniqueViolation:
		return Playlist{}, ErrShareTokenTaken
	}
	return playlist, err
}

// Join makes the user a member of the playlist whose collaboration link has
// token and returns it. Joining again, or joining one's own playlist, changes
// nothing. It is ErrNotFound when no playlist has that link.
func (p *Playlists) Join(ctx context.Context, userID, token string) (Playlist, error) {
	var playlistID string
	err := pgx.BeginFunc(ctx, p.pool, func(tx pgx.Tx) error {
		var ownerID string
		err := tx.QueryRow(ctx, `
			SELECT id::text, owner_id::text FROM playlists WHERE collab_token = $1 FOR SHARE
		`, token).Scan(&playlistID, &ownerID)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil || ownerID == userID {
			return err
		}
		_, err = tx.Exec(ctx, `
			INSERT INTO playlist_members (playlist_id, user_id) VALUES ($1::uuid, $2::uuid)
			ON CONFLICT DO NOTHING
		`, playlistID, userID)
		return err
	})
	if err != nil {
		return Playlist{}, err
	}
	return p.ForUser(ctx, userID, playlistID)
}

// RemoveMember takes memberID out of the playlist, with the tracks they
// added. The owner may remove anyone; a member may only remove themselves,
// which is leaving. ErrNotFound covers a playlist the actor can't see and
// someone who isn't a member.
func (p *Playlists) RemoveMember(ctx context.Context, actorID, playlistID, memberID string) error {
	return pgx.BeginFunc(ctx, p.pool, func(tx pgx.Tx) error {
		var ownerID string
		err := tx.QueryRow(ctx, `
			SELECT playlists.owner_id::text FROM playlists
			WHERE playlists.id::text = $1 AND `+canEdit("playlists", "$2")+`
			FOR UPDATE
		`, playlistID, actorID).Scan(&ownerID)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		if actorID != ownerID && actorID != memberID {
			return ErrForbidden
		}
		tag, err := tx.Exec(ctx, `
			DELETE FROM playlist_members WHERE playlist_id = $1::uuid AND user_id::text = $2
		`, playlistID, memberID)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return ErrNotFound
		}
		if _, err := tx.Exec(ctx, `
			DELETE FROM playlist_tracks pt USING tracks
			WHERE pt.playlist_id = $1::uuid AND tracks.id = pt.track_id AND tracks.owner_id::text = $2
		`, playlistID, memberID); err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `UPDATE playlists SET updated_at = now() WHERE id = $1::uuid`, playlistID)
		return err
	})
}

// PlaylistTrack returns a ready track in a playlist the user owns or has
// joined, so members can play each other's tracks; otherwise ErrNotFound.
func (p *Playlists) PlaylistTrack(ctx context.Context, userID, playlistID, trackID string) (Track, error) {
	track, err := scanTrack(p.pool.QueryRow(ctx, `
		SELECT `+qualifiedTrackColumns("tracks")+`
		FROM playlists
		JOIN playlist_tracks pt ON pt.playlist_id = playlists.id
		JOIN tracks ON tracks.id = pt.track_id
		WHERE playlists.id::text = $1 AND tracks.id::text = $3 AND tracks.status = 'ready'
		  AND `+canEdit("playlists", "$2")+` AND `+trackBelongs("tracks", "playlists")+`
	`, playlistID, userID, trackID))
	if errors.Is(err, pgx.ErrNoRows) {
		return Track{}, ErrNotFound
	}
	return track, err
}
