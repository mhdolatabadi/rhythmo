package store

import (
	"errors"
	"testing"
)

func TestStorageRequestApproveRaisesQuotaAndAudits(t *testing.T) {
	f := newCatalogFixture(t)
	user, admin := f.user("asker@example.com"), f.user("admin@example.com")
	if _, err := f.users.LatestStorageRequest(f.ctx, user.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("no request yet: %v", err)
	}
	request, err := f.users.RequestStorage(f.ctx, user.ID, 512, "پادکست‌های زیادی دارم")
	if err != nil || request.Status != StorageRequestPending {
		t.Fatalf("request %+v %v", request, err)
	}
	if _, err := f.users.RequestStorage(f.ctx, user.ID, 1024, ""); !errors.Is(err, ErrStorageRequestOpen) {
		t.Fatalf("second open request: %v", err)
	}
	pending, err := f.users.PendingStorageRequests(f.ctx, 10, 128)
	if err != nil || len(pending) != 1 || pending[0].Email != "asker@example.com" || pending[0].QuotaBytes != 128 {
		t.Fatalf("pending %+v %v", pending, err)
	}
	if _, err := f.users.DecideStorageRequest(f.ctx, request.ID, admin.ID, true, 100, "", 128); !errors.Is(err, ErrQuotaDecrease) {
		t.Fatalf("lower grant: %v", err)
	}
	decided, err := f.users.DecideStorageRequest(f.ctx, request.ID, admin.ID, true, 256, "", 128)
	if err != nil || decided.Status != StorageRequestApproved || decided.GrantedBytes == nil || *decided.GrantedBytes != 256 {
		t.Fatalf("approve %+v %v", decided, err)
	}
	if quota, err := f.tracks.QuotaForOwner(f.ctx, user.ID, 128); err != nil || quota != 256 {
		t.Fatalf("quota %d %v", quota, err)
	}
	var count int
	if err := f.users.pool.QueryRow(f.ctx, `SELECT count(*) FROM account_storage_quota_audit WHERE account_id=$1::uuid AND actor_id=$2::uuid AND quota_bytes=256`, user.ID, admin.ID).Scan(&count); err != nil || count != 1 {
		t.Fatalf("audit %d %v", count, err)
	}
	if _, err := f.users.DecideStorageRequest(f.ctx, request.ID, admin.ID, false, 0, "", 128); !errors.Is(err, ErrNotPending) {
		t.Fatalf("decided twice: %v", err)
	}
	if pending, _ := f.users.PendingStorageRequests(f.ctx, 10, 128); len(pending) != 0 {
		t.Fatalf("queue not empty: %+v", pending)
	}
}

func TestStorageRequestRejectKeepsQuotaAndAllowsNewAsk(t *testing.T) {
	f := newCatalogFixture(t)
	user, admin := f.user("asker@example.com"), f.user("admin@example.com")
	request, err := f.users.RequestStorage(f.ctx, user.ID, 512, "")
	if err != nil {
		t.Fatal(err)
	}
	decided, err := f.users.DecideStorageRequest(f.ctx, request.ID, admin.ID, false, 0, "فعلاً فضای کافی نداریم", 128)
	if err != nil || decided.Status != StorageRequestRejected || decided.DecisionReason == nil || *decided.DecisionReason != "فعلاً فضای کافی نداریم" {
		t.Fatalf("reject %+v %v", decided, err)
	}
	if quota, _ := f.tracks.QuotaForOwner(f.ctx, user.ID, 128); quota != 128 {
		t.Fatalf("quota changed on reject: %d", quota)
	}
	latest, err := f.users.LatestStorageRequest(f.ctx, user.ID)
	if err != nil || latest.ID != request.ID || latest.Status != StorageRequestRejected {
		t.Fatalf("latest %+v %v", latest, err)
	}
	if _, err := f.users.RequestStorage(f.ctx, user.ID, 512, ""); err != nil {
		t.Fatalf("ask again after reject: %v", err)
	}
	if _, err := f.users.DecideStorageRequest(f.ctx, "not-a-uuid", admin.ID, false, 0, "", 128); !errors.Is(err, ErrNotPending) {
		t.Fatalf("unknown id: %v", err)
	}
}
