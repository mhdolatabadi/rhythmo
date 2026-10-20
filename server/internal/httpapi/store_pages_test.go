package httpapi

import (
	"encoding/json"
	"image/jpeg"
	"net/http"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

// storeSongPath is the fake store song's page, with its slug.
const storeSongPath = "/store/t/" + storeEntryID + "/%D8%A8%D8%A7%D8%B1%D8%A7%D9%86-ac-dc"

func storeSite(t *testing.T, limits AnonymousLimits) (http.Handler, *fakeCatalog) {
	t.Helper()
	duration := int32(245_000)
	catalog := &fakeCatalog{owners: map[string]bool{}, entry: store.StoreEntry{
		ID: storeEntryID, Copies: 2,
		Track: store.Track{ID: "track-of-alice", OwnerID: "alice", Title: "باران", Artist: str("AC/DC"),
			Album: str("Seasons"), FileName: "alice-private-name.flac", StorageKey: "users/alice/tracks/t/a.flac",
			Comment: str("my note"), ContentType: "audio/flac", SizeBytes: 31_876_000, DurationMS: &duration},
	}}
	token := strings.Repeat("A", 22)
	pages := NewPublicPages(&sharingStore{token: &token, public: true, name: "mix"}, fixedPresigner{}, limits).WithStore(catalog)
	return NewHandler(Config{Public: pages}), catalog
}

func TestStorePagesListSongsWithoutTheirOwners(t *testing.T) {
	site, catalog := storeSite(t, AnonymousLimits{})
	for _, path := range []string{"/store", "/store?q=باران", storeSongPath,
		"/store/artists", "/store/artists/AC%2FDC", "/store/albums", "/store/albums/Seasons?artist=AC%2FDC"} {
		response := get(site, path)
		page := response.Body.String()
		if response.Code != http.StatusOK || !strings.Contains(page, "استور") {
			t.Fatalf("%s = %d", path, response.Code)
		}
		for _, leak := range []string{"alice", "track-of-alice", "my note", "a.flac"} {
			if strings.Contains(page, leak) {
				t.Errorf("%s shows %q", path, leak)
			}
		}
		assertHardeningHeaders(t, response.Header(), pageContentSecurityPolicy)
	}

	page := get(site, storeSongPath).Body.String()
	for _, want := range []string{"<h1 dir=\"auto\">باران</h1>", `href="/store/artists/AC%2FDC"`,
		`href="/store/albums/Seasons?artist=AC%2FDC"`, "۴:۰۵", "FLAC", "۳۰٫۴ مگابایت",
		`src="/store/t/` + storeEntryID + `/stream"`, `href="/app/?store=` + storeEntryID + `"`,
		`<link rel="canonical" href="https://rhythmo.example.com` + storeSongPath + `">`} {
		if !strings.Contains(page, want) {
			t.Errorf("song page lacks %q", want)
		}
	}
	recording := jsonLD(t, page)
	if recording["@type"] != "MusicRecording" || recording["duration"] != "PT4M5S" {
		t.Errorf("song structured data = %v", recording)
	}

	// The artist page asks the catalog for that artist, slash and all.
	get(site, "/store/artists/AC%2FDC")
	if catalog.query.Artist != "AC/DC" {
		t.Errorf("artist query = %+v", catalog.query)
	}
	get(site, "/store/albums/Seasons?artist=AC%2FDC&page=2")
	if catalog.query.Album != "Seasons" || catalog.query.Artist != "AC/DC" || catalog.query.Offset != storePageSize {
		t.Errorf("album query = %+v", catalog.query)
	}
	// The fake always says more follow: page links keep the album artist.
	album := get(site, "/store/albums/Seasons?artist=AC%2FDC&page=2").Body.String()
	for _, want := range []string{`href="/store/albums/Seasons?artist=AC%2FDC" rel="prev"`,
		`href="/store/albums/Seasons?artist=AC%2FDC&amp;page=3" rel="next"`} {
		if !strings.Contains(album, want) {
			t.Errorf("album page lacks %q", want)
		}
	}

	// Search results are searchable, not indexed; the catalog sees the words.
	results := get(site, "/store?q=%20باران%20").Body.String()
	if !strings.Contains(results, `<meta name="robots" content="noindex">`) || catalog.query.Search != "باران" {
		t.Errorf("search results: query %+v", catalog.query)
	}
	if !strings.Contains(results, `value="باران"`) {
		t.Error("the search box lost the query")
	}
	if listing := get(site, "/store").Body.String(); strings.Contains(listing, "noindex") {
		t.Error("the store listing is not indexed")
	}
}

func TestStoreSongPagesFollowTheCatalog(t *testing.T) {
	site, catalog := storeSite(t, AnonymousLimits{})
	stream := get(site, "/store/t/"+storeEntryID+"/stream")
	if stream.Code != http.StatusFound || !strings.Contains(stream.Header().Get("Location"), "users/alice/tracks/t/a.flac") ||
		stream.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("stream = %d %v", stream.Code, stream.Header())
	}
	catalog.hidden = true
	if response := get(site, storeSongPath); response.Code != http.StatusNotFound ||
		!strings.Contains(response.Body.String(), "noindex") {
		t.Fatalf("hidden song page = %d", response.Code)
	}
	if response := get(site, "/store/t/"+storeEntryID+"/stream"); response.Code != http.StatusNotFound {
		t.Fatalf("hidden song stream = %d", response.Code)
	}
	if listing := get(site, "/store").Body.String(); !strings.Contains(listing, "هنوز آهنگی در استور نیست") {
		t.Fatal("the empty store says nothing")
	}
}

