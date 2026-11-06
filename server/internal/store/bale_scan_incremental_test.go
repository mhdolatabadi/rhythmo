package store

import (
	"context"
	"testing"
)

func TestBaleScanRefreshOnlyReadsPostsNewerThanTheLastCompletePass(t *testing.T) {
	ctx := context.Background()
	pool := newTestPool(t)
	b := NewBaleImports(pool)
	if err := b.EnsureBaleScan(ctx); err != nil {
		t.Fatal(err)
	}
	lecture := func(id string, date int64) BaleLecture {
		return BaleLecture{MessageID: id, Date: date, Title: "موضوع", Topic: "موضوع", TopicKey: "موضوع", FileName: id + ".mp3", SizeBytes: 1}
	}
	claim, ok, err := b.ClaimBaleScan(ctx)
	if err != nil || !ok || claim.Floor != 0 {
		t.Fatal("first claim", claim, ok, err)
	}
	// First complete pass: two pages, newest first, then the channel start.
	if err = b.SaveBalePage(ctx, claim, []BaleLecture{lecture("3", 3000), lecture("2", 2000)}, 2000, false, 2); err != nil {
		t.Fatal(err)
	}
	claim, _, _ = b.ClaimBaleScan(ctx)
	if err = b.SaveBalePage(ctx, claim, []BaleLecture{lecture("1", 1000)}, 1000, false, 1); err != nil {
		t.Fatal(err)
	}
	claim, _, _ = b.ClaimBaleScan(ctx)
	if err = b.SaveBalePage(ctx, claim, nil, 0, true, 0); err != nil {
		t.Fatal(err)
	}
	if _, ok, _ := b.ClaimBaleScan(ctx); ok {
		t.Fatal("finished scan must stay finished until refreshed")
	}
	// Refresh: start at the newest post again, but stop at the previous newest.
	if err = b.RefreshBaleScan(ctx); err != nil {
		t.Fatal(err)
	}
	claim, ok, err = b.ClaimBaleScan(ctx)
	if err != nil || !ok || claim.Before != 0 || claim.Floor != 3000 {
		t.Fatal("incremental claim", claim, ok, err)
	}
	catalog, err := b.BaleCatalog(ctx, "00000000-0000-0000-0000-000000000000")
	if err != nil || !catalog.Scan.Incremental || catalog.Scan.Scanned != 0 {
		t.Fatalf("incremental catalog %+v %v", catalog.Scan, err)
	}
	// A page of new posts that hasn't reached the floor yet continues.
	if err = b.SaveBalePage(ctx, claim, []BaleLecture{lecture("5", 5000), lecture("4", 4000)}, 4000, false, 2); err != nil {
		t.Fatal(err)
	}
	claim, ok, _ = b.ClaimBaleScan(ctx)
	if !ok || claim.Before != 4000 || claim.Floor != 3000 {
		t.Fatal("continue", claim, ok)
	}
	// The next page reaches already indexed history: the pass ends there.
	if err = b.SaveBalePage(ctx, claim, []BaleLecture{lecture("3", 3000)}, 3000, false, 1); err != nil {
		t.Fatal(err)
	}
	if _, ok, _ := b.ClaimBaleScan(ctx); ok {
		t.Fatal("pass must end at the floor")
	}
	catalog, _ = b.BaleCatalog(ctx, "00000000-0000-0000-0000-000000000000")
	if catalog.Scan.State != "done" || catalog.Scan.Incremental || len(catalog.Topics) != 1 || catalog.Topics[0].Total != 5 {
		t.Fatalf("after incremental %+v", catalog)
	}
	// The next refresh starts from the newest post of the incremental pass.
	if err = b.RefreshBaleScan(ctx); err != nil {
		t.Fatal(err)
	}
	claim, _, _ = b.ClaimBaleScan(ctx)
	if claim.Floor != 5000 {
		t.Fatal("watermark not advanced", claim)
	}
	// With nothing new, the first page already reaches the floor.
	if err = b.SaveBalePage(ctx, claim, []BaleLecture{lecture("5", 5000)}, 5000, false, 1); err != nil {
		t.Fatal(err)
	}
	if _, ok, _ := b.ClaimBaleScan(ctx); ok {
		t.Fatal("no-op refresh kept scanning")
	}
}
