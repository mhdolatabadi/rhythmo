package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Errors of public profiles (#228).
var (
	ErrHandleTaken = errors.New("handle is taken")
	// ErrNoHandle means a profile can't be made public without a handle.
	ErrNoHandle = errors.New("profile has no handle")
	// ErrBlocked means one of the two users blocked the other.
	ErrBlocked = errors.New("blocked")
	// ErrAlreadyReported means the reporter has an open report on the
	// profile already.
	ErrAlreadyReported = errors.New("already reported")
)

// PublicationProfile is the review kind of a public profile.
const PublicationProfile = "profile"

// MyProfile is the owner's own view of their profile.
type MyProfile struct {
	Handle       string
	DisplayName  string
	Bio          string
	Public       bool
	Review       *string
	HideActivity bool
	HasAvatar    bool
	Followers    int
	Following    int
}

// ProfileUpdate is what the owner changes on their profile.
type ProfileUpdate struct {
	// Handle and Bio are "" to clear them.
	Handle       string
	DisplayName  string
	Bio          string
	Public       bool
	HideActivity bool
}

// Profile is a public profile as someone else sees it.
type Profile struct {
	UserID      string
	Handle      string
	DisplayName string
	Bio         string
	Verified    bool
	HasAvatar   bool
	AvatarAt    time.Time
	Followers   int
	Following   int
	CreatedAt   time.Time
	// Viewer's relation to it; false for a visitor.
	FollowedByViewer bool
	BlockedByViewer  bool
	IsViewer         bool
}

// ProfilePlaylist is one public playlist on a profile.
type ProfilePlaylist struct {
	ID         string
	ShareToken string
	Name       string
	TrackCount int
	UpdatedAt  time.Time
}

// FeedItem is one thing someone the viewer follows did: made a playlist
// public, or liked a song in the store.
type FeedItem struct {
	Kind string // "playlist" or "like"
	At   time.Time
	// ID is the playlist's or the liked track's id; it orders items that
	// happened at the same time.
	ID          string
	ActorHandle string
	ActorName   string
	// A playlist's share token and name, or a liked song's store entry,
	// title and artist.
	ShareToken string
	Name       string
	EntryID    string
	Artist     string
}

// FeedCursor is where a page of the feed starts: before this item.
type FeedCursor struct {
	At   time.Time
	Kind string
	ID   string
}

// ProfileReport is an open report as an admin reviews it.
type ProfileReport struct {
	ID          string
	Handle      string
	DisplayName string
	Bio         string
	Reason      string
	Details     *string
	Reports     int
	CreatedAt   time.Time
}

// Profiles keeps public profiles, follows, blocks and their reports.
type Profiles struct {
	pool *pgxpool.Pool
}

func NewProfiles(pool *pgxpool.Pool) *Profiles {
	return &Profiles{pool: pool}
}

// visibleProfile is true for a profile anyone may see: public, approved,
// with a handle.
func visibleProfile(users string) string {
	return `(` + users + `.profile_public AND ` + users + `.profile_review IS NULL AND ` + users + `.handle IS NOT NULL)`
}

// noBlock is true when neither the user whose id column is user nor the
// account whose id is the text viewer blocked the other.
func noBlock(user, viewer string) string {
	return `NOT EXISTS (SELECT 1 FROM user_blocks ub WHERE (ub.blocker_id = ` + user + ` AND ub.blocked_id::text = ` + viewer + `)
		OR (ub.blocked_id = ` + user + ` AND ub.blocker_id::text = ` + viewer + `))`
}

// Mine returns the owner's own profile.
func (p *Profiles) Mine(ctx context.Context, userID string) (MyProfile, error) {
	var me MyProfile
	err := p.pool.QueryRow(ctx, `
		SELECT COALESCE(handle, ''), COALESCE(display_name, ''), COALESCE(bio, ''), profile_public,
			profile_review, hide_activity,
			EXISTS (SELECT 1 FROM user_avatars WHERE user_id = users.id),
			(SELECT count(*)::int FROM user_follows WHERE followee_id = users.id),
			(SELECT count(*)::int FROM user_follows WHERE follower_id = users.id)
		FROM users WHERE id::text = $1
	`, userID).Scan(&me.Handle, &me.DisplayName, &me.Bio, &me.Public, &me.Review, &me.HideActivity,
		&me.HasAvatar, &me.Followers, &me.Following)
	if errors.Is(err, pgx.ErrNoRows) {
		return MyProfile{}, ErrNotFound
	}
	return me, err
}

// Update changes the owner's profile. Without direct (an owner who is
// neither verified nor an admin), a public profile whose handle, name or
// bio changed, or that was just made public, waits for an admin again.
func (p *Profiles) Update(ctx context.Context, userID string, update ProfileUpdate, direct bool) (MyProfile, error) {
	if update.Public && update.Handle == "" {
		return MyProfile{}, ErrNoHandle
	}
	tag, err := p.pool.Exec(ctx, `
		UPDATE users SET
			handle = NULLIF($2, ''), display_name = NULLIF($3, ''), bio = NULLIF($4, ''),
			profile_public = $5, hide_activity = $6,
			profile_review = CASE
				WHEN NOT $5 OR $7 THEN NULL
				WHEN profile_review = 'pending' THEN 'pending'
				WHEN NOT profile_public OR handle IS DISTINCT FROM NULLIF($2, '')
					OR display_name IS DISTINCT FROM NULLIF($3, '') OR bio IS DISTINCT FROM NULLIF($4, '')
					OR profile_review = 'rejected'
				THEN 'pending' END,
			profile_review_at = CASE
				WHEN NOT $5 OR $7 THEN NULL
				WHEN profile_review = 'pending' THEN profile_review_at
				WHEN NOT profile_public OR handle IS DISTINCT FROM NULLIF($2, '')
					OR display_name IS DISTINCT FROM NULLIF($3, '') OR bio IS DISTINCT FROM NULLIF($4, '')
					OR profile_review = 'rejected'
				THEN now() END
		WHERE id::text = $1
	`, userID, update.Handle, update.DisplayName, update.Bio, update.Public, update.HideActivity, direct)
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == uniqueViolation {
		return MyProfile{}, ErrHandleTaken
	}
	if err != nil {
		return MyProfile{}, err
	}
	if tag.RowsAffected() == 0 {
		return MyProfile{}, ErrNotFound
	}
	return p.Mine(ctx, userID)
}

// SetAvatar replaces the owner's avatar; nil data removes it. A new avatar
// on a public profile of an owner without direct waits for an admin.
func (p *Profiles) SetAvatar(ctx context.Context, userID, contentType string, data []byte, direct bool) error {
	return pgx.BeginFunc(ctx, p.pool, func(tx pgx.Tx) error {
		if data == nil {
			_, err := tx.Exec(ctx, `DELETE FROM user_avatars WHERE user_id::text = $1`, userID)
			return err
		}
		if _, err := tx.Exec(ctx, `
			INSERT INTO user_avatars (user_id, content_type, data) VALUES ($1::uuid, $2, $3)
			ON CONFLICT (user_id) DO UPDATE SET content_type = $2, data = $3, updated_at = now()
		`, userID, contentType, data); err != nil {
			return err
		}
		if direct {
			return nil
		}
		_, err := tx.Exec(ctx, `
			UPDATE users SET profile_review = 'pending',
				profile_review_at = CASE WHEN profile_review = 'pending' THEN profile_review_at ELSE now() END
			WHERE id::text = $1 AND profile_public
		`, userID)
		return err
	})
}

// Avatar returns a visible profile's avatar, or the viewer's own.
func (p *Profiles) Avatar(ctx context.Context, handle, viewerID string) (contentType string, data []byte, at time.Time, err error) {
	err = p.pool.QueryRow(ctx, `
		SELECT a.content_type, a.data, a.updated_at
		FROM users JOIN user_avatars a ON a.user_id = users.id
		WHERE users.handle = $1
		  AND (users.id::text = $2 OR (`+visibleProfile("users")+` AND ($2 = '' OR `+noBlock("users.id", "$2")+`)))
	`, handle, viewerID).Scan(&contentType, &data, &at)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", nil, time.Time{}, ErrNotFound
	}
	return contentType, data, at, err
}

