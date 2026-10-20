package httpapi

import (
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"net/url"
	"strings"
	"sync"

	"github.com/mhdolatabadi/rhythmo/server/internal/display"
	"github.com/mhdolatabadi/rhythmo/server/internal/ogimage"
)

// shareImageCacheSize caps the drawn preview cards kept in memory.
const shareImageCacheSize = 512

// shareImages keeps recently drawn preview cards, so a link shared in a
// busy chat is drawn once rather than once per preview.
type shareImages struct {
	mu    sync.Mutex
	cards map[string][]byte
	order []string
}

func (c *shareImages) get(card ogimage.Card) ([]byte, error) {
	key := shareImageVersion(card)
	c.mu.Lock()
	if data, ok := c.cards[key]; ok {
		c.mu.Unlock()
		return data, nil
	}
	c.mu.Unlock()
	data, err := ogimage.Render(card)
	if err != nil {
		return nil, err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.cards == nil {
		c.cards = map[string][]byte{}
	}
	if _, ok := c.cards[key]; !ok {
		if len(c.order) >= shareImageCacheSize {
			delete(c.cards, c.order[0])
			c.order = c.order[1:]
		}
		c.cards[key] = data
		c.order = append(c.order, key)
	}
	return data, nil
}

// shareImageVersion names a card's content, so its URL changes, and chat
// apps fetch it again, whenever what it says changes.
func shareImageVersion(card ogimage.Card) string {
	sum := sha256.Sum256([]byte(card.Kicker + "\x00" + card.Title + "\x00" + card.Subtitle + "\x00" + card.Footer))
	return hex.EncodeToString(sum[:6])
}

// shareImageURL is the page's own preview card at path, versioned by what
// it says.
func shareImageURL(site, path string, card ogimage.Card) string {
	return site + path + "?v=" + shareImageVersion(card)
}

// siteHost is the host the card's footer names.
func siteHost(site string) string {
	if u, err := url.Parse(site); err == nil && u.Host != "" {
		return u.Host
	}
	return strings.TrimPrefix(strings.TrimPrefix(site, "https://"), "http://")
}

// serveShareImage writes a drawn card; it is cached long because its URL
// carries its version.
func (p *PublicPages) serveShareImage(w http.ResponseWriter, card ogimage.Card) {
	data, err := p.images.get(card)
	if err != nil {
		internalError(w, "draw share image", err)
		return
	}
	w.Header().Set("Content-Type", "image/jpeg")
	w.Header().Set("Cache-Control", "public, max-age=604800")
	_, _ = w.Write(data)
}

// playlistCard is a public playlist's preview card.
func playlistCard(site, name string, tracks int, artists []string) ogimage.Card {
	subtitle := display.PersianDigits(tracks) + " آهنگ"
	if len(artists) > 3 {
		artists = artists[:3]
	}
	if len(artists) > 0 {
		subtitle += " · از " + strings.Join(artists, "، ")
	}
	return ogimage.Card{Kicker: "فهرست پخش", Title: name, Subtitle: subtitle, Footer: siteHost(site)}
}

// songCard is a store song's preview card.
func songCard(site, title, artist, album string) ogimage.Card {
	var parts []string
	if artist != "" {
		parts = append(parts, "از "+artist)
	}
	if album != "" {
		parts = append(parts, "آلبوم "+album)
	}
	return ogimage.Card{Kicker: "آهنگ", Title: title, Subtitle: strings.Join(parts, " · "), Footer: siteHost(site)}
}
