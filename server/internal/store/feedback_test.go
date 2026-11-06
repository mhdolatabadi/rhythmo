package store

import (
	"errors"
	"testing"
)

func TestFeedbackPersistenceAndResolution(t *testing.T) {
	f := newCatalogFixture(t)
	user, admin := f.user("sender@example.com"), f.user("admin@example.com")
	if err := f.users.CreateFeedback(f.ctx, user.ID, "bug", "مشکل پخش", "توضیحات"); err != nil {
		t.Fatal(err)
	}
	items, err := f.users.OpenFeedback(f.ctx)
	if err != nil || len(items) != 1 {
		t.Fatalf("inbox: %v %v", items, err)
	}
	item := items[0]
	if item.Email != user.Email || item.Kind != "bug" || item.Subject != "مشکل پخش" || item.CreatedAt.IsZero() {
		t.Fatal(item)
	}
	if err := f.users.ResolveFeedback(f.ctx, item.ID, admin.ID); err != nil {
		t.Fatal(err)
	}
	if items, err := f.users.OpenFeedback(f.ctx); err != nil || len(items) != 0 {
		t.Fatalf("resolved inbox: %v %v", items, err)
	}
	if err := f.users.ResolveFeedback(f.ctx, item.ID, admin.ID); !errors.Is(err, ErrNotFound) {
		t.Fatal(err)
	}
	var actor string
	if err := f.users.pool.QueryRow(f.ctx, `SELECT resolved_by::text FROM user_feedback WHERE id=$1::uuid AND resolved_at IS NOT NULL`, item.ID).Scan(&actor); err != nil || actor != admin.ID {
		t.Fatalf("audit: %s %v", actor, err)
	}
}