// PendingAvatar returns the avatar of a profile waiting for review, so an
// admin can look at it first.
func (p *Profiles) PendingAvatar(ctx context.Context, userID string) (contentType string, data []byte, err error) {
	err = p.pool.QueryRow(ctx, `
		SELECT a.content_type, a.data FROM users JOIN user_avatars a ON a.user_id = users.id
		WHERE users.id::text = $1 AND users.profile_review = 'pending'
	`, userID).Scan(&contentType, &data)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", nil, ErrNotFound
	}
	return contentType, data, err
}

// ByHandle returns a profile as viewerID ("" for a visitor) sees it. A
// hidden profile, or one whose owner blocked the viewer, is ErrNotFound;
// one the viewer blocked is shown, so they can unblock it.
func (p *Profiles) ByHandle(ctx context.Context, handle, viewerID string) (Profile, error) {
	var profile Profile
	var avatarAt *time.Time
	err := p.pool.QueryRow(ctx, `
		SELECT users.id::text, users.handle, COALESCE(users.display_name, ''), COALESCE(users.bio, ''),
			users.verified, a.updated_at, users.created_at,
			(SELECT count(*)::int FROM user_follows WHERE followee_id = users.id),
			(SELECT count(*)::int FROM user_follows WHERE follower_id = users.id),
			$2 <> '' AND EXISTS (SELECT 1 FROM user_follows WHERE followee_id = users.id AND follower_id::text = $2),
			$2 <> '' AND EXISTS (SELECT 1 FROM user_blocks WHERE blocked_id = users.id AND blocker_id::text = $2),
			users.id::text = $2
		FROM users LEFT JOIN user_avatars a ON a.user_id = users.id
		WHERE users.handle = $1 AND (users.id::text = $2 OR `+visibleProfile("users")+`)
		  AND ($2 = '' OR NOT EXISTS (SELECT 1 FROM user_blocks
			WHERE blocker_id = users.id AND blocked_id::text = $2))
	`, handle, viewerID).Scan(&profile.UserID, &profile.Handle, &profile.DisplayName, &profile.Bio,
		&profile.Verified, &avatarAt, &profile.CreatedAt, &profile.Followers, &profile.Following,
		&profile.FollowedByViewer, &profile.BlockedByViewer, &profile.IsViewer)
	if errors.Is(err, pgx.ErrNoRows) {
		return Profile{}, ErrNotFound
	}
	if avatarAt != nil {
		profile.HasAvatar, profile.AvatarAt = true, *avatarAt
	}
	return profile, err
}

