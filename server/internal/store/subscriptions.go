package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Subscription is a public playlist's subscriber count and whether one user
// is subscribed, the way a channel shows its members (#414).
type Subscription struct {
	Count      int
	Subscribed bool
	// Muted is whether the user muted the channel (#428): its notices stay
	// in the inbox, but don't count as unread and aren't pushed.
	Muted bool
}

// SubscriptionFor returns the playlist's subscription as userID sees it.
func (p *Playlists) SubscriptionFor(ctx context.Context, playlistID, userID string) (Subscription, error) {
	var s Subscription
	err := p.pool.QueryRow(ctx, `
		SELECT count(*)::int, COALESCE(bool_or(user_id::text = $2), false),
			COALESCE(bool_or(user_id::text = $2 AND muted_at IS NOT NULL), false)
		FROM playlist_subscriptions WHERE playlist_id = $1::uuid
	`, playlistID, userID).Scan(&s.Count, &s.Subscribed, &s.Muted)
	return s, err
}

// SetSubscription subscribes the user to the public playlist shared with
// token, or unsubscribes them, and returns its subscription after. Doing it
// twice is the same as once. Subscribing is ErrNotFound unless the playlist
// is shared and public, and ErrOwnPlaylist for its owner; unsubscribing
// works however the playlist changed since.
func (p *Playlists) SetSubscription(ctx context.Context, userID, token string, subscribed bool) (Subscription, error) {
	var s Subscription
	err := pgx.BeginFunc(ctx, p.pool, func(tx pgx.Tx) error {
		var playlistID, ownerID string
		var public bool
		err := tx.QueryRow(ctx, `
			SELECT id::text, owner_id::text, is_public FROM playlists WHERE share_token = $1 FOR SHARE
		`, token).Scan(&playlistID, &ownerID, &public)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		if subscribed {
			if !public {
				return ErrNotFound
			}
			if ownerID == userID {
				return ErrOwnPlaylist
			}
			_, err = tx.Exec(ctx, `
				INSERT INTO playlist_subscriptions (playlist_id, user_id) VALUES ($1::uuid, $2::uuid)
				ON CONFLICT DO NOTHING
			`, playlistID, userID)
		} else {
			_, err = tx.Exec(ctx, `
				DELETE FROM playlist_subscriptions WHERE playlist_id = $1::uuid AND user_id::text = $2
			`, playlistID, userID)
			if err == nil {
				// Notices from a playlist one left are no longer wanted.
				_, err = tx.Exec(ctx, `
					DELETE FROM playlist_notifications WHERE playlist_id = $1::uuid AND user_id::text = $2
				`, playlistID, userID)
			}
		}
		if err != nil {
			return err
		}
		return tx.QueryRow(ctx, `
			SELECT count(*)::int, COALESCE(bool_or(user_id::text = $2 AND muted_at IS NOT NULL), false)
			FROM playlist_subscriptions WHERE playlist_id = $1::uuid
		`, playlistID, userID).Scan(&s.Count, &s.Muted)
	})
	s.Subscribed = subscribed
	return s, err
}

// SetMuted mutes or unmutes the user's subscription to the playlist shared
// with token and returns its subscription after; doing it twice is the same
// as once. It is ErrNotFound unless the user is subscribed.
func (p *Playlists) SetMuted(ctx context.Context, userID, token string, muted bool) (Subscription, error) {
	var playlistID string
	err := p.pool.QueryRow(ctx, `
		UPDATE playlist_subscriptions s
		SET muted_at = CASE WHEN $3 THEN COALESCE(s.muted_at, now()) END
		FROM playlists
		WHERE playlists.id = s.playlist_id AND playlists.share_token = $2 AND s.user_id::text = $1
		RETURNING s.playlist_id::text
	`, userID, token, muted).Scan(&playlistID)
	if errors.Is(err, pgx.ErrNoRows) {
		return Subscription{}, ErrNotFound
	}
	if err != nil {
		return Subscription{}, err
	}
	if !muted {
		// What was added while it was muted stays in the inbox but isn't
		// pushed late; only new additions are.
		if _, err := p.pool.Exec(ctx, `
			UPDATE playlist_notifications SET pushed_at = updated_at
			WHERE user_id::text = $1 AND playlist_id = $2::uuid AND read_at IS NULL
		`, userID, playlistID); err != nil {
			return Subscription{}, err
		}
	}
	return p.SubscriptionFor(ctx, playlistID, userID)
}

