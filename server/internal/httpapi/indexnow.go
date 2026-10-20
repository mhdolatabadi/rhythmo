package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"
)

const (
	// indexNowEndpoint shares a notice with every IndexNow search engine
	// (Bing, Yandex, Seznam, Naver and others).
	indexNowEndpoint = "https://api.indexnow.org/indexnow"
	// indexNowBatch is the most URLs one notice may carry.
	indexNowBatch = 10000
	// indexNowEvery is how often the public URLs are compared for changes.
	indexNowEvery = 15 * time.Minute
)

var indexNowKeyPattern = regexp.MustCompile(`^[A-Za-z0-9-]{8,128}$`)

// WithIndexNow serves the IndexNow key at /{key}.txt. A key that is not 8
// to 128 letters, digits or dashes turns IndexNow off.
func (p *PublicPages) WithIndexNow(key string) *PublicPages {
	key = strings.TrimSpace(key)
	if !indexNowKeyPattern.MatchString(key) {
		key = ""
	}
	p.indexNowKey = key
	return p
}

func (p *PublicPages) handleIndexNowKey(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("Cache-Control", "public, max-age=86400")
	_, _ = w.Write([]byte(p.indexNowKey))
}

// IndexNow tells search engines which public pages appeared or went away
// since it last looked, so new playlists and store songs are crawled
// within minutes instead of whenever the sitemap is read again.
type IndexNow struct {
	pages    *PublicPages
	endpoint string
	client   *http.Client
	every    time.Duration
	// known are the public URLs as of the last comparison; nil before the
	// first, which only records them.
	known map[string]bool
}

// NewIndexNow returns nil, and nothing is sent, unless pages has an
// IndexNow key and a configured site origin.
func NewIndexNow(pages *PublicPages) *IndexNow {
	if pages == nil || pages.indexNowKey == "" || pages.site == "" {
		return nil
	}
	return &IndexNow{pages: pages, endpoint: indexNowEndpoint, client: &http.Client{Timeout: 30 * time.Second}, every: indexNowEvery}
}

// Run compares the public URLs every interval until ctx ends. The first
// pass only records them, so a restart doesn't announce every page again.
func (n *IndexNow) Run(ctx context.Context) {
	ticker := time.NewTicker(n.every)
	defer ticker.Stop()
	for {
		if err := n.Sync(ctx); err != nil && ctx.Err() == nil {
			slog.Warn("indexnow sync failed", "error", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

// Sync announces the public URLs added or removed since the last Sync.
func (n *IndexNow) Sync(ctx context.Context) error {
	urls, err := n.pages.allSitemapURLs(ctx, n.pages.site)
	if err != nil {
		return err
	}
	current := make(map[string]bool, len(urls))
	for _, u := range urls {
		current[u] = true
	}
	if n.known == nil {
		n.known = current
		return nil
	}
	var changed []string
	for _, u := range urls {
		if !n.known[u] {
			changed = append(changed, u)
		}
	}
	for u := range n.known {
		if !current[u] {
			changed = append(changed, u)
		}
	}
	for start := 0; start < len(changed); start += indexNowBatch {
		end := min(start+indexNowBatch, len(changed))
		if err := n.notify(ctx, changed[start:end]); err != nil {
			// Keep the old picture, so the next pass tries these again.
			return err
		}
	}
	n.known = current
	if len(changed) > 0 {
		slog.Info("indexnow notified", "urls", len(changed))
	}
	return nil
}

func (n *IndexNow) notify(ctx context.Context, urls []string) error {
	site, _ := url.Parse(n.pages.site)
	body, err := json.Marshal(map[string]any{
		"host": site.Host, "key": n.pages.indexNowKey,
		"keyLocation": n.pages.site + "/" + n.pages.indexNowKey + ".txt", "urlList": urls,
	})
	if err != nil {
		return err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, n.endpoint, bytes.NewReader(body))
	if err != nil {
		return err
	}
	request.Header.Set("Content-Type", "application/json; charset=utf-8")
	response, err := n.client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	// 200 is accepted, 202 is accepted while the key is checked.
	if response.StatusCode != http.StatusOK && response.StatusCode != http.StatusAccepted {
		return fmt.Errorf("indexnow answered %d", response.StatusCode)
	}
	return nil
}