// Playlists lists up to limit of the user's public playlists, newest first.
func (p *Profiles) Playlists(ctx context.Context, userID string, limit int) ([]ProfilePlaylist, error) {
	rows, err := p.pool.Query(ctx, `
		SELECT pl.id::text, pl.share_token, pl.name,
			(SELECT count(*)::int FROM playlist_tracks pt JOIN tracks ON tracks.id = pt.track_id
			 WHERE pt.playlist_id = pl.id AND `+trackBelongs("tracks", "pl")+` AND tracks.status = 'ready'),
			pl.updated_at
		FROM playlists pl
		WHERE pl.owner_id::text = $1 AND pl.is_public AND pl.share_token IS NOT NULL
		ORDER BY pl.public_since DESC NULLS LAST, pl.id
		LIMIT $2
	`, userID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	lists := []ProfilePlaylist{}
	for rows.Next() {
		var pl ProfilePlaylist
		if err := rows.Scan(&pl.ID, &pl.ShareToken, &pl.Name, &pl.TrackCount, &pl.UpdatedAt); err != nil {
			return nil, err
		}
		lists = append(lists, pl)
	}
	return lists, rows.Err()
}

// Listed returns up to limit visible profiles' handles with when they last
// changed, for the sitemap.
func (p *Profiles) Listed(ctx context.Context, limit int) ([]Profile, error) {
	rows, err := p.pool.Query(ctx, `
		SELECT handle, created_at FROM users WHERE `+visibleProfile("users")+`
		ORDER BY created_at, handle LIMIT $1
	`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	profiles := []Profile{}
	for rows.Next() {
		var profile Profile
		if err := rows.Scan(&profile.Handle, &profile.CreatedAt); err != nil {
			return nil, err
		}
		profiles = append(profiles, profile)
	}
	return profiles, rows.Err()
}

// Follow makes followerID follow the visible profile handle. Following
// someone either of them blocked is ErrBlocked; following oneself or a
// hidden profile is ErrNotFound.
func (p *Profiles) Follow(ctx context.Context, followerID, handle string) error {
	return pgx.BeginFunc(ctx, p.pool, func(tx pgx.Tx) error {
		var followeeID string
		var blocked bool
		err := tx.QueryRow(ctx, `
			SELECT id::text, NOT `+noBlock("users.id", "$2")+`
			FROM users WHERE handle = $1 AND id::text <> $2 AND `+visibleProfile("users")+`
		`, handle, followerID).Scan(&followeeID, &blocked)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		if blocked {
			return ErrBlocked
		}
		_, err = tx.Exec(ctx, `
			INSERT INTO user_follows (follower_id, followee_id) VALUES ($1::uuid, $2::uuid)
			ON CONFLICT DO NOTHING
		`, followerID, followeeID)
		return err
	})
}

// Unfollow stops following handle; not following is not an error.
func (p *Profiles) Unfollow(ctx context.Context, followerID, handle string) error {
	_, err := p.pool.Exec(ctx, `
		DELETE FROM user_follows WHERE follower_id::text = $1
		  AND followee_id = (SELECT id FROM users WHERE handle = $2)
	`, followerID, handle)
	return err
}

// Block blocks handle, which also ends follows in both directions. The
// profile need not be visible: a blocked user may hide theirs.
func (p *Profiles) Block(ctx context.Context, blockerID, handle string) error {
	return pgx.BeginFunc(ctx, p.pool, func(tx pgx.Tx) error {
		var blockedID string
		err := tx.QueryRow(ctx, `SELECT id::text FROM users WHERE handle = $1 AND id::text <> $2`,
			handle, blockerID).Scan(&blockedID)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `
			INSERT INTO user_blocks (blocker_id, blocked_id) VALUES ($1::uuid, $2::uuid)
			ON CONFLICT DO NOTHING
		`, blockerID, blockedID); err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `
			DELETE FROM user_follows WHERE (follower_id = $1::uuid AND followee_id = $2::uuid)
				OR (follower_id = $2::uuid AND followee_id = $1::uuid)
		`, blockerID, blockedID)
		return err
	})
}

