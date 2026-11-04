package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

var (
	ErrCodeInvalid     = errors.New("link code is wrong or expired")
	ErrCodeAttempts    = errors.New("too many wrong link codes")
	ErrCodeCollision   = errors.New("link code is already in use")
	ErrDuplicateImport = errors.New("message was already imported")
)

// BotChat is one private chat with a bot. UserID is set while it is linked
// to a rhythmo account.
type BotChat struct {
	Provider string
	ChatID   string
	UserID   *string
	LinkedAt *time.Time
}

// Bots stores messenger chats, the codes that link them to accounts,
// processed updates and audio imports.
type Bots struct {
	pool *pgxpool.Pool
}

func NewBots(pool *pgxpool.Pool) *Bots {
	return &Bots{pool: pool}
}

// Chat returns the chat, or an unlinked chat if it has never been seen.
func (b *Bots) Chat(ctx context.Context, provider, chatID string) (BotChat, error) {
	chat := BotChat{Provider: provider, ChatID: chatID}
	err := b.pool.QueryRow(ctx, `
		SELECT user_id::text, linked_at FROM bot_chats
		WHERE provider = $1 AND chat_id = $2
	`, provider, chatID).Scan(&chat.UserID, &chat.LinkedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return chat, nil
	}
	return chat, err
}

// Unlink detaches the chat from its account.
func (b *Bots) Unlink(ctx context.Context, provider, chatID string) error {
	_, err := b.pool.Exec(ctx, `
		UPDATE bot_chats SET user_id = NULL, linked_at = NULL, updated_at = now()
		WHERE provider = $1 AND chat_id = $2
	`, provider, chatID)
	return err
}

// CreateLinkCode stores a new code for the user, replacing any they had, and
// drops every expired code. ErrCodeCollision means another live code has the
// same value; pick a new one.
func (b *Bots) CreateLinkCode(ctx context.Context, userID string, hash []byte, expiresAt time.Time) error {
	return pgx.BeginFunc(ctx, b.pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `
			DELETE FROM bot_link_codes WHERE (user_id::text = $1 AND playlist_id IS NULL) OR expires_at <= now()
		`, userID); err != nil {
			return err
		}
		tag, err := tx.Exec(ctx, `
			INSERT INTO bot_link_codes (code_hash, user_id, expires_at) VALUES ($1, $2::uuid, $3)
			ON CONFLICT DO NOTHING
		`, hash, userID, expiresAt)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return ErrCodeCollision
		}
		return nil
	})
}

// RedeemLinkCode links the chat to the account whose live code matches hash,
// using the code up. Wrong codes count against the chat: after maxFailures
// within window, every code is refused until the window passes.
func (b *Bots) RedeemLinkCode(
	ctx context.Context, provider, chatID string, hash []byte,
	now time.Time, maxFailures int, window time.Duration,
) (string, error) {
	var linked string
	err := b.redeem(ctx, provider, chatID, hash, now, maxFailures, window, false,
		func(tx pgx.Tx, userID, _ string) error {
			linked = userID
			_, err := tx.Exec(ctx, `
				UPDATE bot_chats SET user_id = $3::uuid, linked_at = $4, failed_links = 0, failed_since = NULL
				WHERE provider = $1 AND chat_id = $2
			`, provider, chatID, userID, now)
			return err
		})
	return linked, err
}

// redeem uses up the live code matching hash, a channel code or a private
// chat one, and runs link with whose it was. Wrong codes count against the
// chat: after maxFailures within window, every code is refused until the
// window passes.
func (b *Bots) redeem(
	ctx context.Context, provider, chatID string, hash []byte,
	now time.Time, maxFailures int, window time.Duration, channel bool,
	link func(tx pgx.Tx, userID, playlistID string) error,
) error {
	var result error
	err := pgx.BeginFunc(ctx, b.pool, func(tx pgx.Tx) error {
		var failures int
		var since *time.Time
		if err := tx.QueryRow(ctx, `
			INSERT INTO bot_chats (provider, chat_id) VALUES ($1, $2)
			ON CONFLICT (provider, chat_id) DO UPDATE SET updated_at = now()
			RETURNING failed_links, failed_since
		`, provider, chatID).Scan(&failures, &since); err != nil {
			return err
		}
		if since == nil || now.Sub(*since) >= window {
			failures, since = 0, &now
		}
		if failures >= maxFailures {
			result = ErrCodeAttempts
			return nil
		}
		var userID string
		var playlistID *string
		err := tx.QueryRow(ctx, `
			DELETE FROM bot_link_codes WHERE code_hash = $1 AND expires_at > $2 AND (playlist_id IS NOT NULL) = $3
			RETURNING user_id::text, playlist_id::text
		`, hash, now, channel).Scan(&userID, &playlistID)
		if errors.Is(err, pgx.ErrNoRows) {
			failures++
			result = ErrCodeInvalid
			if failures >= maxFailures {
				result = ErrCodeAttempts
			}
			_, err := tx.Exec(ctx, `
				UPDATE bot_chats SET failed_links = $3, failed_since = $4
				WHERE provider = $1 AND chat_id = $2
			`, provider, chatID, failures, *since)
			return err
		}
		if err != nil {
			return err
		}
		return link(tx, userID, optional(playlistID))
	})
	if err != nil {
		return err
	}
	return result
}

