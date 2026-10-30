package balearchive

import (
	"context"
	"errors"
	"io"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/mhdolatabadi/rhythmo/server/internal/audio"
	"github.com/mhdolatabadi/rhythmo/server/internal/bot"
	"github.com/mhdolatabadi/rhythmo/server/internal/linkimport"
	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

var ErrTopic = errors.New("topic needs review")
var ErrSession = errors.New("session needs review")

type ArchiveStore interface {
	bot.ImportStore
	QueueBale(context.Context, string, store.BaleLecture, int) (store.BotImport, error)
	RecentImports(context.Context, string, string, int) ([]store.BotImport, error)
}
type Source interface {
	BaleHistory(context.Context, int64) (linkimport.BalePage, error)
	BalePost(context.Context, string, int64) (linkimport.BaleMessage, error)
}
type Entry struct {
	ID          string `json:"id"`
	Date        int64  `json:"date"`
	Title       string `json:"title"`
	Topic       string `json:"topic"`
	Session     int    `json:"session"`
	NeedsReview bool   `json:"needsReview"`
	FileName    string `json:"fileName"`
	SizeBytes   int64  `json:"sizeBytes"`
	DurationMS  int64  `json:"durationMs"`
	SourceURL   string `json:"sourceUrl"`
}
type Page struct {
	Entries    []Entry `json:"entries"`
	NextBefore int64   `json:"nextBefore"`
	Done       bool    `json:"done"`
}
type Service struct {
	source    Source
	imports   ArchiveStore
	provider  *provider
	importer  *bot.Importer
	maxActive int
}

func New(source Source, media *linkimport.Provider, imports ArchiveStore, tracks bot.TrackStore, objects bot.ObjectStore, policy bot.UploadPolicy) *Service {
	p := &provider{Provider: media, source: source}
	return &Service{source: source, imports: imports, provider: p, importer: bot.NewImporter(imports, tracks, objects, policy), maxActive: policy.MaxPending}
}
func entry(m linkimport.BaleMessage) Entry {
	d := m.Message.Document
	duration := d.Ext.Audio.Duration
	if duration < 0 || duration > 2147483647 {
		duration = 0
	}
	t, n, title := Topic(d.Caption.Text)
	return Entry{ID: m.RID, Date: m.Date, Title: title, Topic: t, Session: n, NeedsReview: t == "" || n == 0, FileName: d.Name, SizeBytes: d.FileSize, DurationMS: duration, SourceURL: "https://ble.ir/" + linkimport.KashaniChannel + "/" + url.PathEscape(m.RID) + "/" + strconv.FormatInt(m.Date, 10)}
}
func (s *Service) Preview(ctx context.Context, before int64) (Page, error) {
	p, err := s.source.BaleHistory(ctx, before)
	if err != nil {
		return Page{}, err
	}
	out := Page{Entries: []Entry{}, NextBefore: p.NextBefore, Done: p.Done}
	for _, m := range p.Messages {
		if FullLecture(m) {
			out.Entries = append(out.Entries, entry(m))
		}
	}
	return out, nil
}
func (s *Service) Submit(ctx context.Context, userID, rid string, date int64, topic string, session int) (store.BotImport, error) {
	m, err := s.source.BalePost(ctx, rid, date)
	if err != nil {
		return store.BotImport{}, err
	}
	if !FullLecture(m) {
		return store.BotImport{}, linkimport.ErrNoAudio
	}
	e := entry(m)
	d := m.Message.Document
	if topic != "" {
		e.Topic = Normalize(topic)
	}
	if session > 0 {
		e.Session = session
	}
	if !ValidTopic(e.Topic) {
		return store.BotImport{}, ErrTopic
	}
	if e.Session <= 0 || e.Session > 10000 {
		return store.BotImport{}, ErrSession
	}
	if !linkimport.BaleMediaURL(d.URL) {
		return store.BotImport{}, linkimport.ErrBlocked
	}
	name := bot.FileName(bot.File{Name: d.Name, MIMEType: d.MIMEType})
	switch s.importer.Check(s.provider, bot.File{Name: name, SizeBytes: d.FileSize}) {
	case "":
	case bot.ReasonTooLarge:
		return store.BotImport{}, linkimport.ErrTooLarge
	case bot.ReasonDisabled:
		return store.BotImport{}, linkimport.ErrDisabled
	default:
		return store.BotImport{}, linkimport.ErrUnsupported
	}
	title := e.Title
	if title == "" {
		title = e.Topic + "؛ جلسه " + strconv.Itoa(e.Session)
	}
	return s.imports.QueueBale(ctx, userID, store.BaleLecture{MessageID: rid, Date: date, FileName: audio.SafeFileName(name), Title: title, Caption: d.Caption.Text, Topic: e.Topic, TopicKey: Normalize(e.Topic), SourceURL: e.SourceURL, Session: e.Session, SizeBytes: d.FileSize, DurationMS: e.DurationMS}, s.maxActive)
}
func (s *Service) Recent(ctx context.Context, userID string) ([]store.BotImport, error) {
	return s.imports.RecentImports(ctx, userID, ProviderName, 50)
}

// Run polls the durable queue, one download at a time. Reclaim only jobs
// older than the importer's lease (including after a restart); this is safe
// with overlapping instances. Work never depends on an HTTP request staying open.
func (s *Service) Run(ctx context.Context) {
	ticker := time.NewTicker(3 * time.Second)
	defer ticker.Stop()
	for {
		jobs, err := s.imports.UnfinishedImports(ctx, 100)
		if err == nil {
			for _, j := range jobs {
				if ctx.Err() != nil {
					return
				}
				jobCtx, cancel := context.WithTimeout(ctx, 15*time.Minute)
				s.importer.Run(jobCtx, s.provider, j.ID, false)
				cancel()
			}
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

type provider struct {
	*linkimport.Provider
	source Source
}

func (p *provider) Name() string { return ProviderName }
func (p *provider) Open(ctx context.Context, fileID string) (io.ReadCloser, int64, error) {
	rid, raw, ok := strings.Cut(fileID, "/")
	date, err := strconv.ParseInt(raw, 10, 64)
	if !ok || err != nil {
		return nil, 0, linkimport.ErrInvalidURL
	}
	m, err := p.source.BalePost(ctx, rid, date)
	if err != nil {
		return nil, 0, err
	}
	if !FullLecture(m) {
		return nil, 0, linkimport.ErrNoAudio
	}
	if !linkimport.BaleMediaURL(m.Message.Document.URL) {
		return nil, 0, linkimport.ErrBlocked
	}
	return p.Provider.Open(ctx, m.Message.Document.URL)
}