// Unblock lifts a block; not blocking is not an error.
func (p *Profiles) Unblock(ctx context.Context, blockerID, handle string) error {
	_, err := p.pool.Exec(ctx, `
		DELETE FROM user_blocks WHERE blocker_id::text = $1
		  AND blocked_id = (SELECT id FROM users WHERE handle = $2)
	`, blockerID, handle)
	return err
}

// Blocked lists the handles and names the user blocked, newest first.
func (p *Profiles) Blocked(ctx context.Context, blockerID string) ([]Profile, error) {
	rows, err := p.pool.Query(ctx, `
		SELECT users.handle, COALESCE(users.display_name, '')
		FROM user_blocks ub JOIN users ON users.id = ub.blocked_id
		WHERE ub.blocker_id::text = $1 AND users.handle IS NOT NULL
		ORDER BY ub.created_at DESC
	`, blockerID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	blocked := []Profile{}
	for rows.Next() {
		var profile Profile
		if err := rows.Scan(&profile.Handle, &profile.DisplayName); err != nil {
			return nil, err
		}
		blocked = append(blocked, profile)
	}
	return blocked, rows.Err()
}

// Report records reporterID's «گزارش» about the visible profile handle.
func (p *Profiles) Report(ctx context.Context, reporterID, handle, reason string, details *string) error {
	tag, err := p.pool.Exec(ctx, `
		INSERT INTO profile_reports (reported_id, reporter_id, reason, details)
		SELECT id, $2::uuid, $3, $4 FROM users
		WHERE handle = $1 AND id <> $2::uuid AND `+visibleProfile("users")+`
	`, handle, reporterID, reason, details)
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == uniqueViolation {
		return ErrAlreadyReported
	}
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// OpenReports lists up to limit profiles with open reports, oldest report
// first, each with its latest reason. Reporters are not included.
func (p *Profiles) OpenReports(ctx context.Context, limit int) ([]ProfileReport, error) {
	rows, err := p.pool.Query(ctx, `
		SELECT * FROM (
			SELECT DISTINCT ON (r.reported_id) r.reported_id::text, COALESCE(users.handle, ''),
				COALESCE(users.display_name, ''), COALESCE(users.bio, ''), r.reason, r.details,
				count(*) OVER (PARTITION BY r.reported_id)::int AS reports,
				min(r.created_at) OVER (PARTITION BY r.reported_id) AS first_at
			FROM profile_reports r JOIN users ON users.id = r.reported_id
			WHERE r.resolved_at IS NULL
			ORDER BY r.reported_id, r.created_at DESC
		) open ORDER BY first_at, 1 LIMIT $1
	`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	reports := []ProfileReport{}
	for rows.Next() {
		var report ProfileReport
		if err := rows.Scan(&report.ID, &report.Handle, &report.DisplayName, &report.Bio, &report.Reason,
			&report.Details, &report.Reports, &report.CreatedAt); err != nil {
			return nil, err
		}
		reports = append(reports, report)
	}
	return reports, rows.Err()
}

// ResolveReports closes every open report on the user. With hide, the
// profile is also taken down: it goes back to private with a rejected
// review, which its owner sees.
func (p *Profiles) ResolveReports(ctx context.Context, userID, adminID string, hide bool) error {
	return pgx.BeginFunc(ctx, p.pool, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `
			UPDATE profile_reports SET resolved_at = now(), resolved_by = $2::uuid
			WHERE reported_id::text = $1 AND resolved_at IS NULL
		`, userID, adminID)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return ErrNotFound
		}
		if !hide {
			return nil
		}
		_, err = tx.Exec(ctx, `
			UPDATE users SET profile_public = false, profile_review = 'rejected', profile_review_at = now()
			WHERE id::text = $1
		`, userID)
		return err
	})
}

