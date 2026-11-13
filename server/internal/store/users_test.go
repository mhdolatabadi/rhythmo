package store

import (
	"context"
	"errors"
	"os"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
)

// newTestPool connects to TEST_DATABASE_URL, a disposable database the test may
// wipe. The tests are skipped when it is not set.
func newTestPool(t *testing.T) *pgxpool.Pool {
	t.Helper()
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("TEST_DATABASE_URL is not set")
	}
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	// Dropping the schema removes every table, including ones later
	// migrations add, so this never needs a list kept up to date.
	if _, err := pool.Exec(ctx, "DROP SCHEMA public CASCADE; CREATE SCHEMA public"); err != nil {
		t.Fatal(err)
	}
	if err := Migrate(ctx, pool); err != nil {
		t.Fatal(err)
	}
	return pool
}

func TestMigrateIsIdempotent(t *testing.T) {
	pool := newTestPool(t)
	if err := Migrate(context.Background(), pool); err != nil {
		t.Fatalf("second migration run failed: %v", err)
	}
}

func TestUsers(t *testing.T) {
	ctx := context.Background()
	users := NewUsers(newTestPool(t))

	created, err := users.Create(ctx, "a@example.com", "hash")
	if err != nil {
		t.Fatal(err)
	}
	if created.ID == "" || created.CreatedAt.IsZero() {
		t.Fatalf("incomplete user: %+v", created)
	}
	if _, err := users.Create(ctx, "a@example.com", "other"); !errors.Is(err, ErrEmailTaken) {
		t.Fatalf("expected ErrEmailTaken, got %v", err)
	}

	byEmail, hash, err := users.ByEmail(ctx, "a@example.com")
	if err != nil || byEmail.ID != created.ID || hash != "hash" {
		t.Fatalf("ByEmail = %+v, %q, %v", byEmail, hash, err)
	}
	if _, _, err := users.ByEmail(ctx, "b@example.com"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("expected ErrNotFound, got %v", err)
	}

	byID, err := users.ByID(ctx, created.ID)
	if err != nil || byID.Email != "a@example.com" {
		t.Fatalf("ByID = %+v, %v", byID, err)
	}
	for _, id := range []string{"00000000-0000-0000-0000-000000000000", "not-a-uuid"} {
		if _, err := users.ByID(ctx, id); !errors.Is(err, ErrNotFound) {
			t.Fatalf("ByID(%q): expected ErrNotFound, got %v", id, err)
		}
	}
}

func TestRevokeSessionsMovesTheEpochOn(t *testing.T) {
	ctx := context.Background()
	users := NewUsers(newTestPool(t))
	created, err := users.Create(ctx, "epoch@example.com", "hash")
	if err != nil || created.SessionEpoch != 0 {
		t.Fatalf("Create = %+v, %v", created, err)
	}
	revoked, err := users.RevokeSessions(ctx, created.ID)
	if err != nil || revoked.SessionEpoch != 1 || revoked.Email != created.Email {
		t.Fatalf("RevokeSessions = %+v, %v", revoked, err)
	}
	if epoch, err := users.SessionEpoch(ctx, created.ID); err != nil || epoch != 1 {
		t.Fatalf("SessionEpoch = %d, %v", epoch, err)
	}
	if byEmail, _, _ := users.ByEmail(ctx, created.Email); byEmail.SessionEpoch != 1 {
		t.Fatalf("ByEmail epoch = %d", byEmail.SessionEpoch)
	}
	if byID, _ := users.ByID(ctx, created.ID); byID.SessionEpoch != 1 {
		t.Fatalf("ByID epoch = %d", byID.SessionEpoch)
	}
	for _, id := range []string{"00000000-0000-0000-0000-000000000000", "not-a-uuid"} {
		if _, err := users.SessionEpoch(ctx, id); !errors.Is(err, ErrNotFound) {
			t.Fatalf("SessionEpoch(%q) = %v", id, err)
		}
		if _, err := users.RevokeSessions(ctx, id); !errors.Is(err, ErrNotFound) {
			t.Fatalf("RevokeSessions(%q) = %v", id, err)
		}
	}
}

func TestDisplayNameIsWhatSharedViewsShow(t *testing.T) {
	ctx := context.Background()
	pool := newTestPool(t)
	users := NewUsers(pool)
	owner, _ := users.Create(ctx, "named@example.com", "hash")
	named, err := users.SetDisplayName(ctx, owner.ID, "نیما")
	if err != nil || named.DisplayName != "نیما" {
		t.Fatalf("set name = %+v, %v", named, err)
	}
	if again, _ := users.ByID(ctx, owner.ID); again.DisplayName != "نیما" {
		t.Fatalf("stored name = %q", again.DisplayName)
	}
	playlists := NewPlaylists(pool)
	playlist, err := playlists.Create(ctx, owner.ID, "named mix")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := playlists.Share(ctx, owner.ID, playlist.ID, "named-token", nil, true); err != nil {
		t.Fatal(err)
	}
	if view, err := playlists.ForShareToken(ctx, "named-token"); err != nil || view.OwnerName != "نیما" {
		t.Fatalf("shared view owner = %q, %v", view.OwnerName, err)
	}
	if cleared, err := users.SetDisplayName(ctx, owner.ID, ""); err != nil || cleared.DisplayName != "" {
		t.Fatalf("clear name = %+v, %v", cleared, err)
	}
	if _, err := users.SetDisplayName(ctx, "00000000-0000-0000-0000-000000000000", "x"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("unknown user = %v", err)
	}
}
