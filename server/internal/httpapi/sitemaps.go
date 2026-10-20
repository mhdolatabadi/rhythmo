package httpapi

import (
	"context"
	"encoding/xml"
	"net/http"
	"regexp"
	"strconv"

	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

const (
	// sitemapPageSize is how many URLs one paged sitemap file lists.
	sitemapPageSize = 5000
	// sitemapMaxPages caps the files of each paged kind.
	sitemapMaxPages = 10
	// sitemapPlaylists caps the public playlists in playlists.xml.
	sitemapPlaylists = 10000
	sitemapXMLNS     = "http://www.sitemaps.org/schemas/sitemap/0.9"
)

type sitemapURL struct {
	Loc     string `xml:"loc"`
	LastMod string `xml:"lastmod,omitempty"`
}

type sitemap struct {
	XMLName xml.Name     `xml:"urlset"`
	XMLNS   string       `xml:"xmlns,attr"`
	URLs    []sitemapURL `xml:"url"`
}

type sitemapRef struct {
	Loc string `xml:"loc"`
}

type sitemapIndex struct {
	XMLName  xml.Name     `xml:"sitemapindex"`
	XMLNS    string       `xml:"xmlns,attr"`
	Sitemaps []sitemapRef `xml:"sitemap"`
}

// sitemapKinds are the store's paged sitemaps, in index order.
var sitemapKinds = []string{"songs", "artists", "albums"}

var sitemapFile = regexp.MustCompile(`^(?:(pages|playlists)|(songs|artists|albums)-([1-9][0-9]?))\.xml$`)

// sitemapPage lists one sitemap file's URLs: pages and playlists are one
// file each; songs, artists and albums are paged. more says whether the
// next page has URLs too.
func (p *PublicPages) sitemapPage(ctx context.Context, site, kind string, page int) (urls []sitemapURL, more bool, err error) {
	offset := (page - 1) * sitemapPageSize
	switch kind {
	case "pages":
		urls = []sitemapURL{{Loc: site + "/"}, {Loc: site + "/privacy"}, {Loc: site + "/delete-account"}}
		if p.catalog != nil {
			urls = append(urls, sitemapURL{Loc: site + "/store"}, sitemapURL{Loc: site + "/store/artists"}, sitemapURL{Loc: site + "/store/albums"})
		}
		return urls, false, nil
	case "playlists":
		listed, err := p.playlists.Popular(ctx, "", sitemapPlaylists)
		if err != nil {
			return nil, false, err
		}
		for _, pl := range listed {
			urls = append(urls, sitemapURL{Loc: site + "/p/" + pl.ShareToken, LastMod: lastMod(pl.UpdatedAt)})
		}
		return urls, false, nil
	}
	if p.catalog == nil {
		return nil, false, nil
	}
	switch kind {
	case "songs":
		entries, more, err := p.catalog.StoreEntries(ctx, store.StoreQuery{Limit: sitemapPageSize, Offset: offset})
		if err != nil {
			return nil, false, err
		}
		for _, entry := range entries {
			urls = append(urls, sitemapURL{Loc: site + storeTrackLink(entry), LastMod: lastMod(entry.Track.CreatedAt)})
		}
		return urls, more, nil
	case "artists":
		artists, more, err := p.catalog.StoreArtists(ctx, "", sitemapPageSize, offset)
		if err != nil {
			return nil, false, err
		}
		for _, a := range artists {
			urls = append(urls, sitemapURL{Loc: site + artistLink(a.Name)})
		}
		return urls, more, nil
	case "albums":
		albums, more, err := p.catalog.StoreAlbums(ctx, "", "", sitemapPageSize, offset)
		if err != nil {
			return nil, false, err
		}
		for _, a := range albums {
			urls = append(urls, sitemapURL{Loc: site + albumLink(a.Name, optional(a.Artist))})
		}
		return urls, more, nil
	}
	return nil, false, nil
}

// sitemapPageCount is how many files a paged kind has, found by asking
// for the first item of each next page.
func (p *PublicPages) sitemapPageCount(ctx context.Context, kind string) (int, error) {
	pages := 1
	for pages < sitemapMaxPages {
		offset := pages * sitemapPageSize
		var found int
		var err error
		switch kind {
		case "songs":
			var entries []store.StoreEntry
			entries, _, err = p.catalog.StoreEntries(ctx, store.StoreQuery{Limit: 1, Offset: offset})
			found = len(entries)
		case "artists":
			var artists []store.StoreArtist
			artists, _, err = p.catalog.StoreArtists(ctx, "", 1, offset)
			found = len(artists)
		case "albums":
			var albums []store.StoreAlbum
			albums, _, err = p.catalog.StoreAlbums(ctx, "", "", 1, offset)
			found = len(albums)
		}
		if err != nil {
			return 0, err
		}
		if found == 0 {
			break
		}
		pages++
	}
	return pages, nil
}

// sitemapFiles are the names of every sitemap file sitemap.xml lists.
func (p *PublicPages) sitemapFiles(ctx context.Context) ([]string, error) {
	files := []string{"pages.xml", "playlists.xml"}
	if p.catalog == nil {
		return files, nil
	}
	for _, kind := range sitemapKinds {
		pages, err := p.sitemapPageCount(ctx, kind)
		if err != nil {
			return nil, err
		}
		for page := 1; page <= pages; page++ {
			files = append(files, kind+"-"+strconv.Itoa(page)+".xml")
		}
	}
	return files, nil
}

// allSitemapURLs are every URL the sitemap files list.
func (p *PublicPages) allSitemapURLs(ctx context.Context, site string) ([]string, error) {
	files, err := p.sitemapFiles(ctx)
	if err != nil {
		return nil, err
	}
	var all []string
	for _, file := range files {
		kind, page, _ := parseSitemapFile(file)
		urls, _, err := p.sitemapPage(ctx, site, kind, page)
		if err != nil {
			return nil, err
		}
		for _, u := range urls {
			all = append(all, u.Loc)
		}
	}
	return all, nil
}

// parseSitemapFile reads a sitemap file name such as songs-2.xml.
func parseSitemapFile(name string) (kind string, page int, ok bool) {
	match := sitemapFile.FindStringSubmatch(name)
	if match == nil {
		return "", 0, false
	}
	if match[1] != "" {
		return match[1], 1, true
	}
	page, _ = strconv.Atoi(match[3])
	return match[2], page, page <= sitemapMaxPages
}

// handleSitemapIndex lists the sitemap files, split by kind and paged so
// none nears the 50,000 URL limit.
func (p *PublicPages) handleSitemapIndex(w http.ResponseWriter, r *http.Request) {
	files, err := p.sitemapFiles(r.Context())
	if err != nil {
		internalError(w, "list sitemap files", err)
		return
	}
	site := p.origin(r)
	index := sitemapIndex{XMLNS: sitemapXMLNS}
	for _, file := range files {
		index.Sitemaps = append(index.Sitemaps, sitemapRef{Loc: site + "/sitemaps/" + file})
	}
	writeXML(w, index)
}

func (p *PublicPages) handleSitemap(w http.ResponseWriter, r *http.Request) {
	kind, page, ok := parseSitemapFile(r.PathValue("file"))
	if ok && p.catalog == nil && kind != "pages" && kind != "playlists" {
		ok = false
	}
	if !ok {
		p.handleNotFound(w, r)
		return
	}
	urls, _, err := p.sitemapPage(r.Context(), p.origin(r), kind, page)
	if err != nil {
		internalError(w, "list sitemap "+kind, err)
		return
	}
	if len(urls) == 0 && page > 1 {
		p.handleNotFound(w, r)
		return
	}
	writeXML(w, sitemap{XMLNS: sitemapXMLNS, URLs: urls})
}

func writeXML(w http.ResponseWriter, v any) {
	body, err := xml.MarshalIndent(v, "", "  ")
	if err != nil {
		internalError(w, "encode sitemap", err)
		return
	}
	w.Header().Set("Content-Type", "application/xml; charset=utf-8")
	w.Header().Set("Cache-Control", "public, max-age=3600")
	_, _ = w.Write([]byte(xml.Header))
	_, _ = w.Write(body)
}
