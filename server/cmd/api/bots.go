package main

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/mhdolatabadi/rhythmo/server/internal/auth"
	"github.com/mhdolatabadi/rhythmo/server/internal/bot"
	"github.com/mhdolatabadi/rhythmo/server/internal/botapi"
	"github.com/mhdolatabadi/rhythmo/server/internal/httpapi"
	"github.com/mhdolatabadi/rhythmo/server/internal/storage"
	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

const (
	// Telegram's Bot API serves bots files up to 20 MB and accepts uploads
	// up to 50 MB; Bale follows it.
	defaultBotDownloadBytes = 20 << 20
	defaultBotUploadBytes   = 50 << 20
	botWebhookConcurrency   = 16
	botSendConcurrency      = 4
	botHealthLogInterval    = 5 * time.Minute
	botNotifyInterval       = 30 * time.Second
	minWebhookSecretLength  = 32
)

// messenger is a supported bot provider. Each is configured with environment
// variables named after its prefix, for example BALE_BOT_TOKEN, and is off
// until its token is set.
type messenger struct {
	name        string
	displayName string
	envPrefix   string
	defaultAPI  string
	// linkBase opens a bot by username; "?start=<code>" passes a link code.
	linkBase string
	// headerAuth registers the webhook secret as a secret token, which the
	// provider then sends in a header of every update.
	headerAuth bool
}

var messengers = []messenger{
	{name: "bale", displayName: "بله", envPrefix: "BALE", defaultAPI: "https://tapi.bale.ai", linkBase: "https://ble.ir/"},
	{name: "telegram", displayName: "تلگرام", envPrefix: "TELEGRAM", defaultAPI: "https://api.telegram.org", linkBase: "https://t.me/", headerAuth: true},
}

type botDeps struct {
	tokenSecret []byte
	tokens      *auth.Tokens
	bots        *store.Bots
	users       *store.Users
	tracks      *store.Tracks
	objects     *storage.Storage
	policy      bot.UploadPolicy
	// notifications are pushed to linked chats; webOrigin builds the links.
	notifications *store.Notifications
	webOrigin     string
	// playlists receive the audio posted in synced channels (#430).
	playlists *store.Playlists
}