func TestStorePagesUseTheVisitorLimits(t *testing.T) {
	site, _ := storeSite(t, AnonymousLimits{
		View:   NewRateLimiter(RateLimit{Requests: 2, Window: time.Hour}, 100),
		Stream: NewRateLimiter(RateLimit{Requests: 1, Window: time.Hour}, 100),
	})
	get(site, "/store")
	get(site, "/store/artists")
	if response := get(site, storeSongPath); response.Code != http.StatusTooManyRequests {
		t.Fatalf("past the view limit = %d", response.Code)
	}
	get(site, "/store/t/"+storeEntryID+"/stream")
	if response := get(site, "/store/t/"+storeEntryID+"/stream"); response.Code != http.StatusTooManyRequests {
		t.Fatalf("past the stream limit = %d", response.Code)
	}
}

func TestSitemapListsTheStore(t *testing.T) {
	site, _ := storeSite(t, AnonymousLimits{})
	sitemap := fullSitemap(t, site)
	for _, want := range []string{"https://rhythmo.example.com/store</loc>", "/store/artists</loc>", "/store/albums</loc>",
		"/store/artists/Kayhan</loc>", storeSongPath + "</loc>"} {
		if !strings.Contains(sitemap, want) {
			t.Errorf("sitemap lacks %q", want)
		}
	}
}

func TestStorePagesNeedNoScript(t *testing.T) {
	site, _ := storeSite(t, AnonymousLimits{})
	scriptTag := regexp.MustCompile(`<script[^>]*>`)
	for _, path := range []string{"/store", storeSongPath, "/store/artists", "/store/albums"} {
		page := get(site, path).Body.String()
		for _, tag := range scriptTag.FindAllString(page, -1) {
			if tag != `<script type="application/ld+json">` {
				t.Errorf("%s has an executable script: %s", path, tag)
			}
		}
		if regexp.MustCompile(`\son[a-z]+=`).MatchString(page) || strings.Contains(page, "javascript:") {
			t.Errorf("%s runs script", path)
		}
	}
}

func TestLegalTextMentionsTheStore(t *testing.T) {
	site, _ := storeSite(t, AnonymousLimits{})
	privacy := get(site, "/privacy").Body.String()
	if !strings.Contains(privacy, "استور ریتمو") || !strings.Contains(privacy, "نشانی از صاحب آهنگ نمایش داده نمی‌شود") {
		t.Error("the privacy page doesn't say public playlists are listed in the store")
	}
	if home := get(site, "/").Body.String(); !strings.Contains(home, "استور ریتمو چیست؟") || !strings.Contains(home, `href="/store"`) {
		t.Error("the front page doesn't explain or link the store")
	}
}

// ldScripts returns every JSON-LD block on the page, failing on invalid JSON.
func ldScripts(t *testing.T, page string) []map[string]any {
	t.Helper()
	var blocks []map[string]any
	for _, match := range regexp.MustCompile(`(?s)<script type="application/ld\+json">(.*?)</script>`).FindAllStringSubmatch(page, -1) {
		var data map[string]any
		if err := json.Unmarshal([]byte(match[1]), &data); err != nil {
			t.Fatalf("JSON-LD is not JSON: %v\n%s", err, match[1])
		}
		blocks = append(blocks, data)
	}
	return blocks
}

