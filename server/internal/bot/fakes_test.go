package bot

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"sync"
	"time"

	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

// memStore is an in-memory store.Bots with the same rules.
type memStore struct {
	mu      sync.Mutex
	chats   map[string]*memChat
	codes   map[string]memCode
	updates map[string]bool
	imports map[string]*store.BotImport
	fileIDs map[string]string
	nextID  int
	// Channel sync: codes for a playlist, linked channels, and who runs
	// each playlist.
	channelCodes map[string]memChannelCode
	channels     map[string]store.BotChannel
	managers     map[string]map[string]bool
}

type memChannelCode struct {
	userID, playlistID string
	expiresAt          time.Time
}

type memChat struct {
	store.BotChat
	failures int
	since    time.Time
}

type memCode struct {
	userID    string
	expiresAt time.Time
}

func newMemStore() *memStore {
	return &memStore{
		chats: map[string]*memChat{}, codes: map[string]memCode{},
		updates: map[string]bool{}, imports: map[string]*store.BotImport{}, fileIDs: map[string]string{},
		channelCodes: map[string]memChannelCode{}, channels: map[string]store.BotChannel{},
		managers: map[string]map[string]bool{},
	}
}

func (m *memStore) manages(userID, playlistID string) bool { return m.managers[playlistID][userID] }

func (m *memStore) CreateChannelCode(_ context.Context, userID, playlistID string, hash []byte, expiresAt time.Time) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if !m.manages(userID, playlistID) {
		return store.ErrNotFound
	}
	if _, taken := m.channelCodes[string(hash)]; taken {
		return store.ErrCodeCollision
	}
	m.channelCodes[string(hash)] = memChannelCode{userID, playlistID, expiresAt}
	return nil
}

func (m *memStore) RedeemChannelCode(_ context.Context, provider, chatID, title string, hash []byte, now time.Time, maxFailures int, window time.Duration) (store.BotChannel, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	c := m.chat(provider, chatID)
	if now.Sub(c.since) >= window {
		c.failures, c.since = 0, now
	}
	if c.failures >= maxFailures {
		return store.BotChannel{}, store.ErrCodeAttempts
	}
	code, ok := m.channelCodes[string(hash)]
	if !ok || !code.expiresAt.After(now) {
		c.failures++
		if c.failures >= maxFailures {
			return store.BotChannel{}, store.ErrCodeAttempts
		}
		return store.BotChannel{}, store.ErrCodeInvalid
	}
	if !m.manages(code.userID, code.playlistID) {
		return store.BotChannel{}, store.ErrNotFound
	}
	delete(m.channelCodes, string(hash))
	c.failures = 0
	link := store.BotChannel{Provider: provider, ChatID: chatID, PlaylistID: code.playlistID, UserID: code.userID, Title: title, LinkedAt: now}
	m.channels[provider+"/"+chatID] = link
	return link, nil
}

func (m *memStore) ChannelFor(_ context.Context, provider, chatID string) (store.BotChannel, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	link, ok := m.channels[provider+"/"+chatID]
	if !ok {
		return store.BotChannel{}, store.ErrNotFound
	}
	if !m.manages(link.UserID, link.PlaylistID) {
		delete(m.channels, provider+"/"+chatID)
		return store.BotChannel{}, store.ErrNotFound
	}
	return link, nil
}

func (m *memStore) UnlinkChannel(_ context.Context, provider, chatID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.channels, provider+"/"+chatID)
	return nil
}

// fakePlaylists records what channel posts added.
type fakePlaylists struct {
	mu       sync.Mutex
	names    map[string]string
	appended []string
}

func (f *fakePlaylists) AppendSyncedTrack(_ context.Context, userID, playlistID, trackID string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.appended = append(f.appended, userID+" "+playlistID+" "+trackID)
	return nil
}

func (f *fakePlaylists) Name(_ context.Context, playlistID string) (string, error) {
	name, ok := f.names[playlistID]
	if !ok {
		return "", store.ErrNotFound
	}
	return name, nil
}

func (m *memStore) chat(provider, chatID string) *memChat {
	key := provider + "/" + chatID
	c, ok := m.chats[key]
	if !ok {
		c = &memChat{BotChat: store.BotChat{Provider: provider, ChatID: chatID}}
		m.chats[key] = c
	}
	return c
}

func (m *memStore) Chat(_ context.Context, provider, chatID string) (store.BotChat, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.chat(provider, chatID).BotChat, nil
}