// setupBots starts every messenger bot with a token configured. It returns
// their webhooks, the app-facing bot endpoints (which list no bots when none
// is configured) and a monitor of their health (nil without bots).
func setupBots(ctx context.Context, deps botDeps) (map[string]http.Handler, *httpapi.BotHandlers, *bot.Monitor, error) {
	linkRate, err := rateLimiterEnv("BOT_LINK_RATE", 10, time.Hour)
	if err != nil {
		return nil, nil, nil, err
	}
	sendRate, err := rateLimiterEnv("BOT_SEND_RATE", 30, time.Hour)
	if err != nil {
		return nil, nil, nil, err
	}
	var enabled []messenger
	for _, m := range messengers {
		if os.Getenv(m.envPrefix+"_BOT_TOKEN") != "" {
			enabled = append(enabled, m)
		}
	}
	if len(enabled) == 0 {
		return nil, httpapi.NewBotHandlers(nil, nil, deps.tokens, nil, linkRate, sendRate), nil, nil
	}

	secret := os.Getenv("BOT_WEBHOOK_SECRET")
	if len(secret) < minWebhookSecretLength || strings.Trim(secret, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-") != "" {
		return nil, nil, nil, fmt.Errorf("BOT_WEBHOOK_SECRET must be at least %d letters, digits, _ or -", minWebhookSecretLength)
	}
	publicURL := os.Getenv("BOT_PUBLIC_URL")
	if publicURL == "" {
		publicURL = os.Getenv("STORAGE_PUBLIC_URL")
	}
	if parsed, err := url.Parse(publicURL); err != nil || parsed.Scheme != "https" || parsed.Host == "" {
		return nil, nil, nil, fmt.Errorf("BOT_PUBLIC_URL must be the https origin bots post to, got %q", publicURL)
	}
	// Link codes get their own key, derived so AUTH_TOKEN_SECRET stays the
	// only secret to manage.
	mac := hmac.New(sha256.New, deps.tokenSecret)
	mac.Write([]byte("nafir bot link codes"))
	linker, err := bot.NewLinker(deps.bots, mac.Sum(nil), bot.DefaultLinkLimits)
	if err != nil {
		return nil, nil, nil, err
	}
	importer := bot.NewImporter(deps.bots, deps.tracks, deps.objects, deps.policy)

	webhooks := map[string]http.Handler{}
	senders := bot.Senders{}
	var watched []bot.Watched
	var clients []bot.Provider
	var listed []httpapi.Bot
	for _, m := range enabled {
		env := func(name string) string { return os.Getenv(m.envPrefix + "_" + name) }
		maxBytes, err := positiveInt64Env(m.envPrefix+"_MAX_DOWNLOAD_BYTES", defaultBotDownloadBytes)
		if err != nil {
			return nil, nil, nil, err
		}
		maxUpload, err := positiveInt64Env(m.envPrefix+"_MAX_UPLOAD_BYTES", defaultBotUploadBytes)
		if err != nil {
			return nil, nil, nil, err
		}
		apiURL := env("API_URL")
		if apiURL == "" {
			apiURL = m.defaultAPI
		}
		config := botapi.Config{
			Name: m.name, BaseURL: apiURL, Token: env("BOT_TOKEN"),
			MaxDownloadBytes: maxBytes, MaxUploadBytes: maxUpload, ProxyURL: env("PROXY_URL"),
		}
		webhookAuth := bot.WebhookAuth{PathSecret: secret}
		if m.headerAuth {
			config.SecretToken = secret
			webhookAuth.Header, webhookAuth.HeaderSecret = botapi.SecretTokenHeader, secret
		}
		client, err := botapi.New(config)
		if err != nil {
			return nil, nil, nil, fmt.Errorf("%s: %w", m.name, err)
		}
		info := httpapi.Bot{Provider: m.name, Name: m.displayName}
		if username := strings.TrimPrefix(env("BOT_USERNAME"), "@"); username != "" {
			info.Username = username
			info.LinkURL = m.linkBase + url.PathEscape(username) + "?start=%s"
		}
		listed = append(listed, info)

		service := bot.NewService(client, deps.bots, linker, deps.users, importer)
		if deps.playlists != nil {
			service.WithChannels(deps.bots, deps.playlists)
		}
		webhookURL := strings.TrimSuffix(publicURL, "/") + "/api/v1/bots/" + m.name + "/webhook/" + secret
		go registerWebhook(ctx, client, webhookURL)
		go service.Resume(ctx)
		senders[m.name] = bot.NewSender(client, deps.bots, deps.tracks, deps.objects, linker.SessionTTL(), botSendConcurrency).
			CountInto(service.Metrics())
		clients = append(clients, client)
		watched = append(watched, bot.Watched{
			Name: m.name, Webhook: client, WebhookURL: webhookURL, Metrics: service.Metrics(),
		})
		webhooks[m.name] = bot.Webhook(ctx, service, botapi.Parse, webhookAuth, botWebhookConcurrency)
		slog.Info("bot enabled", "provider", m.name)
	}
	go forgetOldUpdates(ctx, deps.bots)
	if deps.notifications != nil {
		go bot.NewNotifier(clients, deps.notifications, deps.bots, linker.SessionTTL(), deps.webOrigin).
			Run(ctx, botNotifyInterval)
	}
	monitor := bot.NewMonitor(deps.bots, watched...)
	go monitor.LogHealth(ctx, botHealthLogInterval)
	return webhooks, httpapi.NewBotHandlers(linker, senders, deps.tokens, listed, linkRate, sendRate).
		WithChannels(linker, deps.bots), monitor, nil
}

// registerWebhook points the provider at rhythmo, retrying while it is unreachable.
func registerWebhook(ctx context.Context, client *botapi.Client, webhookURL string) {
	for attempt := 1; ; attempt++ {
		err := client.SetWebhook(ctx, webhookURL)
		if err == nil {
			slog.Info("bot webhook registered", "provider", client.Name())
			return
		}
		// The URL holds the webhook secret; log only the error, which the
		// client has already stripped of the token.
		slog.Warn("bot webhook registration failed", "provider", client.Name(), "attempt", attempt,
			"error", strings.ReplaceAll(err.Error(), webhookURL, "<webhook>"))
		delay := min(time.Duration(attempt)*10*time.Second, 5*time.Minute)
		select {
		case <-ctx.Done():
			return
		case <-time.After(delay):
		}
	}
}

// forgetOldUpdates keeps the redelivery table small; providers give up
// redelivering within a day.
func forgetOldUpdates(ctx context.Context, bots *store.Bots) {
	ticker := time.NewTicker(time.Hour)
	defer ticker.Stop()
	for {
		if err := bots.ForgetUpdatesBefore(ctx, time.Now().Add(-7*24*time.Hour)); err != nil && !errors.Is(err, context.Canceled) {
			slog.Error("forget old bot updates", "error", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}
