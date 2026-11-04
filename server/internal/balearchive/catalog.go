package balearchive

import (
	"context"
	"errors"
	"github.com/mhdolatabadi/rhythmo/server/internal/audio"
	"github.com/mhdolatabadi/rhythmo/server/internal/bot"
	"github.com/mhdolatabadi/rhythmo/server/internal/linkimport"
	"github.com/mhdolatabadi/rhythmo/server/internal/store"
	"time"
)

type CatalogStore interface {
	EnsureBaleScan(context.Context) error
	RefreshBaleScan(context.Context) error
	ClaimBaleScan(context.Context) (store.BaleScanClaim, bool, error)
	SaveBalePage(context.Context, store.BaleScanClaim, []store.BaleLecture, int64, bool, int) error
	FailBaleScan(context.Context, string) error
	BaleCatalog(context.Context, string) (store.BaleCatalog, error)
	RequestBaleTopic(context.Context, string, string) error
	BaleTopicRequests(context.Context) ([]store.BaleTopicRequest, error)
	NextBaleLecture(context.Context, store.BaleTopicRequest) (store.BaleLecture, error)
	SetBaleTopicError(context.Context, store.BaleTopicRequest, string) error
	FinishBaleTopic(context.Context, store.BaleTopicRequest) error
	BaleTopicFailure(context.Context, store.BaleTopicRequest) (string, error)
}

func (s *Service) Catalog(ctx context.Context, userID string) (store.BaleCatalog, error) {
	db, ok := s.imports.(CatalogStore)
	if !ok {
		return store.BaleCatalog{}, linkimport.ErrDisabled
	}
	if err := db.EnsureBaleScan(ctx); err != nil {
		return store.BaleCatalog{}, err
	}
	return db.BaleCatalog(ctx, userID)
}
func (s *Service) RefreshCatalog(ctx context.Context) error {
	db, ok := s.imports.(CatalogStore)
	if !ok {
		return linkimport.ErrDisabled
	}
	return db.RefreshBaleScan(ctx)
}
func (s *Service) ImportTopic(ctx context.Context, userID, key string) error {
	db, ok := s.imports.(CatalogStore)
	if !ok {
		return linkimport.ErrDisabled
	}
	if !ValidTopic(key) {
		return ErrTopic
	}
	return db.RequestBaleTopic(ctx, userID, Normalize(key))
}
func (s *Service) scanStep(ctx context.Context, db CatalogStore) {
	claim, ok, err := db.ClaimBaleScan(ctx)
	if err != nil || !ok {
		return
	}
	page, err := s.source.BaleHistory(ctx, claim.Before)
	if err != nil || (!page.Done && (page.NextBefore <= 0 || (claim.Before > 0 && page.NextBefore >= claim.Before))) {
		db.FailBaleScan(ctx, claim.Token)
		return
	}
	posts := []store.BaleLecture{}
	for _, m := range page.Messages {
		if !FullLecture(m) {
			continue
		}
		d := m.Message.Document
		e := entry(m)
		if !linkimport.BaleMediaURL(d.URL) {
			continue
		}
		name := bot.FileName(bot.File{Name: d.Name, MIMEType: d.MIMEType})
		if _, ok := audio.ContentType(name); !ok {
			continue
		}
		key := Normalize(e.Topic)
		if !ValidTopic(key) {
			key = ""
		}
		posts = append(posts, store.BaleLecture{MessageID: e.ID, Date: e.Date, Title: e.Title, Topic: e.Topic, TopicKey: key, Session: e.Session, FileName: audio.SafeFileName(name), SizeBytes: e.SizeBytes, DurationMS: e.DurationMS, Caption: d.Caption.Text, SourceURL: e.SourceURL})
	}
	if err := db.SaveBalePage(ctx, claim, posts, page.NextBefore, page.Done, len(page.Messages)); err != nil {
		db.FailBaleScan(ctx, claim.Token)
	}
}
func (s *Service) topicStep(ctx context.Context, db CatalogStore) {
	requests, err := db.BaleTopicRequests(ctx)
	if err != nil {
		return
	}
	for _, r := range requests {
		if ctx.Err() != nil {
			return
		}
		reason, err := db.BaleTopicFailure(ctx, r)
		if err != nil {
			continue
		}
		if reason != "" {
			db.SetBaleTopicError(ctx, r, reason)
			continue
		}
		lecture, err := db.NextBaleLecture(ctx, r)
		if errors.Is(err, store.ErrNotFound) {
			db.FinishBaleTopic(ctx, r)
			continue
		}
		if err != nil {
			continue
		}
		if reason := s.importer.Check(s.provider, bot.File{Name: lecture.FileName, SizeBytes: lecture.SizeBytes}); reason != "" {
			db.SetBaleTopicError(ctx, r, reason)
			continue
		}
		_, err = s.imports.QueueBale(ctx, r.OwnerID, lecture, s.maxActive)
		if err != nil && !errors.Is(err, store.ErrArchiveBusy) {
			db.SetBaleTopicError(ctx, r, "import_failed")
		}
	}
}
func (s *Service) catalogWorker(ctx context.Context, db CatalogStore) {
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	for {
		s.scanStep(ctx, db)
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}
func (s *Service) topicWorker(ctx context.Context, db CatalogStore) {
	ticker := time.NewTicker(3 * time.Second)
	defer ticker.Stop()
	for {
		s.topicStep(ctx, db)
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}