// Feed is a page of what the people viewerID follows did, newest first:
// playlists they made public and store songs they liked. People who hide
// their activity, hidden profiles and blocked ones are left out.
func (p *Profiles) Feed(ctx context.Context, viewerID string, before *FeedCursor, limit int) ([]FeedItem, error) {
	var at *time.Time
	var kind, id string
	if before != nil {
		at, kind, id = &before.At, before.Kind, before.ID
	}
	rows, err := p.pool.Query(ctx, `
		WITH actors AS (
			SELECT users.id, users.handle, COALESCE(users.display_name, '') AS name
			FROM user_follows f JOIN users ON users.id = f.followee_id
			WHERE f.follower_id::text = $1 AND NOT users.hide_activity
			  AND `+visibleProfile("users")+` AND `+noBlock("users.id", "$1")+`
		), items AS (
			SELECT 'playlist' AS kind, pl.public_since AS at, pl.id::text AS id, a.handle, a.name,
				pl.share_token, pl.name AS title, '' AS entry_id, '' AS artist
			FROM actors a JOIN playlists pl ON pl.owner_id = a.id
			WHERE pl.is_public AND pl.share_token IS NOT NULL AND pl.public_since IS NOT NULL
			UNION ALL
			SELECT 'like', l.created_at, tracks.id::text, a.handle, a.name,
				'', tracks.title, et.entry_id::text, COALESCE(tracks.artist, '')
			FROM actors a JOIN track_likes l ON l.user_id = a.id
			JOIN tracks ON tracks.id = l.track_id
			JOIN store_entry_tracks et ON et.track_id = tracks.id
			JOIN store_entries e ON e.id = et.entry_id AND e.hidden_at IS NULL
			WHERE `+storeEligible("tracks")+`
		)
		SELECT kind, at, id, handle, name, share_token, title, entry_id, artist FROM items
		WHERE $2::timestamptz IS NULL OR (at, kind, id) < ($2, $3, $4)
		ORDER BY at DESC, kind DESC, id DESC
		LIMIT $5
	`, viewerID, at, kind, id, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []FeedItem{}
	for rows.Next() {
		var item FeedItem
		if err := rows.Scan(&item.Kind, &item.At, &item.ID, &item.ActorHandle, &item.ActorName,
			&item.ShareToken, &item.Name, &item.EntryID, &item.Artist); err != nil {
			return nil, err
		}
		items = append(items, item)
	}
	return items, rows.Err()
}

// ReviewProfile approves a pending profile, which shows it, or rejects it,
// which takes it back to private. The decision is audited.
func (p *Publications) ReviewProfile(ctx context.Context, userID, actorID string, approve bool) error {
	return p.review(ctx, PublicationProfile, `
		UPDATE users SET
			profile_public = profile_public AND $2,
			profile_review = CASE WHEN $2 THEN NULL ELSE 'rejected' END,
			profile_review_at = CASE WHEN $2 THEN NULL ELSE now() END
		WHERE id::text = $1 AND profile_review = 'pending' AND profile_public
		RETURNING id::text
	`, userID, actorID, approve)
}
