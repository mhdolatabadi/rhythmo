package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"slices"
	"strings"
	"time"

	"github.com/mhdolatabadi/rhythmo/server/internal/auth"
	"github.com/mhdolatabadi/rhythmo/server/internal/bot"
	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

// BotLinker issues the one-time codes that link a messenger chat to the
// signed-in account, and says which bots the account has linked.
type BotLinker interface {
	NewCode(ctx context.Context, userID string) (string, time.Time, error)
	LinkedProviders(ctx context.Context, userID string) ([]string, error)
}

// BotChannelLinker issues the codes that sync a messenger channel into a
// playlist (#430).
type BotChannelLinker interface {
	NewChannelCode(ctx context.Context, userID, playlistID string) (string, time.Time, error)
}

// BotChannelStore lists and removes a playlist's synced channels.
type BotChannelStore interface {
	PlaylistChannels(ctx context.Context, actorID, playlistID string) ([]store.BotChannel, error)
	RemovePlaylistChannel(ctx context.Context, actorID, playlistID, provider, chatID string) error
}

// BotSender has a bot send one of the user's tracks to their linked chats.
type BotSender interface {
	Send(ctx context.Context, provider, userID, trackID string) error
}

// Bot is a messenger bot people can link. LinkURL, if set, formats a link
// that opens the bot with a code, for example "https://ble.ir/NafirBot?start=%s".
type Bot struct {
	Provider string
	Name     string
	Username string
	LinkURL  string
}

type BotHandlers struct {
	linker   BotLinker
	sender   BotSender
	tokens   *auth.Tokens
	bots     []Bot
	rate     *RateLimiter
	sendRate *RateLimiter
	// emailGate keeps unverified accounts from the bots; nil allows everyone.
	emailGate *EmailGate
	// channelLinker and channels sync messenger channels; nil leaves the
	// channel endpoints out.
	channelLinker BotChannelLinker
	channels      BotChannelStore
}

// WithChannels serves syncing messenger channels into playlists.
func (h *BotHandlers) WithChannels(linker BotChannelLinker, channels BotChannelStore) *BotHandlers {
	h.channelLinker, h.channels = linker, channels
	return h
}

// WithEmailGate keeps accounts with an unverified email out of what costs
// storage or reaches other people.
func (h *BotHandlers) WithEmailGate(gate *EmailGate) *BotHandlers {
	h.emailGate = gate
	return h
}

// NewBotHandlers serves the bot endpoints. With no bots configured, the list
// is empty and nothing is issued or sent.
func NewBotHandlers(linker BotLinker, sender BotSender, tokens *auth.Tokens, bots []Bot, rate, sendRate *RateLimiter) *BotHandlers {
	return &BotHandlers{linker: linker, sender: sender, tokens: tokens, bots: bots, rate: rate, sendRate: sendRate}
}

func (h *BotHandlers) register(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/v1/bots", h.handleList)
	mux.HandleFunc("POST /api/v1/bots/link-code", h.handleLinkCode)
	mux.HandleFunc("POST /api/v1/bots/{provider}/send", h.handleSend)
	if h.channels != nil {
		mux.HandleFunc("POST /api/v1/playlists/{id}/bot-channels/code", h.handleChannelCode)
		mux.HandleFunc("GET /api/v1/playlists/{id}/bot-channels", h.handleChannels)
		mux.HandleFunc("DELETE /api/v1/playlists/{id}/bot-channels/{provider}/{chatId}", h.handleRemoveChannel)
	}
}

type botResponse struct {
	Provider string `json:"provider"`
	Name     string `json:"name"`
	Username string `json:"username,omitempty"`
	LinkURL  string `json:"linkUrl,omitempty"`
	// Linked says the account has a chat linked with this bot.
	Linked bool `json:"linked"`
}

type botListResponse struct {
	Bots []botResponse `json:"bots"`
}

type linkCodeResponse struct {
	Code      string        `json:"code"`
	ExpiresAt time.Time     `json:"expiresAt"`
	Bots      []botResponse `json:"bots"`
}

func (h *BotHandlers) responses(code string, linked []string) []botResponse {
	bots := make([]botResponse, 0, len(h.bots))
	for _, b := range h.bots {
		r := botResponse{Provider: b.Provider, Name: b.Name, Username: b.Username, Linked: slices.Contains(linked, b.Provider)}
		if code != "" && b.LinkURL != "" {
			r.LinkURL = fmtLink(b.LinkURL, code)
		}
		bots = append(bots, r)
	}
	return bots
}

func fmtLink(template, code string) string {
	return strings.Replace(template, "%s", url.QueryEscape(code), 1)
}

func (h *BotHandlers) handleList(w http.ResponseWriter, r *http.Request) {
	userID, ok := authenticate(h.tokens, w, r)
	if !ok {
		return
	}
	var linked []string
	if h.linker != nil && len(h.bots) > 0 {
		var err error
		if linked, err = h.linker.LinkedProviders(r.Context(), userID); err != nil {
			internalError(w, "list linked bots", err)
			return
		}
	}
	writeJSON(w, http.StatusOK, botListResponse{Bots: h.responses("", linked)})
}

