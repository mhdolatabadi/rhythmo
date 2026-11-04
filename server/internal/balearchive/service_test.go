package balearchive

import (
	"context"
	"errors"
	"testing"

	"github.com/mhdolatabadi/rhythmo/server/internal/bot"
	"github.com/mhdolatabadi/rhythmo/server/internal/linkimport"
	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

type fakeSource struct{ messages []linkimport.BaleMessage }

func (f fakeSource) BaleHistory(context.Context, int64) (linkimport.BalePage, error) {
	return linkimport.BalePage{Messages: f.messages, NextBefore: 123}, nil
}
func (f fakeSource) BalePost(_ context.Context, rid string, _ int64) (linkimport.BaleMessage, error) {
	for _, m := range f.messages {
		if m.RID == rid {
			return m, nil
		}
	}
	return linkimport.BaleMessage{}, linkimport.ErrNoAudio
}

type fakeArchiveStore struct {
	ArchiveStore
	lectures []store.BaleLecture
}

func (f *fakeArchiveStore) QueueBale(_ context.Context, _ string, l store.BaleLecture, _ int) (store.BotImport, error) {
	f.lectures = append(f.lectures, l)
	return store.BotImport{ID: l.MessageID}, nil
}
func TestServiceGroupsTopicsAndRefetchesBeforeQueueing(t *testing.T) {
	m1 := message("🎙 #سخنرانی_کامل\n📋 ما و حضرت ولی‌عصر؛ جلسه سیزدهم", "audio/mpeg")
	m1.RID = "13"
	m2 := message("🎙 #سخنرانی_کامل\n📋 فاطمیه دقیقاً چیست؟ - جلسه اول", "audio/mpeg")
	m2.RID = "1"
	clip := message("🎙 #کلیپ", "audio/mpeg")
	clip.RID = "3"
	ambiguous := message("🎙 #سخنرانی_کامل", "audio/mpeg")
	ambiguous.RID = "4"
	src := fakeSource{[]linkimport.BaleMessage{m1, m2, clip, ambiguous}}
	db := &fakeArchiveStore{}
	media := linkimport.NewProvider(linkimport.NewFetcher(), 1000)
	svc := New(src, media, db, nil, nil, bot.UploadPolicy{Enabled: true, MaxFileBytes: 1000, MaxPending: 5})
	page, err := svc.Preview(context.Background(), 0)
	if err != nil || len(page.Entries) != 3 || !page.Entries[2].NeedsReview {
		t.Fatalf("preview %+v %v", page, err)
	}
	for _, m := range []linkimport.BaleMessage{m1, m2} {
		if _, err = svc.Submit(context.Background(), "owner", m.RID, m.Date, "", 0); err != nil {
			t.Fatal(err)
		}
	}
	if db.lectures[0].TopicKey == db.lectures[1].TopicKey || db.lectures[0].Session != 13 || db.lectures[1].Session != 1 {
		t.Fatalf("wrong grouping %+v", db.lectures)
	}
	if _, err = svc.Submit(context.Background(), "owner", clip.RID, clip.Date, "موضوع", 1); !errors.Is(err, linkimport.ErrNoAudio) {
		t.Fatal("client could bypass markers", err)
	}
	if _, err = svc.Submit(context.Background(), "owner", ambiguous.RID, ambiguous.Date, "", 0); !errors.Is(err, ErrTopic) {
		t.Fatal("ambiguous topic accepted", err)
	}
	if _, err = svc.Submit(context.Background(), "owner", ambiguous.RID, ambiguous.Date, "موضوع", 0); !errors.Is(err, ErrSession) {
		t.Fatal("ambiguous session accepted", err)
	}
	if _, err = svc.Submit(context.Background(), "owner", ambiguous.RID, ambiguous.Date, "موضوع", 2); err != nil {
		t.Fatal("review refused", err)
	}
	svc = New(src, media, db, nil, nil, bot.UploadPolicy{Enabled: false, MaxFileBytes: 1000, MaxPending: 5})
	if _, err = svc.Submit(context.Background(), "owner", m1.RID, m1.Date, "", 0); !errors.Is(err, linkimport.ErrDisabled) {
		t.Fatal("uploads policy bypassed", err)
	}
	svc = New(src, media, db, nil, nil, bot.UploadPolicy{Enabled: true, MaxFileBytes: 10, MaxPending: 5})
	if _, err = svc.Submit(context.Background(), "owner", m1.RID, m1.Date, "", 0); !errors.Is(err, linkimport.ErrTooLarge) {
		t.Fatal("size policy bypassed", err)
	}
}
