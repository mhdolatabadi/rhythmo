package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// Storage request states (#208).
const (
	StorageRequestPending  = "pending"
	StorageRequestApproved = "approved"
	StorageRequestRejected = "rejected"
)

// ErrStorageRequestOpen means the account already has a request waiting.
var ErrStorageRequestOpen = errors.New("a storage request is already open")

// StorageRequest is one account's ask for more storage.
type StorageRequest struct {
	ID             string
	AccountID      string
	RequestedBytes int64
	Reason         string
	Status         string
	GrantedBytes   *int64
	DecisionReason *string
	DecidedAt      *time.Time
	CreatedAt      time.Time
}

// PendingStorageRequest is a request in the admin queue, with the account's
// address, what it uses and what it may use now.
type PendingStorageRequest struct {
	StorageRequest
	Email      string
	UsedBytes  int64
	QuotaBytes int64
}

const storageRequestColumns = `storage_requests.id::text, storage_requests.account_id::text, requested_bytes, reason,
	status, granted_bytes, decision_reason, decided_at, storage_requests.created_at`

func scanStorageRequest(row pgx.Row, r *StorageRequest, extra ...any) error {
	return row.Scan(append([]any{&r.ID, &r.AccountID, &r.RequestedBytes, &r.Reason, &r.Status,
		&r.GrantedBytes, &r.DecisionReason, &r.DecidedAt, &r.CreatedAt}, extra...)...)
}

// RequestStorage opens a request for the account to be allowed bytes in
// all. ErrStorageRequestOpen means one is already waiting.
func (u *Users) RequestStorage(ctx context.Context, accountID string, bytes int64, reason string) (StorageRequest, error) {
	var request StorageRequest
	err := scanStorageRequest(u.pool.QueryRow(ctx, `
		INSERT INTO storage_requests (account_id, requested_bytes, reason)
		VALUES ($1::text::uuid, $2, $3)
		RETURNING `+storageRequestColumns, accountID, bytes, reason), &request)
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == uniqueViolation {
		return StorageRequest{}, ErrStorageRequestOpen
	}
	return request, err
}

// LatestStorageRequest is the account's most recent request, or
// ErrNotFound when it never asked.
func (u *Users) LatestStorageRequest(ctx context.Context, accountID string) (StorageRequest, error) {
	var request StorageRequest
	err := scanStorageRequest(u.pool.QueryRow(ctx, `
		SELECT `+storageRequestColumns+` FROM storage_requests
		WHERE account_id::text = $1 ORDER BY created_at DESC, id LIMIT 1`, accountID), &request)
	if errors.Is(err, pgx.ErrNoRows) {
		return StorageRequest{}, ErrNotFound
	}
	return request, err
}

// PendingStorageRequests lists up to limit open requests, oldest first.
// fallback is the quota of accounts without their own.
func (u *Users) PendingStorageRequests(ctx context.Context, limit int, fallback int64) ([]PendingStorageRequest, error) {
	rows, err := u.pool.Query(ctx, `
		SELECT `+storageRequestColumns+`, users.email,
			(SELECT COALESCE(SUM(size_bytes), 0)::bigint FROM tracks WHERE tracks.owner_id = users.id),
			COALESCE(users.storage_quota_bytes, $2)
		FROM storage_requests JOIN users ON users.id = storage_requests.account_id
		WHERE status = 'pending'
		ORDER BY storage_requests.created_at, storage_requests.id
		LIMIT $1`, limit, fallback)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	pending := []PendingStorageRequest{}
	for rows.Next() {
		var p PendingStorageRequest
		if err := scanStorageRequest(rows, &p.StorageRequest, &p.Email, &p.UsedBytes, &p.QuotaBytes); err != nil {
			return nil, err
		}
		pending = append(pending, p)
	}
	return pending, rows.Err()
}

// DecideStorageRequest approves a pending request, raising the account's
// quota to bytes (audited like any quota change), or rejects it with an
// optional reason. ErrNotPending means it was decided already;
// ErrQuotaDecrease that bytes is not above the account's quota now.
func (u *Users) DecideStorageRequest(ctx context.Context, id, actorID string, approve bool, bytes int64, reason string, fallback int64) (StorageRequest, error) {
	var request StorageRequest
	err := pgx.BeginFunc(ctx, u.pool, func(tx pgx.Tx) error {
		err := scanStorageRequest(tx.QueryRow(ctx, `
			SELECT `+storageRequestColumns+` FROM storage_requests
			WHERE id::text = $1 AND status = 'pending' FOR UPDATE`, id), &request)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotPending
		}
		if err != nil {
			return err
		}
		status := StorageRequestRejected
		var granted *int64
		if approve {
			if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,0))`, request.AccountID); err != nil {
				return err
			}
			previous, err := effectiveQuota(ctx, tx, request.AccountID, fallback)
			if err != nil {
				return err
			}
			if bytes <= previous {
				return ErrQuotaDecrease
			}
			if _, err := tx.Exec(ctx, `UPDATE users SET storage_quota_bytes = $2 WHERE id::text = $1`, request.AccountID, bytes); err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, `INSERT INTO account_storage_quota_audit(account_id,actor_id,previous_bytes,quota_bytes)
				VALUES($1::text::uuid,$2::text::uuid,$3,$4)`, request.AccountID, actorID, previous, bytes); err != nil {
				return err
			}
			status, granted = StorageRequestApproved, &bytes
		}
		return scanStorageRequest(tx.QueryRow(ctx, `
			UPDATE storage_requests SET status = $2, granted_bytes = $3, decision_reason = NULLIF($4, ''),
				decided_by = $5::text::uuid, decided_at = now()
			WHERE id::text = $1
			RETURNING `+storageRequestColumns, id, status, granted, reason, actorID), &request)
	})
	return request, err
}
