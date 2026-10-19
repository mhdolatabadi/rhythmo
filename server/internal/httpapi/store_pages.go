package httpapi

import (
	"errors"
	"fmt"
	"html/template"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/mhdolatabadi/rhythmo/server/internal/display"
	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

func init() {
	for name, file := range map[string]string{
		"store": "public/store.html", "storeIndex": "public/store_index.html", "storeTrack": "public/store_track.html",
	} {
		publicTemplates[name] = template.Must(template.New("layout.html").
			Funcs(template.FuncMap{"digits": display.PersianDigits}).
			ParseFS(publicFiles, "public/layout.html", file))
	}
}

const (
	// storePageSize is how many songs, artists or albums a store page lists.
	storePageSize = 50
	// storeMaxPage keeps paging within the catalog's offset limit.
	storeMaxPage = maxStoreOffset / storePageSize
	// sitemapStoreTracks and sitemapStoreArtists cap the store's share of
	// sitemap.xml.
	sitemapStoreTracks  = 5000
	sitemapStoreArtists = 1000
)

// WithStore serves the public store as plain HTML (#243): /store lists and
// searches songs, /store/t/{id} is one song, /store/artists and
// /store/albums browse by artist and album. Owners are never shown.
func (p *PublicPages) WithStore(catalog CatalogStore) *PublicPages {
	p.catalog = catalog
	return p
}

func (p *PublicPages) registerStore(mux *http.ServeMux) {
	if p.catalog == nil {
		return
	}
	mux.HandleFunc("GET /store", p.handleStore)
	mux.HandleFunc("GET /store/t/{id}", p.handleStoreTrack)
	mux.HandleFunc("GET /store/t/{id}/stream", p.handleStoreStream)
	mux.HandleFunc("GET /store/artists", p.handleStoreArtists)
	mux.HandleFunc("GET /store/artists/{name}", p.handleStoreArtist)
	mux.HandleFunc("GET /store/albums", p.handleStoreAlbums)
	mux.HandleFunc("GET /store/albums/{name}", p.handleStoreAlbum)
}

// storePageTrack is one song in a store list.
type storePageTrack struct {
	ID     string
	Title  string
	Artist string
	Size   string
}

// storeTrackPage is a song's own page.
type storeTrackPage struct {
	ID         string
	Title      string
	Artist     string
	ArtistLink string
	Album      string
	AlbumLink  string
	Duration   string
	Format     string
	Size       string
}

// storeIndexItem is an artist or album in a store index.
type storeIndexItem struct {
	Name       string
	Sub        string
	Link       string
	TrackCount int
}

// sizeText says a file size in Persian megabytes, with one decimal.
func sizeText(bytes int64) string {
	if bytes <= 0 {
		return ""
	}
	return strings.Replace(display.PersianDigits(fmt.Sprintf("%.1f", float64(bytes)/(1<<20))), ".", "٫", 1) + " مگابایت"
}

// durationText says a length as m:ss in Persian digits.
func durationText(ms *int32) string {
	if ms == nil || *ms <= 0 {
		return ""
	}
	seconds := *ms / 1000
	return display.PersianDigits(fmt.Sprintf("%d:%02d", seconds/60, seconds%60))
}

// formatText names a file's format for people.
func formatText(contentType string) string {
	switch contentType {
	case "audio/flac", "audio/x-flac":
		return "FLAC"
	case "audio/wav", "audio/x-wav", "audio/wave":
		return "WAV"
	case "audio/mpeg", "audio/mp3":
		return "MP3"
	case "audio/mp4", "audio/x-m4a", "audio/aac":
		return "AAC"
	case "audio/ogg":
		return "OGG"
	case "audio/opus":
		return "Opus"
	case "audio/webm":
		return "WebM"
	}
	return "صوتی"
}

func optional(s *string) string {
	if s == nil {
		return ""
	}
	return strings.TrimSpace(*s)
}

func artistLink(name string) string { return "/store/artists/" + url.PathEscape(name) }

func albumLink(name, artist string) string {
	link := "/store/albums/" + url.PathEscape(name)
	if artist != "" {
		link += "?artist=" + url.QueryEscape(artist)
	}
	return link
}

// storePage reads ?page= (1 to storeMaxPage); anything else is page 1.
func storePage(r *http.Request) int {
	n, err := strconv.Atoi(r.URL.Query().Get("page"))
	if err != nil || n < 1 || n > storeMaxPage {
		return 1
	}
	return n
}

// pageLinks are the previous and next page links of path with query.
func pageLinks(path string, query url.Values, page int, more bool) (prev, next string) {
	link := func(n int) string {
		q := url.Values{}
		for k, v := range query {
			q[k] = v
		}
		q.Del("page")
		if n > 1 {
			q.Set("page", strconv.Itoa(n))
		}
		if encoded := q.Encode(); encoded != "" {
			return path + "?" + encoded
		}
		return path
	}
	if page > 1 {
		prev = link(page - 1)
	}
	if more && page < storeMaxPage {
		next = link(page + 1)
	}
	return prev, next
}

// storeQueryText reads a short text parameter; too long or invalid is empty.
func storeQueryText(raw string) string {
	raw = strings.TrimSpace(raw)
	if !utf8.ValidString(raw) || utf8.RuneCountInString(raw) > maxStoreSearch {
		return ""
	}
	return raw
}

type storeListData struct {
	ArtistName           string
	Albums               []storeIndexItem
	AlbumPrev, AlbumNext string
	pageMeta
	Heading    string
	Intro      string
	Query      string
	Empty      string
	Tracks     []storePageTrack
	Prev, Next string
}

// renderStoreList lists one page of songs matching query under heading.
func (p *PublicPages) renderStoreList(w http.ResponseWriter, r *http.Request, query store.StoreQuery, data storeListData, canonicalPath string, keep url.Values) {
	page := storePage(r)
	query.Limit, query.Offset = storePageSize, (page-1)*storePageSize
	entries, more, err := p.catalog.StoreEntries(r.Context(), query)
	if err != nil {
		internalError(w, "list store page", err)
		return
	}
	site := p.origin(r)
	recordings := make([]map[string]any, 0, len(entries))
	for i, entry := range entries {
		artist := optional(entry.Track.Artist)
		data.Tracks = append(data.Tracks, storePageTrack{
			ID: entry.ID, Title: entry.Track.Title, Artist: artist, Size: sizeText(entry.Track.SizeBytes),
		})
		recording := map[string]any{"@type": "MusicRecording", "name": entry.Track.Title, "url": site + "/store/t/" + entry.ID}
		if artist != "" {
			recording["byArtist"] = map[string]any{"@type": "MusicGroup", "name": artist}
		}
		recordings = append(recordings, map[string]any{"@type": "ListItem", "position": query.Offset + i + 1, "item": recording})
	}
	data.Prev, data.Next = pageLinks(r.URL.Path, keep, page, more)
	canonical := site + canonicalPath
	if page > 1 {
		canonical += map[bool]string{true: "&", false: "?"}[strings.Contains(canonicalPath, "?")] + "page=" + strconv.Itoa(page)
	}
	data.Canonical, data.Image, data.OGType = canonical, site+"/social.png", "website"
	data.JSONLD = map[string]any{"@context": "https://schema.org", "@type": "ItemList", "name": data.Heading, "itemListElement": recordings}
	if data.ArtistName != "" {
		albums := make([]map[string]any, 0, len(data.Albums))
		for _, album := range data.Albums {
			albums = append(albums, map[string]any{"@type": "MusicAlbum", "name": album.Name, "url": site + album.Link, "numTracks": album.TrackCount})
		}
		data.JSONLD = map[string]any{"@context": "https://schema.org", "@graph": []any{
			map[string]any{"@type": "MusicGroup", "name": data.ArtistName, "url": site + artistLink(data.ArtistName), "album": albums},
			data.JSONLD,
		}}
	}
	if len(entries) == 0 && page > 1 {
		data.NoIndex = true
	}
	w.Header().Set("Cache-Control", publicPageMaxAge)
	p.render(w, http.StatusOK, "store", data)
}

// handleStore lists every store song by title, or searches them with ?q=.
func (p *PublicPages) handleStore(w http.ResponseWriter, r *http.Request) {
	if !enforceRateLimit(w, p.limits.View, clientIP(r)) {
		return
	}
	search := storeQueryText(r.URL.Query().Get("q"))
	data := storeListData{
		Heading: "استور ریتمو",
		Intro:   "همه‌ی آهنگ‌های فهرست‌های پخش عمومی ریتمو، هر آهنگ یک بار و با بهترین کیفیت موجود؛ بدون ثبت‌نام بشنو.",
		Query:   search,
		Empty:   "هنوز آهنگی در استور نیست.",
	}
	data.Title = "استور ریتمو — آهنگ‌های فهرست‌های پخش عمومی"
	data.Description = "آهنگ‌های فهرست‌های پخش عمومی ریتمو را جستجو کن، بر اساس خواننده و آلبوم مرور کن و بدون ثبت‌نام بشنو."
	keep := url.Values{}
	if search != "" {
		keep.Set("q", search)
		data.Heading = "جستجوی «" + search + "»"
		data.Title = "«" + search + "» در استور ریتمو"
		data.Empty = "آهنگی با این نام پیدا نشد. املای دیگری را امتحان کن."
		// Search results are not pages of their own.
		data.NoIndex = true
	}
	p.renderStoreList(w, r, store.StoreQuery{Search: search}, data, "/store", keep)
}

func (p *PublicPages) handleStoreArtist(w http.ResponseWriter, r *http.Request) {
	if !enforceRateLimit(w, p.limits.View, clientIP(r)) {
		return
	}
	name := storeQueryText(r.PathValue("name"))
	if name == "" {
		p.renderStoreMissing(w, r)
		return
	}
	data := storeListData{
		Heading: name, Intro: "آهنگ‌های " + name + " در استور ریتمو.",
		Empty: "آهنگی از این خواننده در استور نیست.",
	}
	data.Title = name + " — آهنگ‌ها در استور ریتمو"
	data.Description = "آهنگ‌های " + name + " را در ریتمو بدون ثبت‌نام بشنو."
	tracks, albumCount, err := p.catalog.StoreArtistCounts(r.Context(), name)
	if err != nil {
		internalError(w, "count artist catalog", err)
		return
	}
	albumPage := 1
	if n, err := strconv.Atoi(r.URL.Query().Get("albumPage")); err == nil && n > 0 && n <= storeMaxPage {
		albumPage = n
	}
	albums, more, err := p.catalog.StoreAlbums(r.Context(), "", name, storePageSize, (albumPage-1)*storePageSize)
	if err != nil {
		internalError(w, "list artist albums", err)
		return
	}
	data.ArtistName = name
	data.Intro = fmt.Sprintf("%s با %s آهنگ و %s آلبوم در استور ریتمو؛ بدون ثبت‌نام گوش بده.", name, display.PersianDigits(strconv.Itoa(tracks)), display.PersianDigits(strconv.Itoa(albumCount)))
	for _, album := range albums {
		data.Albums = append(data.Albums, storeIndexItem{Name: album.Name, Link: albumLink(album.Name, optional(album.Artist)), TrackCount: album.TrackCount})
	}
	albumURL := func(n int) string {
		q := url.Values{}
		if n > 1 {
			q.Set("albumPage", strconv.Itoa(n))
		}
		if page := storePage(r); page > 1 {
			q.Set("page", strconv.Itoa(page))
		}
		if len(q) > 0 {
			return artistLink(name) + "?" + q.Encode()
		}
		return artistLink(name)
	}
	if albumPage > 1 {
		data.AlbumPrev = albumURL(albumPage - 1)
	}
	if more && albumPage < storeMaxPage {
		data.AlbumNext = albumURL(albumPage + 1)
	}
	keep := url.Values{}
	canonicalPath := artistLink(name)
	if albumPage > 1 {
		keep.Set("albumPage", strconv.Itoa(albumPage))
		canonicalPath += "?" + keep.Encode()
	}
	p.renderStoreList(w, r, store.StoreQuery{Artist: name}, data, canonicalPath, keep)
}

func (p *PublicPages) handleStoreAlbum(w http.ResponseWriter, r *http.Request) {
	if !enforceRateLimit(w, p.limits.View, clientIP(r)) {
		return
	}
	name := storeQueryText(r.PathValue("name"))
	artist := storeQueryText(r.URL.Query().Get("artist"))
	if name == "" {
		p.renderStoreMissing(w, r)
		return
	}
	data := storeListData{Heading: name, Intro: "آلبوم " + name, Empty: "آهنگی از این آلبوم در استور نیست."}
	keep := url.Values{}
	if artist != "" {
		data.Intro += " از " + artist
		keep.Set("artist", artist)
	}
	data.Intro += " در استور ریتمو."
	data.Title = name + " — آلبوم در استور ریتمو"
	data.Description = data.Intro + " بدون ثبت‌نام بشنو."
	p.renderStoreList(w, r, store.StoreQuery{Album: name, Artist: artist}, data, albumLink(name, artist), keep)
}

type storeIndexData struct {
	pageMeta
	Heading    string
	Intro      string
	Empty      string
	Items      []storeIndexItem
	Prev, Next string
}

func (p *PublicPages) renderStoreIndex(w http.ResponseWriter, r *http.Request, data storeIndexData, more bool, page int) {
	site := p.origin(r)
	data.Prev, data.Next = pageLinks(r.URL.Path, url.Values{}, page, more)
	data.Canonical = site + r.URL.Path
	if page > 1 {
		data.Canonical += "?page=" + strconv.Itoa(page)
	}
	data.Image, data.OGType = site+"/social.png", "website"
	w.Header().Set("Cache-Control", publicPageMaxAge)
	p.render(w, http.StatusOK, "storeIndex", data)
}

func (p *PublicPages) handleStoreArtists(w http.ResponseWriter, r *http.Request) {
	if !enforceRateLimit(w, p.limits.View, clientIP(r)) {
		return
	}
	page := storePage(r)
	artists, more, err := p.catalog.StoreArtists(r.Context(), "", storePageSize, (page-1)*storePageSize)
	if err != nil {
		internalError(w, "list store artists page", err)
		return
	}
	data := storeIndexData{Heading: "خواننده‌ها", Intro: "خواننده‌های آهنگ‌های استور ریتمو.", Empty: "هنوز خواننده‌ای در استور نیست."}
	data.Title = "خواننده‌ها — استور ریتمو"
	data.Description = "آهنگ‌های استور ریتمو را بر اساس خواننده مرور کن و بدون ثبت‌نام بشنو."
	for _, a := range artists {
		data.Items = append(data.Items, storeIndexItem{Name: a.Name, Link: artistLink(a.Name), TrackCount: a.TrackCount})
	}
	p.renderStoreIndex(w, r, data, more, page)
}

func (p *PublicPages) handleStoreAlbums(w http.ResponseWriter, r *http.Request) {
	if !enforceRateLimit(w, p.limits.View, clientIP(r)) {
		return
	}
	page := storePage(r)
	albums, more, err := p.catalog.StoreAlbums(r.Context(), "", "", storePageSize, (page-1)*storePageSize)
	if err != nil {
		internalError(w, "list store albums page", err)
		return
	}
	data := storeIndexData{Heading: "آلبوم‌ها", Intro: "آلبوم‌های آهنگ‌های استور ریتمو.", Empty: "هنوز آلبومی در استور نیست."}
	data.Title = "آلبوم‌ها — استور ریتمو"
	data.Description = "آهنگ‌های استور ریتمو را بر اساس آلبوم مرور کن و بدون ثبت‌نام بشنو."
	for _, a := range albums {
		artist := optional(a.Artist)
		data.Items = append(data.Items, storeIndexItem{Name: a.Name, Sub: artist, Link: albumLink(a.Name, artist), TrackCount: a.TrackCount})
	}
	p.renderStoreIndex(w, r, data, more, page)
}

func (p *PublicPages) renderStoreMissing(w http.ResponseWriter, r *http.Request) {
	p.renderMissing(w, r, "این آهنگ در استور نیست",
		"ممکن است از فهرست‌های پخش عمومی برداشته شده باشد.",
		"این آهنگ در استور ریتمو نیست.")
}

// storeEntry loads the listed entry at {id}, or writes the not-found page.
func (p *PublicPages) storeEntry(w http.ResponseWriter, r *http.Request) (store.StoreEntry, bool) {
	entry, err := p.catalog.StoreEntryByID(r.Context(), r.PathValue("id"), false)
	if errors.Is(err, store.ErrNotFound) {
		p.renderStoreMissing(w, r)
		return store.StoreEntry{}, false
	}
	if err != nil {
		internalError(w, "load store song page", err)
		return store.StoreEntry{}, false
	}
	return entry, true
}

func (p *PublicPages) handleStoreTrack(w http.ResponseWriter, r *http.Request) {
	if !enforceRateLimit(w, p.limits.View, clientIP(r)) {
		return
	}
	entry, ok := p.storeEntry(w, r)
	if !ok {
		return
	}
	t := entry.Track
	track := storeTrackPage{
		ID: entry.ID, Title: t.Title, Artist: optional(t.Artist), Album: optional(t.Album),
		Duration: durationText(t.DurationMS), Format: formatText(t.ContentType), Size: sizeText(t.SizeBytes),
	}
	albumArtist := optional(t.AlbumArtist)
	if albumArtist == "" {
		albumArtist = track.Artist
	}
	if track.Artist != "" {
		track.ArtistLink = artistLink(track.Artist)
	}
	if track.Album != "" {
		track.AlbumLink = albumLink(track.Album, albumArtist)
	}
	site := p.origin(r)
	canonical := site + "/store/t/" + entry.ID
	recording := map[string]any{"@context": "https://schema.org", "@type": "MusicRecording", "name": t.Title, "url": canonical}
	description := "«" + t.Title + "»"
	if track.Artist != "" {
		recording["byArtist"] = map[string]any{"@type": "MusicGroup", "name": track.Artist}
		description += " از " + track.Artist
	}
	if track.Album != "" {
		recording["inAlbum"] = map[string]any{"@type": "MusicAlbum", "name": track.Album}
	}
	if t.DurationMS != nil && *t.DurationMS > 0 {
		recording["duration"] = fmt.Sprintf("PT%dM%dS", *t.DurationMS/60000, *t.DurationMS/1000%60)
	}
	description += " را در استور ریتمو با کیفیت اصلی و بدون ثبت‌نام بشنو."
	w.Header().Set("Cache-Control", publicPageMaxAge)
	p.render(w, http.StatusOK, "storeTrack", struct {
		pageMeta
		Track storeTrackPage
	}{
		pageMeta: pageMeta{
			Title: t.Title + func() string {
				if track.Artist != "" {
					return " از " + track.Artist
				}
				return ""
			}() + " — استور ریتمو",
			Description: description, Canonical: canonical, Image: site + "/social.png",
			OGType: "music.song", JSONLD: recording,
		},
		Track: track,
	})
}

// handleStoreStream sends a player to a short-lived URL for a store song's
// best copy, so the page itself never holds an expiring link.
func (p *PublicPages) handleStoreStream(w http.ResponseWriter, r *http.Request) {
	if !enforceRateLimit(w, p.limits.Stream, clientIP(r)) {
		return
	}
	entry, err := p.catalog.StoreEntryByID(r.Context(), r.PathValue("id"), false)
	if errors.Is(err, store.ErrNotFound) {
		http.NotFound(w, r)
		return
	}
	if err != nil {
		internalError(w, "load store song", err)
		return
	}
	url, _, err := p.streams.PresignGet(r.Context(), entry.Track.StorageKey)
	if err != nil {
		internalError(w, "presign store song", err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	http.Redirect(w, r, url, http.StatusFound)
}

// storeSitemapURLs are the store's pages for sitemap.xml.
func (p *PublicPages) storeSitemapURLs(r *http.Request, site string) ([]sitemapURL, error) {
	if p.catalog == nil {
		return nil, nil
	}
	urls := []sitemapURL{{Loc: site + "/store"}, {Loc: site + "/store/artists"}, {Loc: site + "/store/albums"}}
	artists, _, err := p.catalog.StoreArtists(r.Context(), "", sitemapStoreArtists, 0)
	if err != nil {
		return nil, err
	}
	for _, a := range artists {
		urls = append(urls, sitemapURL{Loc: site + artistLink(a.Name)})
	}
	entries, _, err := p.catalog.StoreEntries(r.Context(), store.StoreQuery{Limit: sitemapStoreTracks})
	if err != nil {
		return nil, err
	}
	for _, entry := range entries {
		urls = append(urls, sitemapURL{Loc: site + "/store/t/" + entry.ID})
	}
	return urls, nil
}
