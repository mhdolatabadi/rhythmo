package store

import (
	"context"
	"errors"
	"strconv"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// BaleImports uses the existing quota-checked bot pipeline; finalizing its
// job and placing the ready track in its topic playlist is one transaction.
type BaleImports struct{ *Bots }

func NewBaleImports(pool *pgxpool.Pool) *BaleImports { return &BaleImports{NewBots(pool)} }

var ErrArchiveBusy = errors.New("archive import queue is full")

type BaleLecture struct {
	MessageID, FileName, Title, Caption, Topic, TopicKey, SourceURL string
	Date, SizeBytes, DurationMS                                     int64
	Session                                                         int
}

func (b *BaleImports) QueueBale(ctx context.Context, userID string, l BaleLecture, maxActive int) (BotImport, error) {
	var job BotImport
	err := pgx.BeginFunc(ctx, b.pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1, 433))`, userID); err != nil {
			return err
		}
		existing, err := scanImport(tx.QueryRow(ctx, `SELECT `+importColumns+` FROM bot_imports WHERE provider='bale_archive' AND chat_id=$1 AND message_id=$2 FOR UPDATE`, userID, l.MessageID))
		if err == nil && existing.State != ImportFailed {
			job = existing
			return nil
		}
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		var n int
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM bot_imports WHERE user_id::text=$1 AND state IN ('queued','downloading')`, userID).Scan(&n); err != nil {
			return err
		}
		if n >= maxActive {
			return ErrArchiveBusy
		}
		if existing.ID != "" {
			// Failed jobs retry their original topic and metadata, keeping one source
			// identity. Refreshing media happens when the worker opens the post.
			job, err = scanImport(tx.QueryRow(ctx, `UPDATE bot_imports SET state='queued', attempts=0,error=NULL,updated_at=now() WHERE id::text=$1 RETURNING `+importColumns, existing.ID))
			return err
		}
		var playlistID string
		err = tx.QueryRow(ctx, `SELECT playlist_id::text FROM bale_archive_topics WHERE owner_id::text=$1 AND channel='kashani1395' AND topic_key=$2`, userID, l.TopicKey).Scan(&playlistID)
		if errors.Is(err, pgx.ErrNoRows) {
			if err = tx.QueryRow(ctx, `INSERT INTO playlists(owner_id,name,description) VALUES($1::uuid,$2,$3) RETURNING id::text`, userID, l.Topic, "حامد کاشانی · منبع: https://ble.ir/kashani1395").Scan(&playlistID); err != nil {
				return err
			}
			_, err = tx.Exec(ctx, `INSERT INTO bale_archive_topics(owner_id,channel,topic_key,playlist_id) VALUES($1::uuid,'kashani1395',$2,$3::uuid)`, userID, l.TopicKey, playlistID)
		}
		if err != nil {
			return err
		}
		artist := "حامد کاشانی"
		job, err = scanImport(tx.QueryRow(ctx, `INSERT INTO bot_imports(provider,chat_id,message_id,user_id,file_id,file_name,title,artist,size_bytes,playlist_id) VALUES('bale_archive',$1::text,$2,$1::text::uuid,$3,$4,$5,$6,$7,$8::uuid) RETURNING `+importColumns, userID, l.MessageID, l.MessageID+"/"+strconv.FormatInt(l.Date, 10), l.FileName, l.Title, artist, l.SizeBytes, playlistID))
		if err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `INSERT INTO bale_archive_posts(owner_id,channel,message_id,message_date,source_url,caption,topic,session_number,duration_ms,import_id) VALUES($1::uuid,'kashani1395',$2,$3,$4,$5,$6,$7,$8,$9::uuid)`, userID, l.MessageID, l.Date, l.SourceURL, l.Caption, l.Topic, l.Session, l.DurationMS, job.ID)
		return err
	})
	return job, err
}

func (b *BaleImports) FinishImport(ctx context.Context, id string, trackID, reason *string) error {
	if trackID == nil {
		return b.Bots.FinishImport(ctx, id, trackID, reason)
	}
	return pgx.BeginFunc(ctx, b.pool, func(tx pgx.Tx) error {
		var ownerID string
		var playlistID *string
		if err := tx.QueryRow(ctx, `SELECT user_id::text,playlist_id::text FROM bot_imports WHERE id::text=$1 AND provider='bale_archive' FOR UPDATE`, id).Scan(&ownerID, &playlistID); err != nil {
			return err
		}
		// Lock against concurrent edits and imports before assigning positions.
		if playlistID != nil {
			var locked string
			err := tx.QueryRow(ctx, `SELECT id::text FROM playlists WHERE id::text=$1 FOR UPDATE`, *playlistID).Scan(&locked)
			if errors.Is(err, pgx.ErrNoRows) {
				playlistID = nil
			} else if err != nil {
				return err
			}
		}
		if _, err := tx.Exec(ctx, `UPDATE tracks t SET album=p.topic,duration_ms=NULLIF(p.duration_ms,0),track_number=NULLIF(p.session_number,0),comment=p.source_url FROM bale_archive_posts p WHERE p.import_id::text=$1 AND t.id::text=$2 AND t.owner_id::text=$3`, id, *trackID, ownerID); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE bot_imports SET state='done',track_id=$2::uuid,error=NULL,updated_at=now() WHERE id::text=$1`, id, *trackID); err != nil {
			return err
		}
		if playlistID == nil {
			return nil
		} // deleted topic never resurrects a playlist
		if _, err := tx.Exec(ctx, `INSERT INTO playlist_tracks(playlist_id,track_id,position) VALUES($1::uuid,$2::uuid,COALESCE((SELECT max(position)+1 FROM playlist_tracks WHERE playlist_id=$1::uuid),0)) ON CONFLICT(playlist_id,track_id) DO NOTHING`, *playlistID, *trackID); err != nil {
			return err
		}
		// Move every old position out of the destination range first to respect
		// the immediate UNIQUE(playlist_id,position) constraint during reordering.
		if _, err := tx.Exec(ctx, `UPDATE playlist_tracks SET position=position+(SELECT COALESCE(max(position),0)+count(*)::int+1 FROM playlist_tracks WHERE playlist_id::text=$1) WHERE playlist_id::text=$1`, *playlistID); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `WITH ordered AS (
   SELECT pt.track_id,(row_number() OVER(ORDER BY NULLIF(p.session_number,0) NULLS LAST,p.message_date NULLS LAST,pt.added_at,pt.track_id)-1)::int AS pos
   FROM playlist_tracks pt LEFT JOIN bot_imports i ON i.track_id=pt.track_id AND i.provider='bale_archive'
   LEFT JOIN bale_archive_posts p ON p.import_id=i.id WHERE pt.playlist_id::text=$1
  ) UPDATE playlist_tracks pt SET position=o.pos FROM ordered o WHERE pt.playlist_id::text=$1 AND pt.track_id=o.track_id`, *playlistID); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `UPDATE playlists SET updated_at=now() WHERE id::text=$1`, *playlistID)
		return err
	})
}

// Avoid unrelated imports starving this archive's restart recovery.
func (b *BaleImports) UnfinishedImports(ctx context.Context, limit int) ([]BotImport, error) {
	rows, err := b.pool.Query(ctx, `SELECT `+importColumns+` FROM bot_imports WHERE provider='bale_archive' AND state IN('queued','downloading') ORDER BY created_at,id LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	jobs := []BotImport{}
	for rows.Next() {
		j, err := scanImport(rows)
		if err != nil {
			return nil, err
		}
		jobs = append(jobs, j)
	}
	return jobs, rows.Err()
}
