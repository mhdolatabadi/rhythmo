package store

import (
	"errors"
	"testing"
)

func TestAccountQuotaOverrideEnforcedByUploadReservation(t *testing.T) {
	f := newCatalogFixture(t)
	user, admin := f.user("quota@example.com"), f.user("admin@example.com")
	track := NewTrack{Title: "large", FileName: "song.mp3", ContentType: "audio/mpeg", SizeBytes: 200}
	if _, err := f.tracks.ReservePending(f.ctx, user.ID, track, 128, 5); !errors.Is(err, ErrQuotaExceeded) {
		t.Fatalf("default quota: %v", err)
	}
	if _, err := f.users.SetStorageQuota(f.ctx, user.ID, admin.ID, 512, 128); err != nil {
		t.Fatal(err)
	}
	if _, err := f.tracks.ReservePending(f.ctx, user.ID, track, 128, 5); err != nil {
		t.Fatalf("override ignored: %v", err)
	}
	track.SizeBytes = 400
	if _, err := f.tracks.ReservePending(f.ctx, user.ID, track, 128, 5); !errors.Is(err, ErrQuotaExceeded) {
		t.Fatalf("override boundary ignored: %v", err)
	}
	if quota, err := f.tracks.QuotaForOwner(f.ctx, user.ID, 128); err != nil || quota != 512 {
		t.Fatalf("quota %d %v", quota, err)
	}
	if _, err := f.users.SetStorageQuota(f.ctx, user.ID, admin.ID, 256, 128); !errors.Is(err, ErrQuotaDecrease) {
		t.Fatalf("quota decrease: %v", err)
	}
	var count int
	if err := f.users.pool.QueryRow(f.ctx, `SELECT count(*) FROM account_storage_quota_audit WHERE account_id=$1::uuid AND actor_id=$2::uuid`, user.ID, admin.ID).Scan(&count); err != nil || count != 1 {
		t.Fatalf("audit %d %v", count, err)
	}
}
