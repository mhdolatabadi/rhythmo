package bot

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

type fakeQueue struct {
	pending []store.Notification
	since   time.Time
	pushed  map[string]time.Time
}

func (q *fakeQueue) PendingPushes(_ context.Context, since time.Time, _ int) ([]store.Notification, error) {
	q.since = since
	var out []store.Notification
	for _, n := range q.pending {
		if at, ok := q.pushed[n.ID]; !ok || at.Before(n.UpdatedAt) {
			out = append(out, n)
		}
	}
	return out, nil
}

func (q *fakeQueue) MarkPushed(_ context.Context, id string, updatedAt time.Time) error {
	if q.pushed == nil {
		q.pushed = map[string]time.Time{}
	}
	q.pushed[id] = updatedAt
	return nil
}

type fakeChatLister map[string][]string

func (c fakeChatLister) LinkedChats(_ context.Context, userID, _ string, _ time.Time) ([]string, error) {
	return c[userID], nil
}

func TestNotifierPushesEachNoticeOnceToLinkedChats(t *testing.T) {
	now := time.Date(2026, 10, 25, 12, 0, 0, 0, time.UTC)
	title := "Track"
	queue := &fakeQueue{pending: []store.Notification{
		{ID: "n1", UserID: "fan", ShareToken: "tok", PlaylistName: "Mix", TrackCount: 1, TrackTitle: &title, UpdatedAt: now},
		{ID: "n2", UserID: "lurker", ShareToken: "tok", PlaylistName: "Mix", TrackCount: 3, UpdatedAt: now},
	}}
	provider := &fakeProvider{}
	n := NewNotifier([]Provider{provider}, queue, fakeChatLister{"fan": {"chat-1"}}, time.Hour, "https://rhythmo.ir/")
	n.now = func() time.Time { return now }

	if err := n.PushPending(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(provider.messages) != 1 || !strings.Contains(provider.messages[0], "«Track»") ||
		!strings.Contains(provider.messages[0], "https://rhythmo.ir/p/tok") {
		t.Fatalf("messages = %q", provider.messages)
	}
	if len(queue.pushed) != 2 {
		t.Fatalf("a notice without a linked chat should still be marked pushed: %v", queue.pushed)
	}
	if !queue.since.Equal(now.Add(-notifyMaxAge)) {
		t.Fatalf("since = %v", queue.since)
	}

	// Nothing new: nothing sent. A later addition is pushed again.
	n.PushPending(context.Background())
	queue.pending[0].TrackCount, queue.pending[0].UpdatedAt = 2, now.Add(time.Minute)
	n.PushPending(context.Background())
	if len(provider.messages) != 2 || !strings.Contains(provider.messages[1], "۲ صوت تازه") {
		t.Fatalf("messages = %q", provider.messages)
	}
}
