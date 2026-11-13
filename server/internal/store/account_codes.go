package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// SetPasswordResetCode replaces the outstanding password reset code of the
// account with this email. hash makes the stored hash from the account's
// id. It is ErrNotFound when no account has the address.
func (u *Users) SetPasswordResetCode(ctx context.Context, email string, hash func(userID string) string, expiresAt time.Time) (User, error) {
	var user User
	err := pgx.BeginFunc(ctx, u.pool, func(tx pgx.Tx) error {
		err := scanUser(tx.QueryRow(ctx,
			`SELECT `+userColumns+` FROM users WHERE email = $1 FOR UPDATE`, email,
		), &user)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		_, err = tx.Exec(ctx,
			`INSERT INTO password_reset_codes (user_id, email, code_hash, expires_at)
			 VALUES ($1::uuid, $2, $3, $4)
			 ON CONFLICT (user_id) DO UPDATE SET email = EXCLUDED.email,
			   code_hash = EXCLUDED.code_hash, expires_at = EXCLUDED.expires_at,
			   attempts = 0, created_at = now()`,
			user.ID, user.Email, hash(user.ID), expiresAt)
		return err
	})
	return user, err
}

// ResetPassword sets a new password hash for the account with this email
// when matches accepts the outstanding code. A wrong code uses up one of
// maxAttempts. On success the code is removed, every session ends (the
// session epoch moves on) and the address counts as verified, since the
// code proves the user reads it.
func (u *Users) ResetPassword(ctx context.Context, email string, now time.Time, maxAttempts int,
	matches func(userID, email, codeHash string) bool, passwordHash string) (User, error) {
	var user User
	tx, err := u.pool.Begin(ctx)
	if err != nil {
		return user, err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	err = scanUser(tx.QueryRow(ctx,
		`SELECT `+userColumns+` FROM users WHERE email = $1 FOR UPDATE`, email,
	), &user)
	if errors.Is(err, pgx.ErrNoRows) {
		return user, ErrNotFound
	}
	if err != nil {
		return user, err
	}
	var codeEmail, codeHash string
	var expiresAt time.Time
	var attempts int
	err = tx.QueryRow(ctx,
		`SELECT email, code_hash, expires_at, attempts FROM password_reset_codes WHERE user_id = $1::uuid`, user.ID,
	).Scan(&codeEmail, &codeHash, &expiresAt, &attempts)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && codeEmail != user.Email) {
		return user, ErrNoEmailCode
	}
	if err != nil {
		return user, err
	}
	if !now.Before(expiresAt) {
		return user, ErrEmailCodeExpired
	}
	if attempts >= maxAttempts {
		return user, ErrEmailCodeLocked
	}
	if !matches(user.ID, codeEmail, codeHash) {
		if _, err := tx.Exec(ctx,
			`UPDATE password_reset_codes SET attempts = attempts + 1 WHERE user_id = $1::uuid`, user.ID); err != nil {
			return user, err
		}
		if err := tx.Commit(ctx); err != nil {
			return user, err
		}
		return user, ErrEmailCodeMismatch
	}
	if _, err := tx.Exec(ctx, `DELETE FROM password_reset_codes WHERE user_id = $1::uuid`, user.ID); err != nil {
		return user, err
	}
	if err := scanUser(tx.QueryRow(ctx,
		`UPDATE users SET password_hash = $2, session_epoch = session_epoch + 1,
		   email_verified_at = COALESCE(email_verified_at, $3)
		 WHERE id = $1::uuid RETURNING `+userColumns,
		user.ID, passwordHash, now,
	), &user); err != nil {
		return user, err
	}
	return user, tx.Commit(ctx)
}

// SetPendingRegistration keeps a sign-up for email until its code is
// confirmed, replacing any earlier one for the address. Long-expired
// sign-ups are dropped on the way.
func (u *Users) SetPendingRegistration(ctx context.Context, email, passwordHash, codeHash string, expiresAt time.Time) error {
	return pgx.BeginFunc(ctx, u.pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx,
			`DELETE FROM pending_registrations WHERE expires_at < now() - interval '1 day'`); err != nil {
			return err
		}
		_, err := tx.Exec(ctx,
			`INSERT INTO pending_registrations (email, password_hash, code_hash, expires_at)
			 VALUES ($1, $2, $3, $4)
			 ON CONFLICT (email) DO UPDATE SET password_hash = EXCLUDED.password_hash,
			   code_hash = EXCLUDED.code_hash, expires_at = EXCLUDED.expires_at,
			   attempts = 0, created_at = now()`,
			email, passwordHash, codeHash, expiresAt)
		return err
	})
}

// ConfirmRegistration creates the account waiting for email once matches
// accepts its code; the address is verified from the start. A wrong code
// uses up one of maxAttempts. ErrEmailTaken means an account took the
// address meanwhile.
func (u *Users) ConfirmRegistration(ctx context.Context, email string, now time.Time, maxAttempts int,
	matches func(codeHash string) bool) (User, error) {
	var user User
	tx, err := u.pool.Begin(ctx)
	if err != nil {
		return user, err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	var passwordHash, codeHash string
	var expiresAt time.Time
	var attempts int
	err = tx.QueryRow(ctx,
		`SELECT password_hash, code_hash, expires_at, attempts FROM pending_registrations
		 WHERE email = $1 FOR UPDATE`, email,
	).Scan(&passwordHash, &codeHash, &expiresAt, &attempts)
	if errors.Is(err, pgx.ErrNoRows) {
		return user, ErrNoEmailCode
	}
	if err != nil {
		return user, err
	}
	if !now.Before(expiresAt) {
		return user, ErrEmailCodeExpired
	}
	if attempts >= maxAttempts {
		return user, ErrEmailCodeLocked
	}
	if !matches(codeHash) {
		if _, err := tx.Exec(ctx,
			`UPDATE pending_registrations SET attempts = attempts + 1 WHERE email = $1`, email); err != nil {
			return user, err
		}
		if err := tx.Commit(ctx); err != nil {
			return user, err
		}
		return user, ErrEmailCodeMismatch
	}
	if _, err := tx.Exec(ctx, `DELETE FROM pending_registrations WHERE email = $1`, email); err != nil {
		return user, err
	}
	err = scanUser(tx.QueryRow(ctx,
		`INSERT INTO users (email, password_hash, email_verified_at) VALUES ($1, $2, $3)
		 RETURNING `+userColumns,
		email, passwordHash, now,
	), &user)
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == uniqueViolation {
		return User{}, ErrEmailTaken
	}
	if err != nil {
		return user, err
	}
	return user, tx.Commit(ctx)
}
