package store

import (
	"context"
	"errors"
	"testing"
)

func TestBaleCatalogCompleteTopicImportsAndExistingRecognition(t *testing.T) {
	ctx := context.Background()
	pool := newTestPool(t)
	b := NewBaleImports(pool)
	owner, _ := NewUsers(pool).Create(ctx, "owner@example.com", "hash")
	other, _ := NewUsers(pool).Create(ctx, "other@example.com", "hash")
	if err := b.EnsureBaleScan(ctx); err != nil {
		t.Fatal(err)
	}
	claim, ok, err := b.ClaimBaleScan(ctx)
	if err != nil || !ok || claim.Before != 0 {
		t.Fatalf("claim %+v %v %v", claim, ok, err)
	}
	if _, ok, _ := b.ClaimBaleScan(ctx); ok {
		t.Fatal("overlapping scanner got lease")
	}
	posts := []BaleLecture{
		{MessageID: "13", Date: 1300, Title: "موضوع؛ جلسه سیزدهم", Topic: "موضوع", TopicKey: "موضوع", Session: 13, FileName: "13.mp3", SizeBytes: 100},
		{MessageID: "2", Date: 1200, Title: "موضوع؛ جلسه دوم", Topic: "موضوع", TopicKey: "موضوع", Session: 2, FileName: "2.mp3", SizeBytes: 100},
		{MessageID: "1", Date: 1100, Title: "فاطمیه؛ جلسه اول", Topic: "فاطمیه", TopicKey: "فاطمیه", Session: 1, FileName: "1.mp3", SizeBytes: 100},
	}
	if err = b.SaveBalePage(ctx, claim, posts, 1000, false, 10); err != nil {
		t.Fatal(err)
	}
	// A failed fetch preserves its last committed cursor and doesn't claim completion.
	claim, ok, err = b.ClaimBaleScan(ctx)
	if err != nil || !ok || claim.Before != 1000 {
		t.Fatal(claim, ok, err)
	}
	if err = b.FailBaleScan(ctx, claim.Token); err != nil {
		t.Fatal(err)
	}
	catalog, err := b.BaleCatalog(ctx, owner.ID)
	if err != nil || catalog.Scan.State != "scanning" || catalog.Scan.Error == nil || len(catalog.Topics) != 2 {
		t.Fatalf("catalog %+v %v", catalog, err)
	}
	if err = b.RefreshBaleScan(ctx); err != nil {
		t.Fatal(err)
	}
	claim, ok, err = b.ClaimBaleScan(ctx)
	if err != nil || !ok || claim.Before != 1000 {
		t.Fatal("resume", claim, ok, err)
	}
	// Request the complete topic while the historical scan is still in progress.
	if err = b.RequestBaleTopic(ctx, owner.ID, "موضوع"); err != nil {
		t.Fatal(err)
	}
	reqs, err := b.BaleTopicRequests(ctx)
	if err != nil || len(reqs) != 1 {
		t.Fatal(reqs, err)
	}
	r := reqs[0]
	next, err := b.NextBaleLecture(ctx, r)
	if err != nil || next.MessageID != "2" {
		t.Fatal("numeric order", next, err)
	}
	first, err := b.QueueBale(ctx, owner.ID, next, 1)
	if err != nil {
		t.Fatal(err)
	}
	next, err = b.NextBaleLecture(ctx, r)
	if err != nil || next.MessageID != "13" {
		t.Fatal(next, err)
	}
	if _, err = b.QueueBale(ctx, owner.ID, next, 1); !errors.Is(err, ErrArchiveBusy) {
		t.Fatal("capacity must wait", err)
	}
	// Mimic a completed earlier import: topic recognition uses durable post IDs.
	tr, err := NewTracks(pool).Create(ctx, owner.ID, NewTrack{Title: "موضوع؛ جلسه دوم", FileName: "2.mp3", ContentType: "audio/mpeg", SizeBytes: 100})
	if err != nil {
		t.Fatal(err)
	}
	if err = b.FinishImport(ctx, first.ID, &tr.ID, nil); err != nil {
		t.Fatal(err)
	}
	if err = b.FinishBaleTopic(ctx, r); err != nil {
		t.Fatal(err)
	}
	reqs, _ = b.BaleTopicRequests(ctx)
	if len(reqs) != 1 {
		t.Fatal("topic finished before discovery was complete")
	}
	// A later history page adds another session to the same requested topic.
	older := BaleLecture{MessageID: "1b", Date: 900, Title: "موضوع؛ جلسه اول", Topic: "موضوع", TopicKey: "موضوع", Session: 1, FileName: "1b.mp3", SizeBytes: 100}
	if err = b.SaveBalePage(ctx, claim, []BaleLecture{older}, 800, false, 10); err != nil {
		t.Fatal(err)
	}
	next, err = b.NextBaleLecture(ctx, r)
	if err != nil || next.MessageID != "1b" {
		t.Fatal("missed later-discovered session", next, err)
	}
	claim, ok, err = b.ClaimBaleScan(ctx)
	if err != nil || !ok {
		t.Fatal(err)
	}
	if err = b.SaveBalePage(ctx, claim, nil, 0, true, 0); err != nil {
		t.Fatal(err)
	}
	catalog, err = b.BaleCatalog(ctx, owner.ID)
	if err != nil || catalog.Scan.State != "done" {
		t.Fatal(catalog, err)
	}
	var selected BaleTopic
	for _, topic := range catalog.Topics {
		if topic.Key == "موضوع" {
			selected = topic
		}
	}
	if selected.Total != 3 || selected.Imported != 1 || selected.State != "importing" {
		t.Fatalf("lost requested topic state %+v", selected)
	}
	catalog, _ = b.BaleCatalog(ctx, other.ID)
	for _, topic := range catalog.Topics {
		if topic.Imported != 0 || topic.State != "available" {
			t.Fatalf("owner state leaked %+v", topic)
		}
	}
	// Complete the remaining sessions, then the request and status survive reopening.
	for {
		p, err := b.NextBaleLecture(ctx, r)
		if errors.Is(err, ErrNotFound) {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		j, err := b.QueueBale(ctx, owner.ID, p, 5)
		if err != nil {
			t.Fatal(err)
		}
		tr, err := NewTracks(pool).Create(ctx, owner.ID, NewTrack{Title: p.Title, FileName: p.FileName, ContentType: "audio/mpeg", SizeBytes: 100})
		if err != nil {
			t.Fatal(err)
		}
		if err = b.FinishImport(ctx, j.ID, &tr.ID, nil); err != nil {
			t.Fatal(err)
		}
	}
	if err = b.FinishBaleTopic(ctx, r); err != nil {
		t.Fatal(err)
	}
	reopened := NewBaleImports(pool)
	catalog, err = reopened.BaleCatalog(ctx, owner.ID)
	if err != nil {
		t.Fatal(err)
	}
	for _, topic := range catalog.Topics {
		if topic.Key == "موضوع" && (topic.Imported != 3 || topic.State != "imported") {
			t.Fatalf("not remembered %+v", topic)
		}
	}
	// Duplicate clicks and restarts cannot queue previously imported post identities.
	if err = b.RequestBaleTopic(ctx, owner.ID, "موضوع"); err != nil {
		t.Fatal(err)
	}
	reqs, _ = b.BaleTopicRequests(ctx)
	if len(reqs) != 1 {
		t.Fatal(reqs)
	}
	if _, err = b.NextBaleLecture(ctx, reqs[0]); !errors.Is(err, ErrNotFound) {
		t.Fatal("would reimport completed session", err)
	}
	if err = b.RequestBaleTopic(ctx, owner.ID, "unknown"); !errors.Is(err, ErrNotFound) {
		t.Fatal(err)
	}
	if err = b.FinishBaleTopic(ctx, reqs[0]); err != nil {
		t.Fatal(err)
	}
	if err = b.RefreshBaleScan(ctx); err != nil {
		t.Fatal(err)
	}
	claim, ok, err = b.ClaimBaleScan(ctx)
	if err != nil || !ok {
		t.Fatal(err)
	}
	newer := BaleLecture{MessageID: "14", Date: 1400, Title: "موضوع؛ جلسه چهاردهم", Topic: "موضوع", TopicKey: "موضوع", Session: 14, FileName: "14.mp3", SizeBytes: 100}
	if err = b.SaveBalePage(ctx, claim, []BaleLecture{newer}, 0, true, 1); err != nil {
		t.Fatal(err)
	}
	catalog, err = b.BaleCatalog(ctx, owner.ID)
	if err != nil {
		t.Fatal(err)
	}
	for _, topic := range catalog.Topics {
		if topic.Key == "موضوع" && (topic.State != "partial" || topic.Total != 4 || topic.Imported != 3) {
			t.Fatalf("new session not distinguished: %+v", topic)
		}
	}
	if err = b.RequestBaleTopic(ctx, owner.ID, "موضوع"); err != nil {
		t.Fatal(err)
	}
	reqs, _ = b.BaleTopicRequests(ctx)
	r = reqs[0]
	next, err = b.NextBaleLecture(ctx, r)
	if err != nil || next.MessageID != "14" {
		t.Fatal("old sessions requeued", next, err)
	}
	failed, err := b.QueueBale(ctx, owner.ID, next, 5)
	if err != nil {
		t.Fatal(err)
	}
	reason := "quota_exceeded"
	if err = b.FinishImport(ctx, failed.ID, nil, &reason); err != nil {
		t.Fatal(err)
	}
	got, err := b.BaleTopicFailure(ctx, r)
	if err != nil || got != reason {
		t.Fatal("quota stop not visible", got, err)
	}
	if err = b.SetBaleTopicError(ctx, r, got); err != nil {
		t.Fatal(err)
	}
	if err = b.RequestBaleTopic(ctx, owner.ID, "موضوع"); err != nil {
		t.Fatal(err)
	}
	reqs, _ = b.BaleTopicRequests(ctx)
	r = reqs[0]
	next, err = b.NextBaleLecture(ctx, r)
	if err != nil || next.MessageID != "14" {
		t.Fatal("failed session not retryable", next, err)
	}
	retried, err := b.QueueBale(ctx, owner.ID, next, 5)
	if err != nil || retried.ID != failed.ID {
		t.Fatal("retry duplicated import", retried, err)
	}

}
