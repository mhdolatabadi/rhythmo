package linkimport

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"golang.org/x/net/html"
)

// BaleArchive reads the same public pages/history used by ble.ir's preview.
// This is not the Bot API. Keep the source fixed: this importer is curated.
const KashaniChannel = "kashani1395"

var ErrBalePage = errors.New("bale public preview is unavailable or changed")

type BalePeer struct {
	Type int   `json:"type"`
	ID   int64 `json:"id"`
}
type BaleDocument struct {
	URL      string `json:"url"`
	Name     string `json:"name"`
	FileSize int64  `json:"fileSize"`
	MIMEType string `json:"mimeType"`
	Caption  struct {
		Text string `json:"text"`
	} `json:"caption"`
	Ext struct {
		Audio struct {
			Duration int64 `json:"duration"`
		} `json:"documentExAudio"`
	} `json:"ext"`
}
type BaleMessage struct {
	RID     string `json:"rid"`
	Date    int64  `json:"date"`
	Message struct {
		Document *BaleDocument `json:"documentMessage"`
	} `json:"message"`
}
type BalePage struct {
	Peer       BalePeer      `json:"peer"`
	Messages   []BaleMessage `json:"messages"`
	NextBefore int64         `json:"nextBefore"`
	Done       bool          `json:"done"`
}

func readBalePage(r io.Reader) (BalePage, error) {
	body, err := io.ReadAll(io.LimitReader(r, maxPageBytes+1))
	if err != nil || len(body) > maxPageBytes {
		return BalePage{}, ErrBalePage
	}
	z := html.NewTokenizer(bytes.NewReader(body))
	var flight strings.Builder
	for {
		tt := z.Next()
		if tt == html.ErrorToken {
			break
		}
		if tt != html.StartTagToken {
			continue
		}
		tag, _ := z.TagName()
		if string(tag) != "script" {
			continue
		}
		if z.Next() != html.TextToken {
			continue
		}
		script := string(z.Text())
		const prefix = "self.__next_f.push("
		if !strings.HasPrefix(script, prefix) {
			continue
		}
		var v []json.RawMessage
		if json.Unmarshal([]byte(strings.TrimSuffix(strings.TrimPrefix(script, prefix), ")")), &v) != nil || len(v) != 2 {
			continue
		}
		var kind int
		var part string
		if json.Unmarshal(v[0], &kind) == nil && kind == 1 && json.Unmarshal(v[1], &part) == nil {
			flight.WriteString(part)
		}
	}
	raw := flight.String()
	var page BalePage
	p := strings.Index(raw, `"peer":`)
	m := strings.Index(raw, `"messages":`)
	if p < 0 || m < 0 {
		return page, ErrBalePage
	}
	if json.NewDecoder(strings.NewReader(raw[p+7:])).Decode(&page.Peer) != nil || json.NewDecoder(strings.NewReader(raw[m+11:])).Decode(&page.Messages) != nil || page.Peer.Type != 2 || page.Peer.ID <= 0 {
		return page, ErrBalePage
	}
	return page, nil
}

func (f *Fetcher) BaleHistory(ctx context.Context, before int64) (BalePage, error) {
	ctx, cancel := context.WithTimeout(ctx, pageTimeout)
	defer cancel()
	u, _ := url.Parse("https://ble.ir/s/" + KashaniChannel)
	resp, err := f.get(ctx, u)
	if err != nil {
		return BalePage{}, err
	}
	page, err := readBalePage(resp.Body)
	resp.Body.Close()
	if err != nil {
		return page, err
	}
	if before > 0 {
		body, _ := json.Marshal(struct {
			Peer BalePeer `json:"peer"`
			Date int64    `json:"date"`
		}{page.Peer, before})
		req, _ := http.NewRequestWithContext(ctx, http.MethodPost, "https://api.ble.ir/api/v1/LoadHistory", bytes.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Origin", "https://ble.ir")
		req.Header.Set("User-Agent", userAgent)
		resp, err = f.client.Do(req)
		if err != nil {
			return BalePage{}, ErrBalePage
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return BalePage{}, ErrBalePage
		}
		raw, err := io.ReadAll(io.LimitReader(resp.Body, maxPageBytes+1))
		if err != nil || len(raw) > maxPageBytes {
			return BalePage{}, ErrBalePage
		}
		var history struct {
			History []BaleMessage `json:"history"`
		}
		if json.Unmarshal(raw, &history) != nil || history.History == nil {
			return BalePage{}, ErrBalePage
		}
		page.Messages = history.History
	}
	page.Done = len(page.Messages) == 0
	for _, m := range page.Messages {
		if m.Date > 0 && (before == 0 || m.Date < before) && (page.NextBefore == 0 || m.Date < page.NextBefore) {
			page.NextBefore = m.Date
		}
	}
	if !page.Done && page.NextBefore == 0 {
		return BalePage{}, ErrBalePage
	} // never loop on a stuck cursor
	return page, nil
}

func (f *Fetcher) BalePost(ctx context.Context, rid string, date int64) (BaleMessage, error) {
	if _, err := strconv.ParseInt(rid, 10, 64); err != nil || date <= 0 || date >= 9007199254740991 {
		return BaleMessage{}, ErrInvalidURL
	}
	page, err := f.BaleHistory(ctx, date+1)
	if err != nil {
		return BaleMessage{}, err
	}
	for _, m := range page.Messages {
		if m.RID == rid && m.Date == date {
			return m, nil
		}
	}
	return BaleMessage{}, ErrNoAudio
}

// BaleMediaURL limits public-preview media to Bale's own HTTPS file gateways.
// Fetcher still checks the actual dialed IP and every redirect for SSRF.
func BaleMediaURL(raw string) bool {
	u, err := ParseURL(raw)
	if err != nil || u.Scheme != "https" || u.Port() != "" || !strings.HasPrefix(u.Path, "/proxy_download/") {
		return false
	}
	host := u.Hostname()
	n := strings.TrimSuffix(strings.TrimPrefix(host, "file-gw"), ".ble.ir")
	_, err = strconv.ParseUint(n, 10, 16)
	return strings.HasPrefix(host, "file-gw") && strings.HasSuffix(host, ".ble.ir") && err == nil
}
