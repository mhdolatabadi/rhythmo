package store

import (
	"context"
	"errors"
	"github.com/jackc/pgx/v5"
	"time"
)

type BaleScan struct {
	State        string    `json:"state"`
	Before       int64     `json:"before"`
	Scanned      int64     `json:"scannedPosts"`
	Unclassified int       `json:"unclassified"`
	Error        *string   `json:"error,omitempty"`
	UpdatedAt    time.Time `json:"updatedAt"`
}
type BaleTopic struct {
	Key      string  `json:"key"`
	Name     string  `json:"name"`
	Total    int     `json:"total"`
	Imported int     `json:"imported"`
	Pending  int     `json:"pending"`
	Failed   int     `json:"failed"`
	State    string  `json:"state"`
	Error    *string `json:"error,omitempty"`
}
type BaleCatalog struct {
	Scan   BaleScan    `json:"scan"`
	Topics []BaleTopic `json:"topics"`
}
type BaleScanClaim struct {
	Token  string
	Before int64
}

// EnsureBaleScan starts the initial scan; polling never restarts a completed scan.
func (b *BaleImports) EnsureBaleScan(ctx context.Context) error {
	_, err := b.pool.Exec(ctx, `UPDATE bale_catalog_scan SET state='scanning',updated_at=now() WHERE id AND state='idle'`)
	return err
}
func (b *BaleImports) RefreshBaleScan(ctx context.Context) error {
	_, err := b.pool.Exec(ctx, `UPDATE bale_catalog_scan SET before_date=CASE WHEN state='done' THEN 0 ELSE before_date END,scanned_posts=CASE WHEN state='done' THEN 0 ELSE scanned_posts END,state='scanning',error=NULL,lease_until=CASE WHEN lease_token IS NULL THEN NULL ELSE lease_until END,updated_at=now() WHERE id`)
	return err
}
func (b *BaleImports) ClaimBaleScan(ctx context.Context) (BaleScanClaim, bool, error) {
	var c BaleScanClaim
	err := b.pool.QueryRow(ctx, `UPDATE bale_catalog_scan SET lease_token=gen_random_uuid(),lease_until=now()+interval '2 minutes' WHERE id AND state='scanning' AND (lease_until IS NULL OR lease_until<now()) RETURNING lease_token::text,before_date`).Scan(&c.Token, &c.Before)
	if errors.Is(err, pgx.ErrNoRows) {
		return c, false, nil
	}
	return c, err == nil, err
}
func (b *BaleImports) FailBaleScan(ctx context.Context, token string) error {
	_, err := b.pool.Exec(ctx, `UPDATE bale_catalog_scan SET error='archive_unavailable',lease_token=NULL,lease_until=now()+interval '1 minute',updated_at=now() WHERE id AND lease_token::text=$1`, token)
	return err
}
func (b *BaleImports) SaveBalePage(ctx context.Context, c BaleScanClaim, posts []BaleLecture, next int64, done bool, scanned int) error {
	return pgx.BeginFunc(ctx, b.pool, func(tx pgx.Tx) error {
		var token *string
		if err := tx.QueryRow(ctx, `SELECT lease_token::text FROM bale_catalog_scan WHERE id FOR UPDATE`).Scan(&token); err != nil {
			return err
		}
		if token == nil || *token != c.Token {
			return nil
		} // superseded lease cannot advance the cursor
		for _, p := range posts {
			_, err := tx.Exec(ctx, `INSERT INTO bale_catalog_posts(message_id,message_date,title,topic,topic_key,session_number,file_name,size_bytes,duration_ms,caption,source_url) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
   ON CONFLICT(message_id) DO UPDATE SET title=EXCLUDED.title,topic=EXCLUDED.topic,topic_key=EXCLUDED.topic_key,session_number=EXCLUDED.session_number,file_name=EXCLUDED.file_name,size_bytes=EXCLUDED.size_bytes,duration_ms=EXCLUDED.duration_ms,caption=EXCLUDED.caption,source_url=EXCLUDED.source_url`, p.MessageID, p.Date, p.Title, p.Topic, p.TopicKey, p.Session, p.FileName, p.SizeBytes, p.DurationMS, p.Caption, p.SourceURL)
			if err != nil {
				return err
			}
		}
		state := "scanning"
		if done {
			state = "done"
			next = c.Before
		}
		_, err := tx.Exec(ctx, `UPDATE bale_catalog_scan SET state=$1,before_date=$2,scanned_posts=scanned_posts+$3,lease_token=NULL,lease_until=NULL,error=NULL,updated_at=now() WHERE id`, state, next, scanned)
		return err
	})
}
func (b *BaleImports) BaleCatalog(ctx context.Context, userID string) (BaleCatalog, error) {
	out := BaleCatalog{Topics: []BaleTopic{}}
	err := b.pool.QueryRow(ctx, `SELECT state,before_date,scanned_posts,error,updated_at,(SELECT count(*)::int FROM bale_catalog_posts WHERE topic_key='') FROM bale_catalog_scan WHERE id`).Scan(&out.Scan.State, &out.Scan.Before, &out.Scan.Scanned, &out.Scan.Error, &out.Scan.UpdatedAt, &out.Scan.Unclassified)
	if err != nil {
		return out, err
	}
	rows, err := b.pool.Query(ctx, `SELECT c.topic_key,min(c.topic),count(*)::int,
 count(*) FILTER(WHERE i.state='done')::int,
 count(*) FILTER(WHERE i.state IN('queued','downloading'))::int,
 count(*) FILTER(WHERE i.state='failed')::int,
 COALESCE(r.state,''),r.error
 FROM bale_catalog_posts c LEFT JOIN bot_imports i ON i.provider='bale_archive' AND i.user_id::text=$1 AND i.message_id=c.message_id
 LEFT JOIN bale_topic_requests r ON r.owner_id::text=$1 AND r.topic_key=c.topic_key
 WHERE c.topic_key<>'' GROUP BY c.topic_key,r.state,r.error ORDER BY min(c.topic)`, userID)
	if err != nil {
		return out, err
	}
	defer rows.Close()
	for rows.Next() {
		var t BaleTopic
		var request string
		if err := rows.Scan(&t.Key, &t.Name, &t.Total, &t.Imported, &t.Pending, &t.Failed, &request, &t.Error); err != nil {
			return out, err
		}
		switch {
		case request == "running" || t.Pending > 0:
			t.State = "importing"
		case t.Imported == t.Total && out.Scan.State == "done":
			t.State = "imported"
		case request == "blocked":
			t.State = "failed"
		case t.Imported > 0:
			t.State = "partial"
		default:
			t.State = "available"
		}
		out.Topics = append(out.Topics, t)
	}
	return out, rows.Err()
}
func (b *BaleImports) RequestBaleTopic(ctx context.Context, userID, key string) error {
	tag, err := b.pool.Exec(ctx, `INSERT INTO bale_topic_requests(owner_id,topic_key,state) SELECT $1::uuid,$2,'running' WHERE EXISTS(SELECT 1 FROM bale_catalog_posts WHERE topic_key=$2)
 ON CONFLICT(owner_id,topic_key) DO UPDATE SET state='running',error=NULL,requested_at=now() WHERE bale_topic_requests.state<>'running'`, userID, key)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		var exists bool
		if err = b.pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM bale_catalog_posts WHERE topic_key=$1)`, key).Scan(&exists); err != nil {
			return err
		}
		if !exists {
			return ErrNotFound
		}
	}
	return nil
}

type BaleTopicRequest struct {
	OwnerID, Key string
	RequestedAt  time.Time
}

func (b *BaleImports) BaleTopicRequests(ctx context.Context) ([]BaleTopicRequest, error) {
	rows, err := b.pool.Query(ctx, `SELECT owner_id::text,topic_key,requested_at FROM bale_topic_requests WHERE state='running' ORDER BY requested_at LIMIT 100`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []BaleTopicRequest{}
	for rows.Next() {
		var r BaleTopicRequest
		if err := rows.Scan(&r.OwnerID, &r.Key, &r.RequestedAt); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}
func (b *BaleImports) NextBaleLecture(ctx context.Context, r BaleTopicRequest) (BaleLecture, error) {
	var p BaleLecture
	err := b.pool.QueryRow(ctx, `SELECT c.message_id,c.message_date,c.file_name,c.title,c.caption,c.topic,c.topic_key,c.source_url,c.session_number,c.size_bytes,c.duration_ms
 FROM bale_catalog_posts c WHERE c.topic_key=$2 AND NOT EXISTS(
 SELECT 1 FROM bot_imports i WHERE i.provider='bale_archive' AND i.user_id::text=$1 AND i.message_id=c.message_id AND (i.state<>'failed' OR i.updated_at>=$3))
 ORDER BY NULLIF(c.session_number,0) NULLS LAST,c.message_date,c.message_id LIMIT 1`, r.OwnerID, r.Key, r.RequestedAt).Scan(&p.MessageID, &p.Date, &p.FileName, &p.Title, &p.Caption, &p.Topic, &p.TopicKey, &p.SourceURL, &p.Session, &p.SizeBytes, &p.DurationMS)
	if errors.Is(err, pgx.ErrNoRows) {
		return p, ErrNotFound
	}
	return p, err
}
func (b *BaleImports) SetBaleTopicError(ctx context.Context, r BaleTopicRequest, reason string) error {
	_, err := b.pool.Exec(ctx, `UPDATE bale_topic_requests SET state='blocked',error=$3 WHERE owner_id::text=$1 AND topic_key=$2 AND requested_at=$4`, r.OwnerID, r.Key, reason, r.RequestedAt)
	return err
}
func (b *BaleImports) FinishBaleTopic(ctx context.Context, r BaleTopicRequest) error {
	// Keep following the topic until the whole scan is complete. A click while
	// discovery is in progress includes sessions found later in the history.
	_, err := b.pool.Exec(ctx, `UPDATE bale_topic_requests r SET state=CASE WHEN EXISTS(
 SELECT 1 FROM bale_catalog_posts c JOIN bot_imports i ON i.message_id=c.message_id AND i.provider='bale_archive' AND i.user_id=r.owner_id WHERE c.topic_key=r.topic_key AND i.state='failed') THEN 'blocked' ELSE 'done' END,
 error=CASE WHEN EXISTS(SELECT 1 FROM bale_catalog_posts c JOIN bot_imports i ON i.message_id=c.message_id AND i.provider='bale_archive' AND i.user_id=r.owner_id WHERE c.topic_key=r.topic_key AND i.state='failed') THEN 'import_failed' ELSE NULL END
 WHERE r.owner_id::text=$1 AND r.topic_key=$2 AND r.requested_at=$3 AND (SELECT state FROM bale_catalog_scan WHERE id)='done'
 AND NOT EXISTS(SELECT 1 FROM bale_catalog_posts c LEFT JOIN bot_imports i ON i.message_id=c.message_id AND i.provider='bale_archive' AND i.user_id=r.owner_id WHERE c.topic_key=r.topic_key AND (i.id IS NULL OR i.state IN('queued','downloading')))`, r.OwnerID, r.Key, r.RequestedAt)
	return err
}

func (b *BaleImports) BaleTopicFailure(ctx context.Context, r BaleTopicRequest) (string, error) {
	var reason string
	err := b.pool.QueryRow(ctx, `SELECT COALESCE(i.error,'import_failed') FROM bot_imports i JOIN bale_catalog_posts c ON c.message_id=i.message_id WHERE i.provider='bale_archive' AND i.user_id::text=$1 AND c.topic_key=$2 AND i.state='failed' AND i.updated_at>=$3 ORDER BY i.updated_at LIMIT 1`, r.OwnerID, r.Key, r.RequestedAt).Scan(&reason)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", nil
	}
	return reason, err
}
