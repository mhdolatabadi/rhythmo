package bot

import (
	"context"
	"errors"
	"log/slog"
	"net/url"
	"strings"
	"time"

	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

// NotificationQueue is the playlist notices waiting to be pushed (#414).
type NotificationQueue interface {
	PendingPushes(ctx context.Context, since time.Time, limit int) ([]store.Notification, error)
	MarkPushed(ctx context.Context, id string, updatedAt time.Time) error
}

// ChatLister finds the chats a user linked with a bot.
type ChatLister interface {
	LinkedChats(ctx context.Context, userID, provider string, since time.Time) ([]string, error)
}

const (
	notifyBatch = 100
	// notifyMaxAge keeps a long outage from sending stale news.
	notifyMaxAge = 24 * time.Hour
)

// Notifier pushes playlist notices out of the app: each subscriber whose
// account is linked with a bot gets a message there with the playlist's
// link. Notices are picked up every interval, so a burst of additions
// becomes one message. Without a linked chat a notice just stays in the
// app's inbox.
type Notifier struct {
	providers  []Provider
	queue      NotificationQueue
	chats      ChatLister
	sessionTTL time.Duration
	webOrigin  string
	now        func() time.Time
}

func NewNotifier(providers []Provider, queue NotificationQueue, chats ChatLister, sessionTTL time.Duration, webOrigin string) *Notifier {
	return &Notifier{
		providers: providers, queue: queue, chats: chats, sessionTTL: sessionTTL,
		webOrigin: strings.TrimSuffix(webOrigin, "/"), now: time.Now,
	}
}

// Run pushes pending notices every interval until ctx is done.
func (n *Notifier) Run(ctx context.Context, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		if err := n.PushPending(ctx); err != nil && !errors.Is(err, context.Canceled) {
			slog.Error("push playlist notifications", "error", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

// PushPending sends one batch of pending notices. A notice is marked pushed
// even when a chat refused it, so a blocked bot isn't retried forever.
func (n *Notifier) PushPending(ctx context.Context) error {
	now := n.now()
	pending, err := n.queue.PendingPushes(ctx, now.Add(-notifyMaxAge), notifyBatch)
	if err != nil {
		return err
	}
	for _, notice := range pending {
		text := msgPlaylistTracksAdded(notice.PlaylistName, notice.TrackCount, notice.TrackTitle, n.playlistURL(notice.ShareToken))
		for _, p := range n.providers {
			chats, err := n.chats.LinkedChats(ctx, notice.UserID, p.Name(), now.Add(-n.sessionTTL))
			if err != nil {
				return err
			}
			for _, chat := range chats {
				if err := p.Send(ctx, chat, text); err != nil {
					slog.Warn("push playlist notification", "provider", p.Name(), "error", err)
				}
			}
		}
		if err := n.queue.MarkPushed(ctx, notice.ID, notice.UpdatedAt); err != nil {
			return err
		}
	}
	return nil
}

func (n *Notifier) playlistURL(token string) string {
	if n.webOrigin == "" {
		return ""
	}
	return n.webOrigin + "/p/" + url.PathEscape(token)
}