func (h *BotHandlers) handleLinkCode(w http.ResponseWriter, r *http.Request) {
	userID, ok := authenticate(h.tokens, w, r)
	if !ok {
		return
	}
	if h.linker == nil || len(h.bots) == 0 {
		writeError(w, http.StatusNotFound, "no_bots")
		return
	}
	if !enforceRateLimit(w, h.rate, userID) || !h.emailGate.allow(w, r, userID) {
		return
	}
	code, expiresAt, err := h.linker.NewCode(r.Context(), userID)
	if err != nil {
		internalError(w, "create bot link code", err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusCreated, linkCodeResponse{
		Code: code, ExpiresAt: expiresAt.UTC(), Bots: h.responses(code, nil),
	})
}

type sendRequest struct {
	TrackID string `json:"trackId"`
}

// handleSend queues one of the caller's tracks for the bot to post in their
// linked chats. Delivery happens in the background; the bot reports
// failures in the chat.
func (h *BotHandlers) handleSend(w http.ResponseWriter, r *http.Request) {
	userID, ok := authenticate(h.tokens, w, r)
	if !ok {
		return
	}
	if h.sender == nil {
		writeError(w, http.StatusNotFound, "no_bots")
		return
	}
	if !enforceRateLimit(w, h.sendRate, userID) || !h.emailGate.allow(w, r, userID) {
		return
	}
	var input sendRequest
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil || input.TrackID == "" {
		writeError(w, http.StatusBadRequest, "invalid_json")
		return
	}
	err := h.sender.Send(r.Context(), r.PathValue("provider"), userID, input.TrackID)
	switch {
	case errors.Is(err, bot.ErrUnknownProvider), errors.Is(err, bot.ErrTrackNotFound):
		writeError(w, http.StatusNotFound, "not_found")
	case errors.Is(err, bot.ErrNotLinked):
		writeError(w, http.StatusConflict, "not_linked")
	case errors.Is(err, bot.ErrTrackTooLarge):
		writeError(w, http.StatusRequestEntityTooLarge, "too_large")
	case err != nil:
		internalError(w, "send track to bot", err)
	default:
		w.WriteHeader(http.StatusAccepted)
	}
}

// handleChannelCode issues a code that, posted in a Telegram or Bale
// channel the bot administers, syncs that channel into the playlist. Its
// owner and admins may ask for one.
func (h *BotHandlers) handleChannelCode(w http.ResponseWriter, r *http.Request) {
	userID, ok := authenticate(h.tokens, w, r)
	if !ok {
		return
	}
	if len(h.bots) == 0 {
		writeError(w, http.StatusNotFound, "no_bots")
		return
	}
	if !enforceRateLimit(w, h.rate, userID) || !h.emailGate.allow(w, r, userID) {
		return
	}
	code, expiresAt, err := h.channelLinker.NewChannelCode(r.Context(), userID, r.PathValue("id"))
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeError(w, http.StatusNotFound, "not_found")
		return
	case err != nil:
		internalError(w, "create bot channel code", err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	// The bots' deep links are for private chats; a channel gets the code.
	writeJSON(w, http.StatusCreated, linkCodeResponse{
		Code: code, ExpiresAt: expiresAt.UTC(), Bots: h.responses("", nil),
	})
}

type botChannelResponse struct {
	Provider string    `json:"provider"`
	ChatID   string    `json:"chatId"`
	Title    string    `json:"title"`
	LinkedAt time.Time `json:"linkedAt"`
}

func (h *BotHandlers) handleChannels(w http.ResponseWriter, r *http.Request) {
	userID, ok := authenticate(h.tokens, w, r)
	if !ok {
		return
	}
	channels, err := h.channels.PlaylistChannels(r.Context(), userID, r.PathValue("id"))
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeError(w, http.StatusNotFound, "not_found")
		return
	case err != nil:
		internalError(w, "list bot channels", err)
		return
	}
	response := make([]botChannelResponse, 0, len(channels))
	for _, c := range channels {
		response = append(response, botChannelResponse{Provider: c.Provider, ChatID: c.ChatID, Title: c.Title, LinkedAt: c.LinkedAt.UTC()})
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]any{"channels": response})
}

func (h *BotHandlers) handleRemoveChannel(w http.ResponseWriter, r *http.Request) {
	userID, ok := authenticate(h.tokens, w, r)
	if !ok {
		return
	}
	err := h.channels.RemovePlaylistChannel(r.Context(), userID, r.PathValue("id"), r.PathValue("provider"), r.PathValue("chatId"))
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeError(w, http.StatusNotFound, "not_found")
	case err != nil:
		internalError(w, "remove bot channel", err)
	default:
		w.WriteHeader(http.StatusNoContent)
	}
}
