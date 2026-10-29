package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// BotChannel is a messenger channel synced into a rhythmo channel (#430):
// audio posted there is imported into UserID's library and added to the
// playlist.
type BotChannel struct {
	Provider   string
	ChatID     string
	PlaylistID string
	UserID     string
	Title      string
	LinkedAt   time.Time
}

const botChannelColumns = `c.provider, c.chat_id, c.playlist_id::text, c.user_id::text, c.title, c.linked_at`

func scanBotChannel(row pgx.Row) (BotChannel, error) {
	var c BotChannel
	err := row.Scan(&c.Provider, &c.ChatID, &c.PlaylistID, &c.UserID, &c.Title, &c.LinkedAt)
	return c, err
}

// CreateChannelCode stores a code that links a messenger channel to the
// playlist, replacing the user's earlier code for it. The owner and admins
// may make one; ErrNotFound for anyone else, ErrCodeCollision when another
// live code has the same value.
func (b *Bots) CreateChannelCode(ctx context.Context, userID, playlistID string, hash []byte, expiresAt time.Time) error {
	return pgx.BeginFunc(ctx, b.pool, func(tx pgx.Tx) error {
		var allowed bool
		err := tx.QueryRow(ctx, `
			SELECT `+canManage("playlists", "$2")+` FROM playlists WHERE playlists.id::text = $1
		`, playlistID, userID).Scan(&allowed)
		if errors.Is(err, pgx.ErrNoRows) || (err == nil && !allowed) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `
			DELETE FROM bot_link_codes
			WHERE (user_id::text = $1 AND playlist_id::text = $2) OR expires_at <= now()
		`, userID, playlistID); err != nil {
			return err
		}
		tag, err := tx.Exec(ctx, `
			INSERT INTO bot_link_codes (code_hash, user_id, playlist_id, expires_at) VALUES ($1, $2::uuid, $3::uuid, $4)
			ON CONFLICT DO NOTHING
		`, hash, userID, playlistID, expiresAt)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return ErrCodeCollision
		}
		return nil
	})
}

// RedeemChannelCode links the channel to the playlist whose live channel
// code matches hash, and returns the link. A channel already linked moves
// to the new playlist. Wrong codes count against the channel as they do
// against a private chat. ErrNotFound means whoever made the code no longer
// runs the playlist.
func (b *Bots) RedeemChannelCode(
	ctx context.Context, provider, chatID, title string, hash []byte,
	now time.Time, maxFailures int, window time.Duration,
) (BotChannel, error) {
	var linked BotChannel
	err := b.redeem(ctx, provider, chatID, hash, now, maxFailures, window, true,
		func(tx pgx.Tx, userID, playlistID string) error {
			if _, err := tx.Exec(ctx, `
				UPDATE bot_chats SET failed_links = 0, failed_since = NULL WHERE provider = $1 AND chat_id = $2
			`, provider, chatID); err != nil {
				return err
			}
			var allowed bool
			if err := tx.QueryRow(ctx, `
				SELECT `+canManage("playlists", "$2")+` FROM playlists WHERE playlists.id::text = $1
			`, playlistID, userID).Scan(&allowed); err != nil {
				return err
			}
			if !allowed {
				return ErrNotFound
			}
			var err error
			linked, err = scanBotChannel(tx.QueryRow(ctx, `
				INSERT INTO bot_channels AS c (provider, chat_id, playlist_id, user_id, title, linked_at)
				VALUES ($1, $2, $3::uuid, $4::uuid, $5, $6)
				ON CONFLICT (provider, chat_id) DO UPDATE SET
					playlist_id = EXCLUDED.playlist_id, user_id = EXCLUDED.user_id,
					title = EXCLUDED.title, linked_at = EXCLUDED.linked_at
				RETURNING `+botChannelColumns,
				provider, chatID, playlistID, userID, title, now))
			return err
		})
	return linked, err
}

// ChannelFor returns the link of a messenger channel, or ErrNotFound when
// it has none. A link whose person no longer runs the playlist is dropped
// and is ErrNotFound too.
func (b *Bots) ChannelFor(ctx context.Context, provider, chatID string) (BotChannel, error) {
	var c BotChannel
	var allowed bool
	err := b.pool.QueryRow(ctx, `
		SELECT `+botChannelColumns+`, `+canManage("playlists", "c.user_id::text")+`
		FROM bot_channels c JOIN playlists ON playlists.id = c.playlist_id
		WHERE c.provider = $1 AND c.chat_id = $2
	`, provider, chatID).Scan(&c.Provider, &c.ChatID, &c.PlaylistID, &c.UserID, &c.Title, &c.LinkedAt, &allowed)
	if errors.Is(err, pgx.ErrNoRows) {
		return BotChannel{}, ErrNotFound
	}
	if err != nil {
		return BotChannel{}, err
	}
	if !allowed {
		if err := b.UnlinkChannel(ctx, provider, chatID); err != nil {
			return BotChannel{}, err
		}
		return BotChannel{}, ErrNotFound
	}
	return c, nil
}

// UnlinkChannel stops syncing the messenger channel. Doing it twice is the
// same as once.
func (b *Bots) UnlinkChannel(ctx context.Context, provider, chatID string) error {
	_, err := b.pool.Exec(ctx, `DELETE FROM bot_channels WHERE provider = $1 AND chat_id = $2`, provider, chatID)
	return err
}

// PlaylistChannels lists the messenger channels synced into the playlist,
// oldest link first, for its owner or an admin; ErrNotFound for anyone else.
func (b *Bots) PlaylistChannels(ctx context.Context, actorID, playlistID string) ([]BotChannel, error) {
	var allowed bool
	err := b.pool.QueryRow(ctx, `
		SELECT `+canManage("playlists", "$2")+` FROM playlists WHERE playlists.id::text = $1
	`, playlistID, actorID).Scan(&allowed)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && !allowed) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	rows, err := b.pool.Query(ctx, `
		SELECT `+botChannelColumns+` FROM bot_channels c
		WHERE c.playlist_id::text = $1
		ORDER BY c.linked_at, c.provider, c.chat_id
	`, playlistID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	channels := []BotChannel{}
	for rows.Next() {
		c, err := scanBotChannel(rows)
		if err != nil {
			return nil, err
		}
		channels = append(channels, c)
	}
	return channels, rows.Err()
}

// RemovePlaylistChannel stops syncing a messenger channel into the
// playlist. Its owner or an admin may; ErrNotFound covers anyone else and a
// channel that isn't linked to it.
func (b *Bots) RemovePlaylistChannel(ctx context.Context, actorID, playlistID, provider, chatID string) error {
	tag, err := b.pool.Exec(ctx, `
		DELETE FROM bot_channels c USING playlists
		WHERE playlists.id = c.playlist_id AND c.playlist_id::text = $1
		  AND c.provider = $3 AND c.chat_id = $4 AND `+canManage("playlists", "$2")+`
	`, playlistID, actorID, provider, chatID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}