// breadcrumbNames returns the page's BreadcrumbList names and links.
func breadcrumbNames(t *testing.T, page string) []string {
	t.Helper()
	for _, block := range ldScripts(t, page) {
		if block["@type"] != "BreadcrumbList" {
			continue
		}
		var names []string
		for _, item := range block["itemListElement"].([]any) {
			entry := item.(map[string]any)
			link, _ := entry["item"].(string)
			names = append(names, entry["name"].(string)+"|"+link)
		}
		return names
	}
	t.Fatal("no BreadcrumbList on the page")
	return nil
}

func TestPlaylistPageLinksItsSongsToTheStore(t *testing.T) {
	_, catalog := storeSite(t, AnonymousLimits{})
	token := strings.Repeat("A", 22)
	artist := "AC/DC"
	data := &sharingStore{token: &token, public: true, name: "Road trip", tracks: []store.Track{
		{ID: "track-of-alice", Title: "باران", Artist: &artist, StorageKey: "k1"},
		{ID: "not-in-store", Title: "Elsewhere", Artist: &artist, StorageKey: "k2"},
	}}
	site := NewHandler(Config{Public: NewPublicPages(data, fixedPresigner{}, AnonymousLimits{}).WithStore(catalog)})

	page := get(site, "/p/"+token).Body.String()
	link := `<a class="title" href="` + storeSongPath + `" dir="auto">باران</a>`
	if !strings.Contains(page, link) || strings.Count(page, `href="/store/artists/AC%2FDC"`) != 1 {
		t.Errorf("the store song is not linked once with its artist:\n%s", page)
	}
	if !strings.Contains(page, `<span class="title" dir="auto">Elsewhere</span>`) {
		t.Error("a song outside the store was linked")
	}
	tracks := jsonLD(t, page)["track"].([]any)
	if tracks[0].(map[string]any)["url"] != "https://rhythmo.example.com"+storeSongPath || tracks[1].(map[string]any)["url"] != nil {
		t.Errorf("playlist structured data = %v", tracks)
	}
	if got := strings.Join(breadcrumbNames(t, page), ","); got != "ریتمو|https://rhythmo.example.com/,فهرست‌های پخش|https://rhythmo.example.com/#playlists,Road trip|" {
		t.Errorf("playlist breadcrumbs = %s", got)
	}

	// Without a store, the page still lists every song, unlinked.
	plain := get(publicSite(data, AnonymousLimits{}), "/p/"+token).Body.String()
	if strings.Contains(plain, "/store/t/") || !strings.Contains(plain, "باران") {
		t.Error("a page without the store linked to it")
	}
	data.tracks = nil
	if empty := get(site, "/p/"+token).Body.String(); !strings.Contains(empty, "این فهرست پخش فعلاً آهنگی ندارد.") {
		t.Error("the empty playlist copy is not Persian")
	}
}

func TestStorePagesHaveBreadcrumbs(t *testing.T) {
	site, _ := storeSite(t, AnonymousLimits{})
	for path, want := range map[string]string{
		"/store": "ریتمو|https://rhythmo.example.com/,استور|",
		storeSongPath: "ریتمو|https://rhythmo.example.com/,استور|https://rhythmo.example.com/store," +
			"AC/DC|https://rhythmo.example.com/store/artists/AC%2FDC,باران|",
		"/store/artists/AC%2FDC": "ریتمو|https://rhythmo.example.com/,استور|https://rhythmo.example.com/store," +
			"خواننده‌ها|https://rhythmo.example.com/store/artists,AC/DC|",
		"/store/albums/Seasons": "ریتمو|https://rhythmo.example.com/,استور|https://rhythmo.example.com/store," +
			"آلبوم‌ها|https://rhythmo.example.com/store/albums,Seasons|",
		"/store/albums": "ریتمو|https://rhythmo.example.com/,استور|https://rhythmo.example.com/store,آلبوم‌ها|",
	} {
		page := get(site, path).Body.String()
		if got := strings.Join(breadcrumbNames(t, page), ","); got != want {
			t.Errorf("%s breadcrumbs = %s", path, got)
		}
		if !strings.Contains(page, `<nav class="crumbs" aria-label="مسیر صفحه">`) || !strings.Contains(page, `<span aria-current="page">`) {
			t.Errorf("%s shows no breadcrumb trail", path)
		}
	}
}