func optional(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

// LinkedChats lists the user's chats with the provider linked since the
// given time; older links have expired.
func (b *Bots) LinkedChats(ctx context.Context, userID, provider string, since time.Time) ([]string, error) {
	rows, err := b.pool.Query(ctx, `
		SELECT chat_id FROM bot_chats
		WHERE user_id::text = $1 AND provider = $2 AND linked_at >= $3
		ORDER BY linked_at DESC
	`, userID, provider, since)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowTo[string])
}

// LinkedProviders lists the providers the user has a chat linked with since
// the given time.
func (b *Bots) LinkedProviders(ctx context.Context, userID string, since time.Time) ([]string, error) {
	rows, err := b.pool.Query(ctx, `
		SELECT DISTINCT provider FROM bot_chats
		WHERE user_id::text = $1 AND linked_at >= $2
		ORDER BY provider
	`, userID, since)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowTo[string])
}

// TrackFileID returns the provider's file ID for a track, or "" if the bot
// has not uploaded it yet.
func (b *Bots) TrackFileID(ctx context.Context, provider, trackID string) (string, error) {
	var fileID string
	err := b.pool.QueryRow(ctx, `
		SELECT file_id FROM bot_track_files WHERE provider = $1 AND track_id::text = $2
	`, provider, trackID).Scan(&fileID)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", nil
	}
	return fileID, err
}

// SaveTrackFileID remembers (or replaces) the provider's file ID for a track.
func (b *Bots) SaveTrackFileID(ctx context.Context, provider, trackID, fileID string) error {
	_, err := b.pool.Exec(ctx, `
		INSERT INTO bot_track_files (provider, track_id, file_id) VALUES ($1, $2::uuid, $3)
		ON CONFLICT (provider, track_id) DO UPDATE SET file_id = $3, created_at = now()
	`, provider, trackID, fileID)
	return err
}

// FirstDelivery records an update and reports whether it is new.
func (b *Bots) FirstDelivery(ctx context.Context, provider, updateID string) (bool, error) {
	tag, err := b.pool.Exec(ctx, `
		INSERT INTO bot_updates (provider, update_id) VALUES ($1, $2)
		ON CONFLICT DO NOTHING
	`, provider, updateID)
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() == 1, nil
}

// ForgetUpdatesBefore bounds the dedup table; providers stop redelivering
// long before this.
func (b *Bots) ForgetUpdatesBefore(ctx context.Context, before time.Time) error {
	_, err := b.pool.Exec(ctx, `DELETE FROM bot_updates WHERE received_at < $1`, before)
	return err
}

type ImportState string

const (
	ImportQueued      ImportState = "queued"
	ImportDownloading ImportState = "downloading"
	ImportDone        ImportState = "done"
	ImportFailed      ImportState = "failed"
)

type BotImport struct {
	ID        string
	Provider  string
	ChatID    string
	MessageID string
	UserID    string
	FileID    string
	FileName  string
	Title     *string
	Artist    *string
	SizeBytes int64
	State     ImportState
	TrackID   *string
	Error     *string
	Attempts  int
	CreatedAt time.Time
	// PlaylistID is set for a post in a synced channel: the imported track
	// is added to that rhythmo channel.
	PlaylistID *string
}

const importColumns = `id::text, provider, chat_id, message_id, user_id::text, file_id, file_name,
	title, artist, size_bytes, state, track_id::text, error, attempts, created_at, playlist_id::text`

func scanImport(row pgx.Row) (BotImport, error) {
	var i BotImport
	err := row.Scan(&i.ID, &i.Provider, &i.ChatID, &i.MessageID, &i.UserID, &i.FileID, &i.FileName,
		&i.Title, &i.Artist, &i.SizeBytes, &i.State, &i.TrackID, &i.Error, &i.Attempts, &i.CreatedAt, &i.PlaylistID)
	return i, err
}

// AddImport queues an import. The same message is queued only once, however
// often the provider redelivers it: ErrDuplicateImport.
func (b *Bots) AddImport(ctx context.Context, i BotImport) (BotImport, error) {
	created, err := scanImport(b.pool.QueryRow(ctx, `
		INSERT INTO bot_imports (provider, chat_id, message_id, user_id, file_id, file_name, title, artist, size_bytes, playlist_id)
		VALUES ($1, $2, $3, $4::uuid, $5, $6, $7, $8, $9, $10::uuid)
		ON CONFLICT (provider, chat_id, message_id) DO NOTHING
		RETURNING `+importColumns,
		i.Provider, i.ChatID, i.MessageID, i.UserID, i.FileID, i.FileName, i.Title, i.Artist, i.SizeBytes, i.PlaylistID))
	if errors.Is(err, pgx.ErrNoRows) {
		return BotImport{}, ErrDuplicateImport
	}
	return created, err
}

