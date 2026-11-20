package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/mhdolatabadi/rhythmo/server/internal/transcription"
)

type Transcriptions struct{ pool *pgxpool.Pool }
// TranscriptionQueueHealth exposes only aggregate operational counts.
// No user, track identifier or transcript appears in the diagnostic output.
type TranscriptionQueueHealth struct {
	Queued               int64
	Processing           int64
	Failed               int64
	OldestPendingSeconds int64
}

func (s *Transcriptions) QueueHealth(ctx context.Context) (TranscriptionQueueHealth, error) {
	var q TranscriptionQueueHealth
	err := s.pool.QueryRow(ctx, `
		SELECT
			count(*) FILTER (WHERE state = 'queued'),
			count(*) FILTER (WHERE state = 'processing'),
			count(*) FILTER (WHERE state = 'failed'),
			COALESCE(EXTRACT(EPOCH FROM
				(now() - MIN(updated_at) FILTER (WHERE state IN ('queued','processing')))), 0)::bigint
		FROM track_transcriptions
	`).Scan(&q.Queued, &q.Processing, &q.Failed, &q.OldestPendingSeconds)
	return q, err
}


func NewTranscriptions(pool *pgxpool.Pool) *Transcriptions { return &Transcriptions{pool} }
func (s *Transcriptions) Status(ctx context.Context, id string) (transcription.Result, error) {
	var r transcription.Result
	err := s.pool.QueryRow(ctx, `SELECT state, plain_text, synced_text FROM track_transcriptions WHERE track_id=$1::uuid`, id).Scan(&r.State, &r.Plain, &r.Synced)
	if errors.Is(err, pgx.ErrNoRows) {
		return transcription.Result{State: "idle"}, nil
	}
	return r, err
}

// Queue serializes per-owner limits with the user row, including simultaneous requests.
func (s *Transcriptions) Queue(ctx context.Context, owner, id string) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	var locked string
	if err = tx.QueryRow(ctx, `SELECT id::text FROM users WHERE id=$1::uuid FOR UPDATE`, owner).Scan(&locked); err != nil {
		return err
	}
	var count int
	if err = tx.QueryRow(ctx, `SELECT count(*) FROM track_transcriptions j JOIN tracks t ON t.id=j.track_id WHERE t.owner_id=$1::uuid AND j.state IN ('queued','processing') AND t.id<>$2::uuid`, owner, id).Scan(&count); err != nil {
		return err
	}
	if count >= 2 {
		return transcription.ErrBusy
	}
	_, err = tx.Exec(ctx, `INSERT INTO track_transcriptions(track_id,state) SELECT id,'queued' FROM tracks WHERE id=$1::uuid AND owner_id=$2::uuid AND status='ready'
 ON CONFLICT(track_id) DO UPDATE SET state='queued', plain_text='',synced_text='',updated_at=now() WHERE track_transcriptions.state='failed'`, id, owner)
	if err != nil {
		return err
	}
	return tx.Commit(ctx)
}
func (s *Transcriptions) Claim(ctx context.Context, lease time.Duration) (transcription.Job, bool, error) {
	var j transcription.Job
	err := s.pool.QueryRow(ctx, `WITH candidate AS (
 SELECT track_id FROM track_transcriptions WHERE state='queued' OR (state='processing' AND updated_at<$1) ORDER BY updated_at FOR UPDATE SKIP LOCKED LIMIT 1
 ), claimed AS (
 UPDATE track_transcriptions SET state='processing', updated_at=now() WHERE track_id IN (SELECT track_id FROM candidate) RETURNING track_id,updated_at
 ) SELECT t.id::text,t.storage_key,t.size_bytes,c.updated_at FROM claimed c JOIN tracks t ON t.id=c.track_id`, time.Now().Add(-lease)).Scan(&j.ID, &j.Key, &j.Size, &j.Lease)
	if errors.Is(err, pgx.ErrNoRows) {
		return j, false, nil
	}
	return j, err == nil, err
}
func (s *Transcriptions) Finish(ctx context.Context, j transcription.Job, r transcription.Result) error {
	// A deleted track or a newer lease cannot be resurrected by a late result.
	_, err := s.pool.Exec(ctx, `UPDATE track_transcriptions SET state=$3,plain_text=$4,synced_text=$5,updated_at=now() WHERE track_id=$1::uuid AND updated_at=$2 AND state='processing'`, j.ID, j.Lease, r.State, r.Plain, r.Synced)
	return err
}