func TestFrontPageLinksToStoreSongs(t *testing.T) {
	site, catalog := storeSite(t, AnonymousLimits{})
	page := get(site, "/").Body.String()
	if !strings.Contains(page, "آهنگ‌های محبوب استور") || !strings.Contains(page, `href="`+storeSongPath+`"`) ||
		catalog.ranked != store.RankPopular {
		t.Error("the front page does not link to popular store songs")
	}
	catalog.hidden = true
	if page := get(site, "/").Body.String(); strings.Contains(page, "آهنگ‌های محبوب استور") {
		t.Error("an empty store still has a front page section")
	}
}

func TestSitemapListsStoreAlbumsAndSongDates(t *testing.T) {
	site, catalog := storeSite(t, AnonymousLimits{})
	catalog.entry.Track.CreatedAt = time.Date(2026, 3, 4, 23, 0, 0, 0, time.UTC)
	sitemap := fullSitemap(t, site)
	for _, want := range []string{"/store/albums/Seasons?artist=AC%2FDC</loc>",
		storeSongPath + "</loc>\n    <lastmod>2026-03-04</lastmod>"} {
		if !strings.Contains(sitemap, want) {
			t.Errorf("sitemap lacks %q:\n%s", want, sitemap)
		}
	}
}

func TestStoreSongURLsCarryAReadableSlug(t *testing.T) {
	site, catalog := storeSite(t, AnonymousLimits{})
	// A bare, stale or differently escaped link moves to the one URL.
	for _, path := range []string{"/store/t/" + storeEntryID, "/store/t/" + storeEntryID + "/old-name"} {
		response := get(site, path)
		if response.Code != http.StatusMovedPermanently || response.Header().Get("Location") != storeSongPath {
			t.Errorf("%s = %d to %q", path, response.Code, response.Header().Get("Location"))
		}
	}
	if response := get(site, "/store/t/"+storeEntryID+"/باران-ac-dc"); response.Code != http.StatusOK {
		t.Errorf("the unescaped slug = %d", response.Code)
	}
	if response := get(site, "/store/t/00000000-0000-0000-0000-000000000000/x"); response.Code != http.StatusNotFound {
		t.Errorf("an unknown song with a slug = %d", response.Code)
	}
	// A song whose slug would be empty, or would be the stream path, keeps
	// the bare URL.
	catalog.entry.Track.Title, catalog.entry.Track.Artist = "Stream", nil
	if response := get(site, "/store/t/"+storeEntryID); response.Code != http.StatusOK {
		t.Errorf("a song titled Stream = %d", response.Code)
	}
	if stream := get(site, "/store/t/"+storeEntryID+"/stream"); stream.Code != http.StatusFound {
		t.Errorf("the stream of a song titled Stream = %d", stream.Code)
	}
}

func TestSongSlug(t *testing.T) {
	for _, c := range []struct{ title, artist, want string }{
		{"باران", "AC/DC", "باران-ac-dc"},
		{"  Hello,  World!! ", "", "hello-world"},
		{"علي‌كوچك", "", "علی-کوچک"},
		{"سَلام", "۲۰۲۴", "سلام-۲۰۲۴"},
		{"!!!", "", ""},
		{"stream", "", ""},
		{strings.Repeat("a", 100), "", strings.Repeat("a", maxSlugRunes)},
		{strings.Repeat("ab ", 40), "", strings.TrimSuffix(strings.Repeat("ab-", 27), "-")},
	} {
		if got := songSlug(c.title, c.artist); got != c.want {
			t.Errorf("songSlug(%q, %q) = %q; want %q", c.title, c.artist, got, c.want)
		}
	}
}

func TestStorePageTitlesFollowPersianSearches(t *testing.T) {
	site, _ := storeSite(t, AnonymousLimits{})
	for path, want := range map[string]string{
		storeSongPath:                          "<title>آهنگ باران از AC/DC | پخش آنلاین در ریتمو</title>",
		"/store/artists/AC%2FDC":               "<title>آهنگ‌های AC/DC | پخش آنلاین در ریتمو</title>",
		"/store/albums/Seasons?artist=AC%2FDC": "<title>آلبوم Seasons از AC/DC | پخش آنلاین در ریتمو</title>",
		"/store":                               "<title>استور ریتمو | پخش آنلاین آهنگ با کیفیت اصلی</title>",
	} {
		if page := get(site, path).Body.String(); !strings.Contains(page, want) {
			t.Errorf("%s lacks %s", path, want)
		}
	}
	song := get(site, storeSongPath).Body.String()
	if !strings.Contains(song, `content="آهنگ «باران» از AC/DC، آلبوم Seasons را آنلاین، با کیفیت اصلی (FLAC) و بدون ثبت‌نام در ریتمو بشنو`) {
		t.Error("the song description does not name its album and format")
	}
}