// SubscribedPlaylist is a public playlist a user subscribed to, with how
// many tracks were added since they last read its notices.
type SubscribedPlaylist struct {
	ShareToken   string
	Name         string
	OwnerEmail   string
	TrackCount   int
	Unread       int
	Muted        bool
	SubscribedAt time.Time
	UpdatedAt    time.Time
}

// Subscribed lists the public playlists the user subscribed to, those with
// unread additions first, then the most recently updated. Playlists that
// stopped being public are left out until they are public again.
func (p *Playlists) Subscribed(ctx context.Context, userID string) ([]SubscribedPlaylist, error) {
	rows, err := p.pool.Query(ctx, `
		SELECT playlists.share_token, playlists.name, users.email,
			(SELECT count(*)::int FROM playlist_tracks pt JOIN tracks ON tracks.id = pt.track_id
			 WHERE pt.playlist_id = playlists.id AND `+trackBelongs("tracks", "playlists")+`
			   AND tracks.status = 'ready'),
			COALESCE(n.track_count, 0), s.muted_at IS NOT NULL, s.created_at, playlists.updated_at
		FROM playlist_subscriptions s
		JOIN playlists ON playlists.id = s.playlist_id
		JOIN users ON users.id = playlists.owner_id
		LEFT JOIN playlist_notifications n
			ON n.playlist_id = s.playlist_id AND n.user_id = s.user_id AND n.read_at IS NULL
		WHERE s.user_id::text = $1 AND playlists.is_public AND playlists.share_token IS NOT NULL
		ORDER BY n.id IS NOT NULL DESC, playlists.updated_at DESC, playlists.id
	`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	listed := []SubscribedPlaylist{}
	for rows.Next() {
		var sp SubscribedPlaylist
		if err := rows.Scan(&sp.ShareToken, &sp.Name, &sp.OwnerEmail, &sp.TrackCount, &sp.Unread,
			&sp.Muted, &sp.SubscribedAt, &sp.UpdatedAt); err != nil {
			return nil, err
		}
		listed = append(listed, sp)
	}
	return listed, rows.Err()
}

// Notification tells a subscriber that TrackCount tracks were added to a
// public playlist; TrackTitle is the latest one's, if it is still there.
type Notification struct {
	ID           string
	UserID       string
	ShareToken   string
	PlaylistName string
	TrackID      *string
	TrackTitle   *string
	TrackCount   int
	CreatedAt    time.Time
	UpdatedAt    time.Time
	ReadAt       *time.Time
}

// Notifications is a user's inbox of playlist notices, and the queue of
// those still to be pushed out of the app.
type Notifications struct {
	pool *pgxpool.Pool
}

func NewNotifications(pool *pgxpool.Pool) *Notifications {
	return &Notifications{pool: pool}
}

// visibleNotification keeps notices of playlists that are still public and
// shared; the others stay hidden until the playlist is public again.
const visibleNotification = `playlists.is_public AND playlists.share_token IS NOT NULL`

const notificationColumns = `n.id::text, n.user_id::text, playlists.share_token, playlists.name,
	n.track_id::text, CASE WHEN tracks.moderated_at IS NULL THEN tracks.title END, n.track_count,
	n.created_at, n.updated_at, n.read_at`

func scanNotifications(rows pgx.Rows) ([]Notification, error) {
	defer rows.Close()
	list := []Notification{}
	for rows.Next() {
		var n Notification
		if err := rows.Scan(&n.ID, &n.UserID, &n.ShareToken, &n.PlaylistName, &n.TrackID, &n.TrackTitle,
			&n.TrackCount, &n.CreatedAt, &n.UpdatedAt, &n.ReadAt); err != nil {
			return nil, err
		}
		list = append(list, n)
	}
	return list, rows.Err()
}

// List returns up to limit of the user's notices, newest first, and how
// many are unread.
func (s *Notifications) List(ctx context.Context, userID string, limit int) ([]Notification, int, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT `+notificationColumns+`
		FROM playlist_notifications n
		JOIN playlists ON playlists.id = n.playlist_id
		LEFT JOIN tracks ON tracks.id = n.track_id
		WHERE n.user_id::text = $1 AND `+visibleNotification+`
		ORDER BY n.updated_at DESC, n.id
		LIMIT $2
	`, userID, limit)
	if err != nil {
		return nil, 0, err
	}
	list, err := scanNotifications(rows)
	if err != nil {
		return nil, 0, err
	}
	unread, err := s.UnreadCount(ctx, userID)
	return list, unread, err
}

// notMuted keeps notices of channels the user hasn't muted.
const notMuted = `NOT EXISTS (SELECT 1 FROM playlist_subscriptions ms
	WHERE ms.playlist_id = n.playlist_id AND ms.user_id = n.user_id AND ms.muted_at IS NOT NULL)`

// UnreadCount is how many of the user's visible notices are unread, leaving
// out those of channels they muted.
func (s *Notifications) UnreadCount(ctx context.Context, userID string) (int, error) {
	var unread int
	err := s.pool.QueryRow(ctx, `
		SELECT count(*)::int FROM playlist_notifications n
		JOIN playlists ON playlists.id = n.playlist_id
		WHERE n.user_id::text = $1 AND n.read_at IS NULL AND `+visibleNotification+` AND `+notMuted+`
	`, userID).Scan(&unread)
	return unread, err
}

// MarkRead marks the user's notices with the given IDs as read, or all of
// them when ids is empty. A playlist's notice is also read when shareToken
// is set, which is what opening the playlist does. IDs of other users'
// notices are ignored.
func (s *Notifications) MarkRead(ctx context.Context, userID string, ids []string, shareToken string) error {
	_, err := s.pool.Exec(ctx, `
		UPDATE playlist_notifications n SET read_at = now()
		WHERE n.user_id::text = $1 AND n.read_at IS NULL
		  AND CASE WHEN $3 <> '' THEN n.playlist_id = (SELECT id FROM playlists WHERE share_token = $3)
			WHEN cardinality($2::text[]) > 0 THEN n.id::text = ANY($2)
			ELSE true END
	`, userID, ids, shareToken)
	return err
}

// PendingPushes returns up to limit unread notices that changed since they
// were last pushed, oldest change first. Notices older than since are left
// alone, so a long outage doesn't send stale news, and so are those of
// channels the subscriber muted.
func (s *Notifications) PendingPushes(ctx context.Context, since time.Time, limit int) ([]Notification, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT `+notificationColumns+`
		FROM playlist_notifications n
		JOIN playlists ON playlists.id = n.playlist_id
		LEFT JOIN tracks ON tracks.id = n.track_id
		WHERE n.read_at IS NULL AND n.updated_at >= $1
		  AND (n.pushed_at IS NULL OR n.pushed_at < n.updated_at) AND `+visibleNotification+` AND `+notMuted+`
		ORDER BY n.updated_at, n.id
		LIMIT $2
	`, since, limit)
	if err != nil {
		return nil, err
	}
	return scanNotifications(rows)
}

// MarkPushed records that the notice was pushed as it was at updatedAt; a
// later addition makes it pending again.
func (s *Notifications) MarkPushed(ctx context.Context, id string, updatedAt time.Time) error {
	_, err := s.pool.Exec(ctx, `
		UPDATE playlist_notifications SET pushed_at = $2 WHERE id::text = $1
	`, id, updatedAt)
	return err
}
