package balearchive

import (
	"context"
	"github.com/mhdolatabadi/rhythmo/server/internal/bot"
	"github.com/mhdolatabadi/rhythmo/server/internal/linkimport"
	"github.com/mhdolatabadi/rhythmo/server/internal/store"
	"testing"
)

type scanDB struct {
	CatalogStore
	claim   store.BaleScanClaim
	saved   []store.BaleLecture
	failed  bool
	next    int64
	scanned int
}

func (d *scanDB) ClaimBaleScan(context.Context) (store.BaleScanClaim, bool, error) {
	return d.claim, true, nil
}
func (d *scanDB) SaveBalePage(_ context.Context, _ store.BaleScanClaim, p []store.BaleLecture, next int64, _ bool, n int) error {
	d.saved = p
	d.next = next
	d.scanned = n
	return nil
}
func (d *scanDB) FailBaleScan(context.Context, string) error { d.failed = true; return nil }
func TestCatalogScanIndexesOnlyFullLecturesAndStopsOnStuckCursor(t *testing.T) {
	full := message("🎙 #سخنرانی_کامل\n📋 موضوع؛ جلسه دوم", "audio/mpeg")
	clip := message("🎙 #کلیپ", "audio/mpeg")
	clip.RID = "clip"
	s := &Service{source: fakeSource{[]linkimport.BaleMessage{full, clip}}}
	db := &scanDB{claim: store.BaleScanClaim{Token: "lease"}}
	s.scanStep(context.Background(), db)
	if db.failed || len(db.saved) != 1 || db.saved[0].TopicKey != "موضوع" || db.saved[0].Session != 2 || db.scanned != 2 || db.next != 123 {
		t.Fatalf("bad scan %+v", db)
	}
	db = &scanDB{claim: store.BaleScanClaim{Token: "lease", Before: 100}}
	s.scanStep(context.Background(), db)
	if !db.failed || len(db.saved) != 0 {
		t.Fatal("stuck history was marked successful")
	}
}

type fullQueue struct {
	ArchiveStore
	calls int
}

func (q *fullQueue) QueueBale(context.Context, string, store.BaleLecture, int) (store.BotImport, error) {
	q.calls++
	return store.BotImport{}, store.ErrArchiveBusy
}

type topicDB struct {
	CatalogStore
	blocked  bool
	finished bool
}

func (d *topicDB) BaleTopicRequests(context.Context) ([]store.BaleTopicRequest, error) {
	return []store.BaleTopicRequest{{OwnerID: "owner", Key: "موضوع"}}, nil
}
func (d *topicDB) BaleTopicFailure(context.Context, store.BaleTopicRequest) (string, error) {
	return "", nil
}
func (d *topicDB) NextBaleLecture(context.Context, store.BaleTopicRequest) (store.BaleLecture, error) {
	return store.BaleLecture{FileName: "a.mp3", SizeBytes: 100}, nil
}
func (d *topicDB) SetBaleTopicError(context.Context, store.BaleTopicRequest, string) error {
	d.blocked = true
	return nil
}
func (d *topicDB) FinishBaleTopic(context.Context, store.BaleTopicRequest) error {
	d.finished = true
	return nil
}
func TestWholeTopicWaitsForQueueCapacityInsteadOfFailing(t *testing.T) {
	q := &fullQueue{}
	d := &topicDB{}
	media := linkimport.NewProvider(linkimport.NewFetcher(), 1000)
	s := New(fakeSource{}, media, q, nil, nil, bot.UploadPolicy{Enabled: true, MaxFileBytes: 1000, MaxPending: 1})
	s.topicStep(context.Background(), d)
	if q.calls != 1 || d.blocked || d.finished {
		t.Fatal("capacity wait lost durable request")
	}
}