// ogImage returns the page's og:image URL, failing if it has none.
func ogImage(t *testing.T, page string) string {
	t.Helper()
	match := regexp.MustCompile(`<meta property="og:image" content="([^"]+)">`).FindStringSubmatch(page)
	if match == nil {
		t.Fatal("no og:image")
	}
	return strings.ReplaceAll(match[1], "&amp;", "&")
}

func TestPublicPagesHaveTheirOwnShareImages(t *testing.T) {
	site, catalog := storeSite(t, AnonymousLimits{})
	token := strings.Repeat("A", 22)
	artist := "AC/DC"
	data := &sharingStore{token: &token, public: true, name: "Road trip", tracks: []store.Track{
		{ID: "t1", Title: "باران", Artist: &artist, StorageKey: "k1"},
	}}
	playlistSite := NewHandler(Config{Public: NewPublicPages(data, fixedPresigner{}, AnonymousLimits{}).WithStore(catalog)})

	for _, c := range []struct {
		handler http.Handler
		path    string
		prefix  string
		alt     string
	}{
		{playlistSite, "/p/" + token, "https://rhythmo.example.com/p/" + token + "/og.jpg?v=", "فهرست پخش «Road trip» در ریتمو"},
		{site, storeSongPath, "https://rhythmo.example.com/store/t/" + storeEntryID + "/og.jpg?v=", "آهنگ باران از AC/DC در ریتمو"},
	} {
		page := get(c.handler, c.path).Body.String()
		image := ogImage(t, page)
		if !strings.HasPrefix(image, c.prefix) || !strings.Contains(page, `<meta name="twitter:image" content="`+image+`">`) ||
			!strings.Contains(page, `<meta property="og:image:alt" content="`+c.alt+`">`) {
			t.Errorf("%s share image = %s", c.path, image)
		}
		response := get(c.handler, strings.TrimPrefix(image, "https://rhythmo.example.com"))
		if response.Code != http.StatusOK || response.Header().Get("Content-Type") != "image/jpeg" ||
			!strings.Contains(response.Header().Get("Cache-Control"), "max-age=604800") {
			t.Fatalf("%s = %d %v", image, response.Code, response.Header())
		}
		if _, err := jpeg.Decode(response.Body); err != nil {
			t.Fatalf("%s is not a JPEG: %v", image, err)
		}
	}

	// What the card says versions its URL.
	before := ogImage(t, get(playlistSite, "/p/"+token).Body.String())
	data.name = "Road trip 2"
	if after := ogImage(t, get(playlistSite, "/p/"+token).Body.String()); after == before {
		t.Error("renaming the playlist kept its share image URL")
	}

	// Link-only playlists and hidden songs have no card.
	data.public = false
	catalog.hidden = true
	for _, path := range []string{"/p/" + token + "/og.jpg", "/store/t/" + storeEntryID + "/og.jpg"} {
		if response := get(playlistSite, path); response.Code != http.StatusNotFound {
			t.Errorf("%s = %d", path, response.Code)
		}
	}
	// Other pages keep the site's own card.
	if image := ogImage(t, get(site, "/store").Body.String()); image != "https://rhythmo.example.com/social.png" {
		t.Errorf("store listing image = %s", image)
	}
}

// List rows stay scannable; detailed size and format belong to the song page.
func TestStoreRowsShowArtistWithoutFileSize(t *testing.T) {
	site, _ := storeSite(t, AnonymousLimits{})
	page := get(site, "/store").Body.String()
	if !strings.Contains(page, `<span class="sub"><bdi>AC/DC</bdi></span>`) {
		t.Fatal("store row must show the artist")
	}
	if strings.Contains(page, "۳۰٫۴ مگابایت") {
		t.Fatal("store rows must not show file size")
	}
	if !strings.Contains(get(site, storeSongPath).Body.String(), "۳۰٫۴ مگابایت") {
		t.Fatal("song details must retain file size")
	}
}
