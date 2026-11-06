package store

import (
	"context"
	"errors"
	"github.com/jackc/pgx/v5"
)

var ErrQuotaDecrease = errors.New("storage capacity can only be increased")

type quotaQuery interface {
	QueryRow(context.Context, string, ...any) pgx.Row
}

func effectiveQuota(ctx context.Context, q quotaQuery, userID string, fallback int64) (int64, error) {
	var quota int64
	err := q.QueryRow(ctx, `SELECT COALESCE(storage_quota_bytes,$2) FROM users WHERE id::text=$1`, userID, fallback).Scan(&quota)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, ErrNotFound
	}
	return quota, err
}
func (t *Tracks) QuotaForOwner(ctx context.Context, userID string, fallback int64) (int64, error) {
	return effectiveQuota(ctx, t.pool, userID, fallback)
}
func (u *Users) SetStorageQuota(ctx context.Context, id, actor string, bytes, fallback int64) (User, error) {
	var user User
	err := pgx.BeginFunc(ctx, u.pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,0))`, id); err != nil {
			return err
		}
		previous, err := effectiveQuota(ctx, tx, id, fallback)
		if err != nil {
			return err
		}
		if bytes < previous {
			return ErrQuotaDecrease
		}
		if err := scanUser(tx.QueryRow(ctx, `UPDATE users SET storage_quota_bytes=$2 WHERE id::text=$1 RETURNING `+userColumns, id, bytes), &user); err != nil {
			return err
		}
		if bytes == previous {
			return nil
		}
		_, err = tx.Exec(ctx, `INSERT INTO account_storage_quota_audit(account_id,actor_id,previous_bytes,quota_bytes) VALUES($1::text::uuid,$2::text::uuid,$3,$4)`, id, actor, previous, bytes)
		return err
	})
	return user, err
}
