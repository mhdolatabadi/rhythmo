package httpapi

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"
)

const testIndexNowKey = "rhythmo-indexnow-test"

func TestIndexNowKeyIsServedOnlyWhenValid(t *testing.T) {
	pages := NewPublicPages(&sharingStore{}, fixedPresigner{}, AnonymousLimits{}).WithIndexNow(testIndexNowKey)
	site := NewHandler(Config{Public: pages})
	key := get(site, "/"+testIndexNowKey+".txt")
	if key.Code != http.StatusOK || key.Body.String() != testIndexNowKey {
		t.Fatalf("key file = %d %q", key.Code, key.Body.String())
	}
	for _, bad := range []string{"short", "has spaces in it", strings.Repeat("a", 129), "../../etc/passwd"} {
		if NewPublicPages(&sharingStore{}, fixedPresigner{}, AnonymousLimits{}).WithIndexNow(bad).indexNowKey != "" {
			t.Errorf("key %q was accepted", bad)
		}
	}
	if NewIndexNow(pages) != nil {
		t.Error("IndexNow ran without a configured site origin")
	}
	if NewIndexNow(NewPublicPages(&sharingStore{}, fixedPresigner{}, AnonymousLimits{}).WithSite("https://rhythmo.ir")) != nil {
		t.Error("IndexNow ran without a key")
	}
}

func TestIndexNowAnnouncesAddedAndRemovedPages(t *testing.T) {
	var notices []map[string]any
	status := http.StatusOK
	engine := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var notice map[string]any
		if err := json.NewDecoder(r.Body).Decode(&notice); err != nil || r.Method != http.MethodPost {
			t.Errorf("notice = %s %v", r.Method, err)
		}
		notices = append(notices, notice)
		w.WriteHeader(status)
	}))
	defer engine.Close()

	token := strings.Repeat("A", 22)
	data := &sharingStore{token: &token, public: false}
	pages := NewPublicPages(data, fixedPresigner{}, AnonymousLimits{}).WithSite("https://rhythmo.ir").WithIndexNow(testIndexNowKey)
	notifier := NewIndexNow(pages)
	notifier.endpoint = engine.URL
	ctx := context.Background()

	// The first pass only records what is public.
	if err := notifier.Sync(ctx); err != nil || len(notices) != 0 {
		t.Fatalf("first sync = %v, %d notices", err, len(notices))
	}
	playlist := "https://rhythmo.ir/p/" + token
	data.public = true
	if err := notifier.Sync(ctx); err != nil || len(notices) != 1 {
		t.Fatalf("sync after publishing = %v, %d notices", err, len(notices))
	}
	notice := notices[0]
	if notice["host"] != "rhythmo.ir" || notice["key"] != testIndexNowKey ||
		notice["keyLocation"] != "https://rhythmo.ir/"+testIndexNowKey+".txt" {
		t.Errorf("notice = %v", notice)
	}
	if urls := notice["urlList"].([]any); len(urls) != 1 || urls[0] != playlist {
		t.Errorf("announced %v; want only the new playlist", urls)
	}
	// Nothing changed, nothing sent.
	if err := notifier.Sync(ctx); err != nil || len(notices) != 1 {
		t.Fatalf("idle sync = %v, %d notices", err, len(notices))
	}

	// A failed notice is retried by the next pass.
	data.public = false
	status = http.StatusTooManyRequests
	if err := notifier.Sync(ctx); err == nil {
		t.Fatal("a refused notice was not an error")
	}
	status = http.StatusAccepted
	if err := notifier.Sync(ctx); err != nil || len(notices) != 3 {
		t.Fatalf("retry = %v, %d notices", err, len(notices))
	}
	var urls []string
	for _, u := range notices[2]["urlList"].([]any) {
		urls = append(urls, u.(string))
	}
	if !slices.Equal(urls, []string{playlist}) {
		t.Errorf("removal announced %v", urls)
	}
}