func (m *memStore) Unlink(_ context.Context, provider, chatID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	c := m.chat(provider, chatID)
	c.UserID, c.LinkedAt = nil, nil
	return nil
}

func (m *memStore) CreateLinkCode(_ context.Context, userID string, hash []byte, expiresAt time.Time) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for k, c := range m.codes {
		if c.userID == userID {
			delete(m.codes, k)
		}
	}
	if _, taken := m.codes[string(hash)]; taken {
		return store.ErrCodeCollision
	}
	m.codes[string(hash)] = memCode{userID, expiresAt}
	return nil
}

func (m *memStore) RedeemLinkCode(_ context.Context, provider, chatID string, hash []byte, now time.Time, maxFailures int, window time.Duration) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	c := m.chat(provider, chatID)
	if now.Sub(c.since) >= window {
		c.failures, c.since = 0, now
	}
	if c.failures >= maxFailures {
		return "", store.ErrCodeAttempts
	}
	code, ok := m.codes[string(hash)]
	if !ok || !code.expiresAt.After(now) {
		c.failures++
		if c.failures >= maxFailures {
			return "", store.ErrCodeAttempts
		}
		return "", store.ErrCodeInvalid
	}
	delete(m.codes, string(hash))
	userID := code.userID
	c.UserID, c.LinkedAt, c.failures = &userID, &now, 0
	return userID, nil
}

func (m *memStore) LinkedChats(_ context.Context, userID, provider string, since time.Time) ([]string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var chats []string
	for _, c := range m.chats {
		if c.Provider == provider && c.UserID != nil && *c.UserID == userID && !c.LinkedAt.Before(since) {
			chats = append(chats, c.ChatID)
		}
	}
	return chats, nil
}

func (m *memStore) LinkedProviders(_ context.Context, userID string, since time.Time) ([]string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	seen := map[string]bool{}
	var providers []string
	for _, c := range m.chats {
		if c.UserID != nil && *c.UserID == userID && !c.LinkedAt.Before(since) && !seen[c.Provider] {
			seen[c.Provider] = true
			providers = append(providers, c.Provider)
		}
	}
	return providers, nil
}

func (m *memStore) TrackFileID(_ context.Context, provider, trackID string) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.fileIDs[provider+"/"+trackID], nil
}

func (m *memStore) SaveTrackFileID(_ context.Context, provider, trackID, fileID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.fileIDs[provider+"/"+trackID] = fileID
	return nil
}

func (m *memStore) FirstDelivery(_ context.Context, provider, updateID string) (bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	key := provider + "/" + updateID
	if m.updates[key] {
		return false, nil
	}
	m.updates[key] = true
	return true, nil
}

func (m *memStore) AddImport(_ context.Context, i store.BotImport) (store.BotImport, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, existing := range m.imports {
		if existing.Provider == i.Provider && existing.ChatID == i.ChatID && existing.MessageID == i.MessageID {
			return store.BotImport{}, store.ErrDuplicateImport
		}
	}
	m.nextID++
	i.ID = fmt.Sprint("import-", m.nextID)
	i.State = store.ImportQueued
	m.imports[i.ID] = &i
	return i, nil
}

func (m *memStore) StartImport(_ context.Context, id string, staleBefore time.Time) (store.BotImport, bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	i, ok := m.imports[id]
	if !ok || (i.State != store.ImportQueued && !(i.State == store.ImportDownloading && staleBefore.After(clock))) {
		return store.BotImport{}, false, nil
	}
	i.State = store.ImportDownloading
	i.Attempts++
	return *i, true, nil
}

func (m *memStore) FinishImport(_ context.Context, id string, trackID, reason *string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	i := m.imports[id]
	i.State, i.TrackID, i.Error = store.ImportDone, trackID, reason
	if trackID == nil {
		i.State = store.ImportFailed
	}
	return nil
}

func (m *memStore) RequeueImport(_ context.Context, id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.imports[id].State = store.ImportQueued
	return nil
}

func (m *memStore) UnfinishedImports(_ context.Context, _ int) ([]store.BotImport, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var out []store.BotImport
	for _, i := range m.imports {
		if i.State == store.ImportQueued || i.State == store.ImportDownloading {
			out = append(out, *i)
		}
	}
	return out, nil
}

// clock is the fake current time shared by memStore and Auth in tests.
var clock = time.Date(2026, 9, 29, 12, 0, 0, 0, time.UTC)

type fakeUsers map[string]store.User

