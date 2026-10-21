package store

import (
	"context"
	"time"
)

type Feedback struct {
	ID        string    `json:"id"`
	Email     string    `json:"email"`
	Kind      string    `json:"kind"`
	Subject   string    `json:"subject"`
	Body      string    `json:"body"`
	CreatedAt time.Time `json:"created_at"`
}

func (u *Users) CreateFeedback(ctx context.Context, user, kind, subject, body string) error {
	_, err := u.pool.Exec(ctx, `INSERT INTO user_feedback(user_id,kind,subject,body) VALUES($1::uuid,$2,$3,$4)`, user, kind, subject, body)
	return err
}
func (u *Users) OpenFeedback(ctx context.Context) ([]Feedback, error) {
	rows, err := u.pool.Query(ctx, `SELECT f.id::text,u.email,f.kind,f.subject,f.body,f.created_at FROM user_feedback f JOIN users u ON u.id=f.user_id WHERE f.resolved_at IS NULL ORDER BY f.created_at,f.id LIMIT 100`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Feedback{}
	for rows.Next() {
		var f Feedback
		if err := rows.Scan(&f.ID, &f.Email, &f.Kind, &f.Subject, &f.Body, &f.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, f)
	}
	return out, rows.Err()
}
func (u *Users) ResolveFeedback(ctx context.Context, id, actor string) error {
	result, err := u.pool.Exec(ctx, `UPDATE user_feedback SET resolved_at=now(),resolved_by=$2::uuid WHERE id::text=$1 AND resolved_at IS NULL`, id, actor)
	if err == nil && result.RowsAffected() == 0 {
		return ErrNotFound
	}
	return err
}
