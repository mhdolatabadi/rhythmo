package httpapi

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/mhdolatabadi/rhythmo/server/internal/auth"
	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

// fakeChannels lets u1 run playlist p1, which has one synced channel.
type fakeChannels struct {
	codes   []string
	removed []string
}

func (f *fakeChannels) NewChannelCode(_ context.Context, userID, playlistID string) (string, time.Time, error) {
	if userID != "u1" || playlistID != "p1" {
		return "", time.Time{}, store.ErrNotFound
	}
	f.codes = append(f.codes, playlistID)
	return "87654321", time.Date(2026, 10, 29, 12, 10, 0, 0, time.UTC), nil
}

func (f *fakeChannels) PlaylistChannels(_ context.Context, actorID, playlistID string) ([]store.BotChannel, error) {
	if actorID != "u1" || playlistID != "p1" {
		return nil, store.ErrNotFound
	}
	return []store.BotChannel{{Provider: "telegram", ChatID: "-1001", Title: "Golden", LinkedAt: time.Date(2026, 10, 29, 12, 0, 0, 0, time.UTC)}}, nil
}

func (f *fakeChannels) RemovePlaylistChannel(_ context.Context, actorID, playlistID, provider, chatID string) error {
	if actorID != "u1" || playlistID != "p1" || provider != "telegram" || chatID != "-1001" {
		return store.ErrNotFound
	}
	f.removed = append(f.removed, provider+"/"+chatID)
	return nil
}

func TestSyncingMessengerChannelsAPI(t *testing.T) {
	tokens, _ := auth.NewTokens([]byte(strings.Repeat("k", auth.MinSecretBytes)), time.Hour)
	token, _, _ := tokens.Issue("u1")
	other, _, _ := tokens.Issue("u2")
	channels := &fakeChannels{}
	rate := NewRateLimiter(RateLimit{Requests: 5, Window: time.Hour}, 100)
	bots := NewBotHandlers(&fakeLinker{}, nil, tokens,
		[]Bot{{Provider: "telegram", Name: "تلگرام", Username: "RhythmoBot", LinkURL: "https://t.me/RhythmoBot?start=%s"}}, rate, rate).
		WithChannels(channels, channels)
	// Next to the playlist endpoints, as in production.
	handler := NewHandler(Config{Bots: bots, Playlists: NewPlaylistHandlers(store.NewPlaylists(nil), tokens)})

	if response := botRequest(handler, http.MethodPost, "/api/v1/playlists/p1/bot-channels/code", ""); response.Code != http.StatusUnauthorized {
		t.Fatalf("signed out = %d", response.Code)
	}
	if response := botRequest(handler, http.MethodPost, "/api/v1/playlists/p1/bot-channels/code", other); response.Code != http.StatusNotFound {
		t.Fatalf("someone else's playlist = %d", response.Code)
	}
	response := botRequest(handler, http.MethodPost, "/api/v1/playlists/p1/bot-channels/code", token)
	body := response.Body.String()
	// A channel code has no deep link: it is posted in the channel.
	if response.Code != http.StatusCreated || !strings.Contains(body, `"code":"87654321"`) ||
		!strings.Contains(body, `"username":"RhythmoBot"`) || strings.Contains(body, "linkUrl") {
		t.Fatalf("channel code = %d %s", response.Code, body)
	}

	response = botRequest(handler, http.MethodGet, "/api/v1/playlists/p1/bot-channels", token)
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), `"chatId":"-1001","title":"Golden"`) {
		t.Fatalf("list = %d %s", response.Code, response.Body)
	}
	if response := botRequest(handler, http.MethodGet, "/api/v1/playlists/p1/bot-channels", other); response.Code != http.StatusNotFound {
		t.Fatalf("someone else's list = %d", response.Code)
	}
	if response := botRequest(handler, http.MethodDelete, "/api/v1/playlists/p1/bot-channels/telegram/-1001", token); response.Code != http.StatusNoContent {
		t.Fatalf("remove = %d", response.Code)
	}
	if response := botRequest(handler, http.MethodDelete, "/api/v1/playlists/p1/bot-channels/telegram/-9", token); response.Code != http.StatusNotFound {
		t.Fatalf("remove unknown = %d", response.Code)
	}
	if len(channels.removed) != 1 {
		t.Fatalf("removed = %v", channels.removed)
	}
}