// StartImport claims a queued (or interrupted) import and counts the attempt.
// It returns false when another worker has it or it is finished.
func (b *Bots) StartImport(ctx context.Context, id string, staleBefore time.Time) (BotImport, bool, error) {
	claimed, err := scanImport(b.pool.QueryRow(ctx, `
		UPDATE bot_imports SET state = 'downloading', attempts = attempts + 1, updated_at = now()
		WHERE id::text = $1
		  AND (state = 'queued' OR (state = 'downloading' AND updated_at < $2))
		RETURNING `+importColumns, id, staleBefore))
	if errors.Is(err, pgx.ErrNoRows) {
		return BotImport{}, false, nil
	}
	return claimed, err == nil, err
}

// FinishImport records the outcome. trackID is set on success, reason on failure.
func (b *Bots) FinishImport(ctx context.Context, id string, trackID, reason *string) error {
	state := ImportDone
	if trackID == nil {
		state = ImportFailed
	}
	_, err := b.pool.Exec(ctx, `
		UPDATE bot_imports SET state = $2, track_id = $3::uuid, error = $4, updated_at = now()
		WHERE id::text = $1
	`, id, string(state), trackID, reason)
	return err
}

// RequeueImport puts an import that failed for a passing reason back in line.
func (b *Bots) RequeueImport(ctx context.Context, id string) error {
	_, err := b.pool.Exec(ctx,
		`UPDATE bot_imports SET state = 'queued', updated_at = now() WHERE id::text = $1`, id)
	return err
}

// ActiveImports counts the user's imports still queued or downloading.
func (b *Bots) ActiveImports(ctx context.Context, userID string) (int, error) {
	var n int
	err := b.pool.QueryRow(ctx, `
		SELECT COUNT(*)::integer FROM bot_imports
		WHERE user_id::text = $1 AND state IN ('queued', 'downloading')
	`, userID).Scan(&n)
	return n, err
}

// ImportStats summarizes the import queue across all users.
type ImportStats struct {
	Queued         int        `json:"queued"`
	Downloading    int        `json:"downloading"`
	DoneLastHour   int        `json:"doneLastHour"`
	FailedLastHour int        `json:"failedLastHour"`
	OldestWaiting  *time.Time `json:"oldestWaiting,omitempty"`
}

// ImportStats reports how the import queue for one provider is doing.
func (b *Bots) ImportStats(ctx context.Context, provider string, now time.Time) (ImportStats, error) {
	var stats ImportStats
	err := b.pool.QueryRow(ctx, `
		SELECT
			COUNT(*) FILTER (WHERE state = 'queued')::integer,
			COUNT(*) FILTER (WHERE state = 'downloading')::integer,
			COUNT(*) FILTER (WHERE state = 'done' AND updated_at >= $2)::integer,
			COUNT(*) FILTER (WHERE state = 'failed' AND updated_at >= $2)::integer,
			MIN(created_at) FILTER (WHERE state IN ('queued', 'downloading'))
		FROM bot_imports WHERE provider = $1
	`, provider, now.Add(-time.Hour)).Scan(
		&stats.Queued, &stats.Downloading, &stats.DoneLastHour, &stats.FailedLastHour, &stats.OldestWaiting)
	return stats, err
}

// UnfinishedImports lists imports interrupted by a restart, oldest first.
func (b *Bots) UnfinishedImports(ctx context.Context, limit int) ([]BotImport, error) {
	rows, err := b.pool.Query(ctx, `
		SELECT `+importColumns+` FROM bot_imports
		WHERE state IN ('queued', 'downloading')
		ORDER BY created_at, id LIMIT $1
	`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var imports []BotImport
	for rows.Next() {
		i, err := scanImport(rows)
		if err != nil {
			return nil, err
		}
		imports = append(imports, i)
	}
	return imports, rows.Err()
}

// ActiveImportFor reports whether the user already has an unfinished
// import of this file from this provider.
func (b *Bots) ActiveImportFor(ctx context.Context, userID, provider, fileID string) (bool, error) {
	var active bool
	err := b.pool.QueryRow(ctx, `
		SELECT EXISTS (
			SELECT 1 FROM bot_imports
			WHERE user_id::text = $1 AND provider = $2 AND file_id = $3
			  AND state IN ('queued', 'downloading')
		)
	`, userID, provider, fileID).Scan(&active)
	return active, err
}

// RecentImports lists the user's latest imports from one provider, newest
// first.
func (b *Bots) RecentImports(ctx context.Context, userID, provider string, limit int) ([]BotImport, error) {
	rows, err := b.pool.Query(ctx, `
		SELECT `+importColumns+` FROM bot_imports
		WHERE user_id::text = $1 AND provider = $2
		ORDER BY created_at DESC, id LIMIT $3
	`, userID, provider, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	imports := []BotImport{}
	for rows.Next() {
		i, err := scanImport(rows)
		if err != nil {
			return nil, err
		}
		imports = append(imports, i)
	}
	return imports, rows.Err()
}