func (f fakeUsers) ByID(_ context.Context, id string) (store.User, error) {
	u, ok := f[id]
	if !ok {
		return store.User{}, store.ErrNotFound
	}
	return u, nil
}

type fakeProvider struct {
	mu        sync.Mutex
	messages  []string
	files     map[string][]byte
	openErr   error
	maxBytes  int64
	maxUpload int64
	// sent records every SendAudio; fileIDs the provider knows.
	sent     []OutgoingAudio
	uploaded map[string][]byte
	sendErr  error
	staleIDs map[string]bool
}

func (p *fakeProvider) SendAudio(_ context.Context, chatID string, audio OutgoingAudio) (string, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if audio.Body != nil {
		data, err := io.ReadAll(audio.Body)
		if err != nil {
			return "", err
		}
		audio.Body = nil
		p.sent = append(p.sent, audio)
		if p.sendErr != nil {
			return "", p.sendErr
		}
		if p.uploaded == nil {
			p.uploaded = map[string][]byte{}
		}
		id := fmt.Sprint("file-", len(p.uploaded)+1)
		p.uploaded[id] = data
		return id, nil
	}
	p.sent = append(p.sent, audio)
	if p.staleIDs[audio.FileID] {
		return "", errors.New("Bad Request: wrong file identifier")
	}
	return audio.FileID, p.sendErr
}

func (p *fakeProvider) MaxUploadBytes() int64 { return p.maxUpload }

func (p *fakeProvider) Name() string { return "bale" }

func (p *fakeProvider) Send(_ context.Context, _ string, text string) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.messages = append(p.messages, text)
	return nil
}

func (p *fakeProvider) Open(_ context.Context, fileID string) (io.ReadCloser, int64, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.openErr != nil {
		return nil, 0, p.openErr
	}
	data, ok := p.files[fileID]
	if !ok {
		return nil, 0, errors.New("no such file")
	}
	return io.NopCloser(bytes.NewReader(data)), int64(len(data)), nil
}

func (p *fakeProvider) MaxDownloadBytes() int64 { return p.maxBytes }

func (p *fakeProvider) last() string {
	p.mu.Lock()
	defer p.mu.Unlock()
	if len(p.messages) == 0 {
		return ""
	}
	return p.messages[len(p.messages)-1]
}

type fakeTracks struct {
	mu       sync.Mutex
	tracks   map[string]store.Track
	next     int
	quotaErr error
}

func (f *fakeTracks) ReservePending(_ context.Context, ownerID string, t store.NewTrack, _ int64, _ int) (store.Track, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.quotaErr != nil {
		return store.Track{}, f.quotaErr
	}
	f.next++
	id := fmt.Sprint("track-", f.next)
	track := store.Track{
		ID: id, OwnerID: ownerID, Status: store.TrackPending, Title: t.Title, Artist: t.Artist,
		StorageKey: store.StorageKey(ownerID, id, t.FileName), ContentType: t.ContentType, SizeBytes: t.SizeBytes,
		Source: t.Source,
	}
	f.tracks[id] = track
	return track, nil
}

func (f *fakeTracks) ForOwner(_ context.Context, ownerID, trackID string) (store.Track, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	t, ok := f.tracks[trackID]
	if !ok || t.OwnerID != ownerID {
		return store.Track{}, store.ErrNotFound
	}
	return t, nil
}

func (f *fakeTracks) MarkReady(_ context.Context, ownerID, trackID string) (store.Track, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	t := f.tracks[trackID]
	t.Status = store.TrackReady
	f.tracks[trackID] = t
	return t, nil
}

func (f *fakeTracks) Delete(_ context.Context, _, trackID string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	delete(f.tracks, trackID)
	return nil
}

type fakeObjects struct {
	mu      sync.Mutex
	objects map[string][]byte
	putErr  error
}

func (f *fakeObjects) Put(_ context.Context, key string, r io.Reader, size int64, _ string) error {
	if f.putErr != nil {
		return f.putErr
	}
	data, err := io.ReadAll(r)
	if err != nil {
		return err
	}
	if int64(len(data)) != size {
		return fmt.Errorf("read %d bytes, expected %d", len(data), size)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.objects[key] = data
	return nil
}

func (f *fakeObjects) Open(_ context.Context, key string) (io.ReadCloser, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	data, ok := f.objects[key]
	if !ok {
		return nil, errors.New("no such object")
	}
	return io.NopCloser(bytes.NewReader(data)), nil
}

func (f *fakeObjects) Remove(_ context.Context, key string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	delete(f.objects, key)
	return nil
}
