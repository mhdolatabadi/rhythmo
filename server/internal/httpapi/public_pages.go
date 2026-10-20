package httpapi

import (
	"bytes"
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"encoding/xml"
	"errors"
	"fmt"
	"html/template"
	"log/slog"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/mhdolatabadi/rhythmo/server/internal/bot"
	"github.com/mhdolatabadi/rhythmo/server/internal/display"
	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

//go:embed public/*.html public/rhythmo.png public/social.png public/fonts/*.woff2
var publicFiles embed.FS

var publicTemplates = map[string]*template.Template{
	"home":     template.Must(template.New("layout.html").Funcs(template.FuncMap{"digits": display.PersianDigits}).ParseFS(publicFiles, "public/layout.html", "public/home.html")),
	"playlist": template.Must(template.New("layout.html").Funcs(template.FuncMap{"digits": display.PersianDigits}).ParseFS(publicFiles, "public/layout.html", "public/playlist.html")),
	"missing":  template.Must(template.New("layout.html").Funcs(template.FuncMap{"digits": display.PersianDigits}).ParseFS(publicFiles, "public/layout.html", "public/missing.html")),
	"privacy":  template.Must(template.New("layout.html").Funcs(template.FuncMap{"digits": display.PersianDigits}).ParseFS(publicFiles, "public/layout.html", "public/privacy.html")),
	"delete":   template.Must(template.New("layout.html").Funcs(template.FuncMap{"digits": display.PersianDigits}).ParseFS(publicFiles, "public/layout.html", "public/delete_account.html")),
}

const (
	// publicListSize is how many popular playlists the front page shows.
	publicListSize = 100
	// homeStoreSize is how many store songs the front page shows.
	homeStoreSize = 8
	// sitemapSize caps the playlists listed in sitemap.xml.
	sitemapSize = 5000
	// publicPageMaxAge lets browsers and proxies reuse a page briefly.
	publicPageMaxAge = "public, max-age=60"
)

// PublicPages serves the public, search-engine-friendly side of rhythmo as
// plain HTML: the most-liked public playlists at /, one public playlist at
// /p/{token}, with sitemap.xml and robots.txt. Visitors need no account;
// link-only and private playlists are never shown.
type PublicPages struct {
	playlists SharedPlaylistStore
	streams   StreamPresigner
	limits    AnonymousLimits
	// quotaBytes is each account's cloud storage, as the front page tells it.
	quotaBytes int64
	// androidApp is where the Android app is installed from; the front page
	// offers it only when set.
	androidApp string
	// contact is the email the privacy page gives for questions and
	// account deletion; the page leaves it out when it is empty.
	contact string
	// site is the configured origin every canonical, Open Graph and sitemap
	// URL uses, so one page never shows up under several hosts; empty
	// falls back to the request's own host.
	site string
	// verify holds the search console ownership tokens for the front page.
	verify siteVerification
	// catalog, when set, serves the public store's pages.
	catalog CatalogStore
	// images keeps the drawn link preview cards.
	images shareImages
}

// siteVerification is the content of the search engines' ownership <meta>
// tags; an empty one is left out.
type siteVerification struct {
	Google string
	Bing   string
}

func NewPublicPages(playlists SharedPlaylistStore, streams StreamPresigner, limits AnonymousLimits) *PublicPages {
	return &PublicPages{playlists: playlists, streams: streams, limits: limits, quotaBytes: 1 << 30}
}

// WithQuota sets the per-account storage the front page mentions.
func (p *PublicPages) WithQuota(bytes int64) *PublicPages {
	if bytes > 0 {
		p.quotaBytes = bytes
	}
	return p
}

// WithAndroidApp sets the https link the Android app is installed from,
// such as its store page; anything else is ignored.
func (p *PublicPages) WithAndroidApp(link string) *PublicPages {
	link = strings.TrimSpace(link)
	if u, err := url.Parse(link); err == nil && u.Scheme == "https" && u.Host != "" && u.User == nil {
		p.androidApp = link
	} else {
		p.androidApp = ""
	}
	return p
}

// quotaText says bytes in Persian, in whole gigabytes or megabytes.
func quotaText(bytes int64) string {
	if bytes >= 1<<30 && bytes%(1<<30) == 0 {
		return display.PersianDigits(bytes>>30) + " گیگابایت"
	}
	return display.PersianDigits((bytes+(1<<20)-1)>>20) + " مگابایت"
}

// publicFeature is one point of what rhythmo does, on the front page.
type publicFeature struct {
	Title string
	Text  string
}

// publicQuestion is one frequently asked question, shown on the front page
// and given to search engines as FAQ structured data.
type publicQuestion struct {
	Question string
	Answer   string
}

var publicFeatures = []publicFeature{
	{"کتابخانه‌ی ابری با کیفیت اصلی", "آهنگ‌هایت را آپلود کن؛ همان فایلی که فرستادی نگه داشته و پخش می‌شود، بدون فشرده‌سازی دوباره."},
	{"فهرست پخش و اشتراک‌گذاری", "فهرست پخش بساز، با لینک یا به‌صورت عمومی به اشتراک بگذار، یا با دوستانت فهرست مشترک بساز."},
	{"وب و اندروید", "در مرورگر بدون نصب گوش بده؛ در اندروید موسیقی خود گوشی را هم ببین و آهنگ‌ها را برای پخش بدون اینترنت دانلود کن."},
	{"مشخصات درست برای هر آهنگ", "نام، خواننده و آلبوم را ویرایش کن؛ فایلی که دانلود می‌کنی همان مشخصات و نام را دارد."},
	{"افزودن از لینک و بات", "آهنگ را با لینک یا از طریق بات‌های بله و تلگرام مستقیم به کتابخانه‌ات بفرست."},
}

func (p *PublicPages) questions() []publicQuestion {
	return []publicQuestion{
		{"ریتمو رایگان است؟", "بله. هر حساب " + quotaText(p.quotaBytes) + " فضای ابری برای موسیقی دارد."},
		{"چه قالب‌هایی را می‌شود آپلود کرد؟", "MP3، M4A، AAC، FLAC، OGG، Opus، WAV و WebM."},
		{"کیفیت آهنگ‌ها کم می‌شود؟", "نه. ریتمو فایل را همان‌طور که آپلود کرده‌ای نگه می‌دارد و پخش می‌کند."},
		{"چه کسی فهرست‌های پخش مرا می‌بیند؟", "فقط خودت، مگر اینکه لینکش را بسازی. فهرستی که «عمومی» کنی در صفحه‌ی اول ریتمو هم نشان داده می‌شود و آهنگ‌هایش، بدون نام یا ایمیل تو، در استور ریتمو می‌آیند."},
		{"استور ریتمو چیست؟", "همه‌ی آهنگ‌های فهرست‌های پخش عمومی، هر آهنگ یک بار، که هر کسی بدون ثبت‌نام می‌شنود و با حساب ریتمو به کتابخانه‌اش اضافه می‌کند. کتابخانه‌های خصوصی هیچ‌وقت در استور نمی‌آیند."},
		{"اپ اندروید هم دارد؟", "بله. ریتمو روی وب بدون نصب کار می‌کند و اپ اندروید هم دارد که موسیقی گوشی را هم نشان می‌دهد و پخش بدون اینترنت دارد."},
		{"چطور حسابم را حذف کنم؟", "از تنظیمات اپ، «حذف حساب کاربری» را بزن. همه‌ی آهنگ‌ها و فهرست‌های پخشت برای همیشه پاک می‌شوند."},
	}
}

func (p *PublicPages) register(mux *http.ServeMux) {
	mux.HandleFunc("GET /{$}", p.handleHome)
	mux.HandleFunc("GET /p/{token}", p.handlePlaylist)
	mux.HandleFunc("GET /p/{token}/t/{trackId}", p.handleTrack)
	mux.HandleFunc("GET /p/{token}/og.jpg", p.handlePlaylistImage)
	mux.HandleFunc("GET /sitemap.xml", p.handleSitemap)
	mux.HandleFunc("GET /robots.txt", p.handleRobots)
	mux.HandleFunc("GET /rhythmo.png", p.handleIcon)
	// The icon's URL before the rename, still in old shares and caches.
	mux.HandleFunc("GET /nafir.png", p.handleIcon)
	mux.HandleFunc("GET /social.png", p.handleSocialImage)
	mux.HandleFunc("GET /fonts/{name}", p.handleFont)
	mux.HandleFunc("GET /privacy", p.handlePrivacy)
	mux.HandleFunc("GET /delete-account", p.handleDeleteAccount)
	p.registerStore(mux)
	mux.HandleFunc("GET /", p.handleNotFound)
}

type pageMeta struct {
	Title       string
	Description string
	Canonical   string
	Image       string
	// ImageAlt describes Image; empty is the site's own card.
	ImageAlt string
	OGType   string
	NoIndex  bool
	// JSONLD is structured data for search engines; it is JSON-encoded
	// safely by html/template inside its script tag.
	JSONLD any
	// Crumbs is the page's place in the site, shown above its content and
	// given to search engines as a BreadcrumbList.
	Crumbs   []crumb
	CrumbsLD any
}

// crumb is one step of a breadcrumb trail; the last one, the page itself,
// has no link.
type crumb struct {
	Name string
	Link string
}

// setCrumbs gives the page a breadcrumb trail that starts at the front page.
func (m *pageMeta) setCrumbs(site string, trail ...crumb) {
	m.Crumbs = append([]crumb{{Name: "ریتمو", Link: "/"}}, trail...)
	items := make([]map[string]any, 0, len(m.Crumbs))
	for i, c := range m.Crumbs {
		item := map[string]any{"@type": "ListItem", "position": i + 1, "name": c.Name}
		if c.Link != "" {
			item["item"] = site + c.Link
		}
		items = append(items, item)
	}
	m.CrumbsLD = map[string]any{"@context": "https://schema.org", "@type": "BreadcrumbList", "itemListElement": items}
}

type publicListItem struct {
	ShareToken string
	Name       string
	Owner      string
	TrackCount int
	LikeCount  int
}

type publicTrack struct {
	Title  string
	Artist string
	Stream string
	// Link and ArtistLink are the song's and its artist's store pages,
	// when the song is in the store.
	Link       string
	ArtistLink string
}

type publicPlaylist struct {
	ShareToken string
	Name       string
	Owner      string
	TrackCount int
	LikeCount  int
	Tracks     []publicTrack
}

// WithSite sets the origin, such as https://rhythmo.ir, that canonical,
// Open Graph and sitemap URLs use. Anything but a plain http(s) origin is
// ignored, and the request's host is used instead.
func (p *PublicPages) WithSite(site string) *PublicPages {
	u, err := url.Parse(strings.TrimRight(strings.TrimSpace(site), "/"))
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" ||
		u.Path != "" || u.RawQuery != "" || u.Fragment != "" || u.User != nil {
		p.site = ""
		return p
	}
	p.site = u.Scheme + "://" + u.Host
	return p
}

// WithVerification sets the Google Search Console and Bing Webmaster Tools
// ownership tokens shown on the front page; empty ones are left out.
func (p *PublicPages) WithVerification(google, bing string) *PublicPages {
	p.verify = siteVerification{Google: strings.TrimSpace(google), Bing: strings.TrimSpace(bing)}
	return p
}

// origin is the configured site origin, or the request's own scheme and
// host when none is set.
func (p *PublicPages) origin(r *http.Request) string {
	if p.site != "" {
		return p.site
	}
	return origin(r)
}

// origin is the site's own scheme and host, as Caddy forwards them.
func origin(r *http.Request) string {
	scheme := "https"
	if r.TLS == nil && r.Header.Get("X-Forwarded-Proto") != "https" {
		scheme = "http"
	}
	return scheme + "://" + r.Host
}

func (p *PublicPages) render(w http.ResponseWriter, r *http.Request, status int, name string, data any) {
	var page bytes.Buffer
	if err := publicTemplates[name].ExecuteTemplate(&page, "layout", data); err != nil {
		internalError(w, "render public page", err)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if status == http.StatusOK {
		// Crawlers and browsers revalidating an unchanged page get a bodiless
		// 304 instead of the whole page again.
		sum := sha256.Sum256(page.Bytes())
		etag := `"` + hex.EncodeToString(sum[:12]) + `"`
		w.Header().Set("ETag", etag)
		if etagMatches(r.Header.Get("If-None-Match"), etag) {
			w.WriteHeader(http.StatusNotModified)
			return
		}
	}
	w.WriteHeader(status)
	_, _ = page.WriteTo(w)
}

// etagMatches reports whether an If-None-Match header names etag.
func etagMatches(header, etag string) bool {
	for _, candidate := range strings.Split(header, ",") {
		candidate = strings.TrimPrefix(strings.TrimSpace(candidate), "W/")
		if candidate == etag || candidate == "*" {
			return true
		}
	}
	return false
}

func (p *PublicPages) handleHome(w http.ResponseWriter, r *http.Request) {
	if !enforceRateLimit(w, p.limits.View, clientIP(r)) {
		return
	}
	listed, err := p.playlists.Popular(r.Context(), "", publicListSize)
	if err != nil {
		internalError(w, "list public playlists", err)
		return
	}
	site := p.origin(r)
	items := make([]publicListItem, 0, len(listed))
	listJSON := make([]map[string]any, 0, len(listed))
	for i, pl := range listed {
		items = append(items, publicListItem{
			ShareToken: pl.ShareToken, Name: pl.Name, Owner: bot.MaskEmail(pl.OwnerEmail),
			TrackCount: pl.TrackCount, LikeCount: pl.Likes.Count,
		})
		listJSON = append(listJSON, map[string]any{
			"@type": "ListItem", "position": i + 1, "url": site + "/p/" + pl.ShareToken, "name": pl.Name,
		})
	}
	songs := p.homeStoreSongs(r)
	questions := p.questions()
	faqJSON := make([]map[string]any, 0, len(questions))
	for _, q := range questions {
		faqJSON = append(faqJSON, map[string]any{
			"@type": "Question", "name": q.Question,
			"acceptedAnswer": map[string]any{"@type": "Answer", "text": q.Answer},
		})
	}
	w.Header().Set("Cache-Control", publicPageMaxAge)
	p.render(w, r, http.StatusOK, "home", struct {
		pageMeta
		Verify     siteVerification
		Features   []publicFeature
		Questions  []publicQuestion
		AndroidApp string
		Playlists  []publicListItem
		Songs      []storePageTrack
	}{
		Verify: p.verify,
		pageMeta: pageMeta{
			Title: "ریتمو | پخش آنلاین موسیقی و فضای ابری برای آهنگ‌هایت",
			Description: "ریتمو کتابخانه‌ی موسیقی ابری توست: آهنگ‌هایت را با کیفیت اصلی آپلود کن، " +
				"فهرست پخش بساز و روی وب و اندروید گوش بده. فهرست‌های پخش محبوب را بدون ثبت‌نام بشنو.",
			Canonical: site + "/", Image: site + "/social.png", OGType: "website",
			JSONLD: map[string]any{
				"@context": "https://schema.org",
				"@graph": []map[string]any{
					{"@type": "WebSite", "@id": site + "/#website", "name": "ریتمو", "alternateName": "rhythmo",
						"url": site + "/", "inLanguage": "fa"},
					{"@type": "Organization", "@id": site + "/#organization", "name": "ریتمو", "url": site + "/",
						"logo": site + "/rhythmo.png"},
					{"@type": "ItemList", "name": "فهرست‌های پخش محبوب ریتمو", "itemListElement": listJSON},
					{"@type": "FAQPage", "mainEntity": faqJSON},
				},
			},
		},
		Features: publicFeatures, Questions: questions, AndroidApp: p.androidApp,
		Playlists: items, Songs: songs,
	})
}

// homeStoreSongs are the store's most popular songs, or its first ones
// while nothing has been played yet. The store only adds to the front page,
// so a failure leaves the section out rather than failing the page.
func (p *PublicPages) homeStoreSongs(r *http.Request) []storePageTrack {
	if p.catalog == nil {
		return nil
	}
	entries, _, err := p.catalog.StoreRanked(r.Context(), store.RankPopular, homeStoreSize, 0)
	if err == nil && len(entries) == 0 {
		entries, _, err = p.catalog.StoreEntries(r.Context(), store.StoreQuery{Limit: homeStoreSize})
	}
	if err != nil {
		slog.Error("request failed", "action", "list front page store songs", "error", err)
		return nil
	}
	songs := make([]storePageTrack, 0, len(entries))
	for _, entry := range entries {
		songs = append(songs, storePageTrack{
			ID: entry.ID, Link: storeTrackLink(entry), Title: entry.Track.Title, Artist: optional(entry.Track.Artist),
		})
	}
	return songs
}

// renderMissing writes the branded not-found page, which search engines
// are told not to index.
func (p *PublicPages) renderMissing(w http.ResponseWriter, r *http.Request, heading, body, description string) {
	site := p.origin(r)
	p.render(w, r, http.StatusNotFound, "missing", struct {
		pageMeta
		Heading string
		Body    string
	}{
		pageMeta: pageMeta{
			Title: "پیدا نشد — ریتمو", Description: description,
			Canonical: site + r.URL.Path, Image: site + "/social.png", OGType: "website", NoIndex: true,
		},
		Heading: heading, Body: body,
	})
}

// handleNotFound answers every path nothing else serves: API clients get
// the usual JSON error, people and crawlers the branded page.
func (p *PublicPages) handleNotFound(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path == "/api" || strings.HasPrefix(r.URL.Path, "/api/") {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	p.renderMissing(w, r, "این صفحه پیدا نشد",
		"نشانی را بررسی کن یا از صفحه‌ی اول ادامه بده.",
		"صفحه‌ای که دنبالش بودی در ریتمو پیدا نشد.")
}

// publicPlaylistFor loads the public playlist at {token}, or writes the
// not-found page: link-only and private playlists look the same as missing.
func (p *PublicPages) publicPlaylistFor(w http.ResponseWriter, r *http.Request) (store.SharedPlaylist, bool) {
	token := r.PathValue("token")
	shared := store.SharedPlaylist{}
	err := store.ErrNotFound
	if validShareToken(token) {
		shared, err = p.playlists.ForShareToken(r.Context(), token)
	}
	if err == nil && !shared.IsPublic {
		err = store.ErrNotFound
	}
	if errors.Is(err, store.ErrNotFound) {
		p.renderMissing(w, r, "این فهرست پخش پیدا نشد",
			"ممکن است صاحبش آن را خصوصی کرده یا حذف کرده باشد.",
			"این فهرست پخش عمومی نیست یا حذف شده است.")
		return store.SharedPlaylist{}, false
	}
	if err != nil {
		internalError(w, "load public playlist", err)
		return store.SharedPlaylist{}, false
	}
	return shared, true
}

func (p *PublicPages) handlePlaylist(w http.ResponseWriter, r *http.Request) {
	if !enforceRateLimit(w, p.limits.View, clientIP(r)) {
		return
	}
	shared, ok := p.publicPlaylistFor(w, r)
	if !ok {
		return
	}
	likes, err := p.playlists.LikesFor(r.Context(), shared.ID, "")
	if err != nil {
		internalError(w, "load playlist likes", err)
		return
	}
	site := p.origin(r)
	token := *shared.ShareToken
	page := publicPlaylist{
		ShareToken: token, Name: shared.Name, Owner: bot.MaskEmail(shared.OwnerEmail),
		TrackCount: len(shared.Tracks), LikeCount: likes.Count,
	}
	inStore := p.storeEntriesFor(r, shared.Tracks)
	recordings := make([]map[string]any, 0, len(shared.Tracks))
	for _, t := range shared.Tracks {
		artist := ""
		if t.Artist != nil {
			artist = strings.TrimSpace(*t.Artist)
		}
		track := publicTrack{Title: t.Title, Artist: artist, Stream: "/p/" + token + "/t/" + t.ID}
		recording := map[string]any{"@type": "MusicRecording", "name": t.Title}
		if entry, ok := inStore[t.ID]; ok {
			track.Link = storeTrackLink(entry)
			recording["url"] = site + track.Link
			if artist != "" {
				track.ArtistLink = artistLink(artist)
			}
		}
		page.Tracks = append(page.Tracks, track)
		if artist != "" {
			recording["byArtist"] = map[string]any{"@type": "MusicGroup", "name": artist}
		}
		recordings = append(recordings, recording)
	}
	artists := playlistArtists(shared.Tracks)
	description := fmt.Sprintf("فهرست پخش «%s» با %s آهنگ در ریتمو", shared.Name, display.PersianDigits(len(shared.Tracks)))
	if len(artists) > 0 {
		description += "، از " + strings.Join(artists, "، ")
	}
	description += ". آنلاین و بدون ثبت‌نام بشنو."
	canonical := site + "/p/" + token
	meta := pageMeta{
		Title:       shared.Name + " | فهرست پخش آنلاین در ریتمو",
		Description: description,
		Canonical:   canonical, OGType: "music.playlist",
		Image:    shareImageURL(site, "/p/"+token+"/og.jpg", playlistCard(site, shared.Name, len(shared.Tracks), artists)),
		ImageAlt: "فهرست پخش «" + shared.Name + "» در ریتمو",
		JSONLD: map[string]any{
			"@context": "https://schema.org", "@type": "MusicPlaylist",
			"name": shared.Name, "url": canonical, "numTracks": len(shared.Tracks), "track": recordings,
		},
	}
	meta.setCrumbs(site, crumb{Name: "فهرست‌های پخش", Link: "/#playlists"}, crumb{Name: shared.Name})
	w.Header().Set("Cache-Control", publicPageMaxAge)
	p.render(w, r, http.StatusOK, "playlist", struct {
		pageMeta
		Playlist publicPlaylist
	}{pageMeta: meta, Playlist: page})
}

// playlistArtists are the first five different artists of a playlist.
func playlistArtists(tracks []store.Track) []string {
	var artists []string
	seen := map[string]bool{}
	for _, t := range tracks {
		artist := optional(t.Artist)
		if artist != "" && !seen[strings.ToLower(artist)] && len(artists) < 5 {
			seen[strings.ToLower(artist)] = true
			artists = append(artists, artist)
		}
	}
	return artists
}

// handlePlaylistImage draws a public playlist's link preview.
func (p *PublicPages) handlePlaylistImage(w http.ResponseWriter, r *http.Request) {
	if !enforceRateLimit(w, p.limits.View, clientIP(r)) {
		return
	}
	shared, ok := p.publicPlaylistFor(w, r)
	if !ok {
		return
	}
	p.serveShareImage(w, playlistCard(p.origin(r), shared.Name, len(shared.Tracks), playlistArtists(shared.Tracks)))
}

// storeEntriesFor maps the tracks that are in the store to their entries.
// The store only adds links, so a failure leaves them out rather than
// failing the page.
func (p *PublicPages) storeEntriesFor(r *http.Request, tracks []store.Track) map[string]store.StoreEntry {
	if p.catalog == nil || len(tracks) == 0 {
		return nil
	}
	ids := make([]string, len(tracks))
	for i, t := range tracks {
		ids[i] = t.ID
	}
	found, err := p.catalog.StoreEntriesForTracks(r.Context(), ids)
	if err != nil {
		slog.Error("request failed", "action", "find playlist songs in the store", "error", err)
		return nil
	}
	return found
}

// handleTrack sends a player to a short-lived URL for one track of a public
// playlist, so the page itself never holds an expiring link.
func (p *PublicPages) handleTrack(w http.ResponseWriter, r *http.Request) {
	if !enforceRateLimit(w, p.limits.Stream, clientIP(r)) {
		return
	}
	token := r.PathValue("token")
	if !validShareToken(token) {
		http.NotFound(w, r)
		return
	}
	track, err := p.playlists.SharedTrack(r.Context(), token, r.PathValue("trackId"), true)
	if errors.Is(err, store.ErrNotFound) {
		http.NotFound(w, r)
		return
	}
	if err != nil {
		internalError(w, "load public track", err)
		return
	}
	url, _, err := p.streams.PresignGet(r.Context(), track.StorageKey)
	if err != nil {
		internalError(w, "presign public track", err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	http.Redirect(w, r, url, http.StatusFound)
}

type sitemapURL struct {
	Loc     string `xml:"loc"`
	LastMod string `xml:"lastmod,omitempty"`
}

// lastMod is a sitemap date, or empty for an unknown time.
func lastMod(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.UTC().Format(time.DateOnly)
}

type sitemap struct {
	XMLName xml.Name     `xml:"urlset"`
	XMLNS   string       `xml:"xmlns,attr"`
	URLs    []sitemapURL `xml:"url"`
}

func (p *PublicPages) handleSitemap(w http.ResponseWriter, r *http.Request) {
	listed, err := p.playlists.Popular(r.Context(), "", sitemapSize)
	if err != nil {
		internalError(w, "list sitemap playlists", err)
		return
	}
	site := p.origin(r)
	urls := []sitemapURL{{Loc: site + "/"}, {Loc: site + "/privacy"}, {Loc: site + "/delete-account"}}
	for _, pl := range listed {
		urls = append(urls, sitemapURL{
			Loc: site + "/p/" + pl.ShareToken, LastMod: lastMod(pl.UpdatedAt),
		})
	}
	storeURLs, err := p.storeSitemapURLs(r, site)
	if err != nil {
		internalError(w, "list sitemap store pages", err)
		return
	}
	urls = append(urls, storeURLs...)
	body, err := xml.MarshalIndent(sitemap{XMLNS: "http://www.sitemaps.org/schemas/sitemap/0.9", URLs: urls}, "", "  ")
	if err != nil {
		internalError(w, "encode sitemap", err)
		return
	}
	w.Header().Set("Content-Type", "application/xml; charset=utf-8")
	w.Header().Set("Cache-Control", "public, max-age=3600")
	_, _ = w.Write([]byte(xml.Header))
	_, _ = w.Write(body)
}

func (p *PublicPages) handleRobots(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("Cache-Control", "public, max-age=3600")
	fmt.Fprintf(w, "User-agent: *\nAllow: /\nDisallow: /app/\nDisallow: /api/\nSitemap: %s/sitemap.xml\n", p.origin(r))
}

// WithContact sets the email the privacy page gives for questions and
// account deletion.
func (p *PublicPages) WithContact(email string) *PublicPages {
	p.contact = strings.TrimSpace(email)
	return p
}

// privacyUpdated is when the privacy policy text last changed.
const privacyUpdated = "۲۳ مهر ۱۴۰۵"

// handlePrivacy serves the privacy policy app stores link to.
func (p *PublicPages) handlePrivacy(w http.ResponseWriter, r *http.Request) {
	site := p.origin(r)
	w.Header().Set("Cache-Control", "public, max-age=3600")
	p.render(w, r, http.StatusOK, "privacy", struct {
		pageMeta
		Updated string
		Contact string
	}{
		pageMeta: pageMeta{
			Title:       "حریم خصوصی — ریتمو",
			Description: "ریتمو چه اطلاعاتی نگه می‌دارد، چه کسی آن را می‌بیند و چطور حذفش کنی.",
			Canonical:   site + "/privacy", Image: site + "/social.png", OGType: "website",
		},
		Updated: privacyUpdated,
		Contact: p.contact,
	})
}

// deleteAccountUpdated is when the account deletion page last changed.
const deleteAccountUpdated = "۱۰ مهر ۱۴۰۵"

// handleDeleteAccount serves the account deletion page app stores link to,
// for people who no longer have the app.
func (p *PublicPages) handleDeleteAccount(w http.ResponseWriter, r *http.Request) {
	site := p.origin(r)
	w.Header().Set("Cache-Control", "public, max-age=3600")
	p.render(w, r, http.StatusOK, "delete", struct {
		pageMeta
		Updated string
		Contact string
	}{
		pageMeta: pageMeta{
			Title:       "حذف حساب کاربری — ریتمو",
			Description: "چطور حساب ریتمو و همه‌ی موسیقی‌ها و فهرست‌های پخشت را برای همیشه حذف کنی.",
			Canonical:   site + "/delete-account", Image: site + "/social.png", OGType: "website",
		},
		Updated: deleteAccountUpdated,
		Contact: p.contact,
	})
}

// handleSocialImage serves the 1200×630 card link previews show.
func (p *PublicPages) handleSocialImage(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "public, max-age=604800")
	http.ServeFileFS(w, r, publicFiles, "public/social.png")
}

// publicFonts are the Vazirmatn faces the public pages use, cut down to
// the Persian, Arabic and Latin letters they need.
var publicFonts = map[string]bool{"vazirmatn-regular.woff2": true, "vazirmatn-bold.woff2": true}

func (p *PublicPages) handleFont(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	if !publicFonts[name] {
		p.handleNotFound(w, r)
		return
	}
	w.Header().Set("Cache-Control", "public, max-age=2592000")
	w.Header().Set("Content-Type", "font/woff2")
	http.ServeFileFS(w, r, publicFiles, "public/fonts/"+name)
}

func (p *PublicPages) handleIcon(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "public, max-age=86400")
	http.ServeFileFS(w, r, publicFiles, "public/rhythmo.png")
}
