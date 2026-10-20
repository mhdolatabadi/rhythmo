package httpapi

import (
	"encoding/json"
	"image/png"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

func publicSite(data *sharingStore, limits AnonymousLimits) http.Handler {
	return NewHandler(Config{Public: NewPublicPages(data, fixedPresigner{}, limits)})
}

func get(handler http.Handler, path string) *httptest.ResponseRecorder {
	request := httptest.NewRequest(http.MethodGet, path, nil)
	request.Host = "rhythmo.example.com"
	request.Header.Set("X-Forwarded-Proto", "https")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	return response
}

// jsonLD returns the page's structured data, failing if it isn't valid JSON.
func jsonLD(t *testing.T, page string) map[string]any {
	t.Helper()
	match := regexp.MustCompile(`(?s)<script type="application/ld\+json">(.*?)</script>`).FindStringSubmatch(page)
	if match == nil {
		t.Fatal("no JSON-LD on the page")
	}
	var data map[string]any
	if err := json.Unmarshal([]byte(match[1]), &data); err != nil {
		t.Fatalf("JSON-LD is not JSON: %v\n%s", err, match[1])
	}
	return data
}

// fullSitemap reads sitemap.xml and every sitemap file it lists, one after
// another, failing if any of them is missing.
func fullSitemap(t *testing.T, site http.Handler) string {
	t.Helper()
	index := get(site, "/sitemap.xml").Body.String()
	var all strings.Builder
	for _, match := range regexp.MustCompile(`<loc>https://[^/]+(/sitemaps/[^<]+)</loc>`).FindAllStringSubmatch(index, -1) {
		response := get(site, match[1])
		if response.Code != http.StatusOK {
			t.Fatalf("%s = %d", match[1], response.Code)
		}
		all.WriteString(response.Body.String())
	}
	return all.String()
}

// graphNode returns the @graph entry of the given type, failing if absent.
func graphNode(t *testing.T, data map[string]any, kind string) map[string]any {
	t.Helper()
	graph, _ := data["@graph"].([]any)
	for _, node := range graph {
		if n, ok := node.(map[string]any); ok && n["@type"] == kind {
			return n
		}
	}
	t.Fatalf("no %s in JSON-LD %v", kind, data)
	return nil
}

func TestPublicFrontPageListsPublicPlaylists(t *testing.T) {
	token := strings.Repeat("A", 22)
	evil := `</script><script>alert(1)</script>`
	data := &sharingStore{token: &token, public: true, name: evil, tracks: []store.Track{{ID: "t1", Title: "song"}}}
	site := publicSite(data, AnonymousLimits{})

	response := get(site, "/")
	page := response.Body.String()
	if response.Code != http.StatusOK || !strings.HasPrefix(response.Header().Get("Content-Type"), "text/html") {
		t.Fatalf("front page = %d %s", response.Code, response.Header().Get("Content-Type"))
	}
	for _, want := range []string{
		`<html lang="fa" dir="rtl">`,
		`<link rel="canonical" href="https://rhythmo.example.com/">`,
		`<meta property="og:title"`,
		`href="/p/` + token + `"`,
		`<bdi>a***@example.com</bdi> · ۱ آهنگ`,
		`href="/app/"`,
	} {
		if !strings.Contains(page, want) {
			t.Errorf("front page is missing %q", want)
		}
	}
	if strings.Contains(page, "<script>alert(1)") {
		t.Fatal("a playlist name was not escaped")
	}
	if list := graphNode(t, jsonLD(t, page), "ItemList"); len(list["itemListElement"].([]any)) != 1 {
		t.Fatalf("ItemList = %v", list)
	}
	if response.Header().Get("Cache-Control") != publicPageMaxAge {
		t.Fatalf("cache = %q", response.Header().Get("Cache-Control"))
	}

	data.public = false
	if page := get(site, "/").Body.String(); strings.Contains(page, token) {
		t.Fatal("a link-only playlist was listed")
	}
}

func TestPublicPlaylistPage(t *testing.T) {
	token := strings.Repeat("A", 22)
	artist := `"><img src=x onerror=alert(1)>`
	data := &sharingStore{token: &token, public: true, name: "Road trip", tracks: []store.Track{
		{ID: "t1", Title: "First", Artist: &artist, StorageKey: "users/alice/tracks/t1/a.mp3"},
		{ID: "t2", Title: "Second", StorageKey: "users/alice/tracks/t2/b.mp3"},
	}}
	site := publicSite(data, AnonymousLimits{})

	response := get(site, "/p/"+token)
	page := response.Body.String()
	if response.Code != http.StatusOK {
		t.Fatalf("playlist page = %d", response.Code)
	}
	for _, want := range []string{
		`<title>Road trip | فهرست پخش آنلاین در ریتمو</title>`,
		`<meta name="description" content="فهرست پخش «Road trip» با ۲ آهنگ در ریتمو`,
		`<link rel="canonical" href="https://rhythmo.example.com/p/` + token + `">`,
		`<meta property="og:type" content="music.playlist">`,
		`src="/p/` + token + `/t/t1"`,
		`href="/app/?shared=` + token + `"`,
	} {
		if !strings.Contains(page, want) {
			t.Errorf("playlist page is missing %q", want)
		}
	}
	if strings.Contains(page, "<img src=x") || strings.Contains(page, "users/alice") {
		t.Fatal("user text was not escaped, or a storage key leaked")
	}
	if ld := jsonLD(t, page); ld["@type"] != "MusicPlaylist" || ld["numTracks"] != float64(2) {
		t.Fatalf("JSON-LD = %v", ld)
	}

	// The track link sends the player to a short-lived URL.
	track := get(site, "/p/"+token+"/t/t1")
	if track.Code != http.StatusFound || !strings.Contains(track.Header().Get("Location"), "users/alice/tracks/t1/") {
		t.Fatalf("track = %d %s", track.Code, track.Header().Get("Location"))
	}
	if get(site, "/p/"+token+"/t/elsewhere").Code != http.StatusNotFound {
		t.Fatal("a track outside the playlist played")
	}

	// Link-only, malformed and unknown are all the same unindexed 404.
	data.public = false
	for _, path := range []string{"/p/" + token, "/p/not-a-token", "/p/" + strings.Repeat("B", 22)} {
		response := get(site, path)
		if response.Code != http.StatusNotFound || !strings.Contains(response.Body.String(), `<meta name="robots" content="noindex">`) {
			t.Errorf("%s = %d", path, response.Code)
		}
	}
	if get(site, "/p/"+token+"/t/t1").Code != http.StatusNotFound {
		t.Fatal("a link-only playlist's track played")
	}
}

func TestPublicPagesAreRateLimitedPerIP(t *testing.T) {
	token := strings.Repeat("A", 22)
	data := &sharingStore{token: &token, public: true, tracks: []store.Track{{ID: "t1", StorageKey: "k"}}}
	site := publicSite(data, AnonymousLimits{
		View:   NewRateLimiter(RateLimit{Requests: 2, Window: time.Hour}, 10),
		Stream: NewRateLimiter(RateLimit{Requests: 1, Window: time.Hour}, 10),
	})
	get(site, "/")
	get(site, "/p/"+token)
	if response := get(site, "/"); response.Code != http.StatusTooManyRequests || response.Header().Get("Retry-After") == "" {
		t.Fatalf("third page = %d", response.Code)
	}
	get(site, "/p/"+token+"/t/t1")
	if response := get(site, "/p/"+token+"/t/t1"); response.Code != http.StatusTooManyRequests {
		t.Fatalf("second track = %d", response.Code)
	}
}

func TestSitemapAndRobots(t *testing.T) {
	token := strings.Repeat("A", 22)
	data := &sharingStore{token: &token, public: true}
	site := publicSite(data, AnonymousLimits{})

	sitemap := fullSitemap(t, site)
	for _, want := range []string{
		`<?xml version="1.0" encoding="UTF-8"?>`,
		`<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">`,
		`<loc>https://rhythmo.example.com/</loc>`,
		`<loc>https://rhythmo.example.com/p/` + token + `</loc>`,
	} {
		if !strings.Contains(sitemap, want) {
			t.Errorf("sitemap is missing %q:\n%s", want, sitemap)
		}
	}
	robots := get(site, "/robots.txt").Body.String()
	if !strings.Contains(robots, "Disallow: /app/") || !strings.Contains(robots, "Sitemap: https://rhythmo.example.com/sitemap.xml") {
		t.Fatalf("robots.txt = %s", robots)
	}
	for _, path := range []string{"/rhythmo.png", "/nafir.png"} {
		if icon := get(site, path); icon.Code != http.StatusOK || icon.Header().Get("Content-Type") != "image/png" {
			t.Fatalf("icon %s = %d %s", path, icon.Code, icon.Header().Get("Content-Type"))
		}
	}
	// Only the exact root is the front page; other paths stay 404.
	if get(site, "/elsewhere").Code != http.StatusNotFound {
		t.Fatal("unknown paths should not render the front page")
	}
}

func TestPrivacyPage(t *testing.T) {
	data := &sharingStore{}
	page := func(pages *PublicPages) string {
		t.Helper()
		response := get(NewHandler(Config{Public: pages}), "/privacy")
		if response.Code != http.StatusOK || !strings.HasPrefix(response.Header().Get("Content-Type"), "text/html") {
			t.Fatalf("privacy = %d %q", response.Code, response.Header().Get("Content-Type"))
		}
		return response.Body.String()
	}

	body := page(NewPublicPages(data, fixedPresigner{}, AnonymousLimits{}).WithContact("privacy@example.com"))
	for _, want := range []string{"حریم خصوصی ریتمو", "bcrypt", `href="mailto:privacy@example.com"`, `<link rel="canonical" href="https://rhythmo.example.com/privacy">`} {
		if !strings.Contains(body, want) {
			t.Fatalf("privacy page lacks %q", want)
		}
	}
	// Every public page links to it from the footer.
	if !strings.Contains(body, `<a href="/privacy">حریم خصوصی</a>`) {
		t.Fatal("footer has no privacy link")
	}
	// Without a contact the page still works and links nowhere.
	if body := page(NewPublicPages(data, fixedPresigner{}, AnonymousLimits{})); strings.Contains(body, "mailto:") {
		t.Fatal("privacy page links an empty contact")
	}
}

func TestDeleteAccountPage(t *testing.T) {
	data := &sharingStore{}
	page := func(pages *PublicPages) string {
		t.Helper()
		response := get(NewHandler(Config{Public: pages}), "/delete-account")
		if response.Code != http.StatusOK || !strings.HasPrefix(response.Header().Get("Content-Type"), "text/html") {
			t.Fatalf("delete-account = %d %q", response.Code, response.Header().Get("Content-Type"))
		}
		return response.Body.String()
	}

	body := page(NewPublicPages(data, fixedPresigner{}, AnonymousLimits{}).WithContact("privacy@example.com"))
	for _, want := range []string{
		"حذف حساب کاربری ریتمو",
		"تنظیمات",
		`href="mailto:privacy@example.com?subject=%D8%AD%D8%B0%D9%81%20%D8%AD%D8%B3%D8%A7%D8%A8%20%D9%86%D9%81%DB%8C%D8%B1"`,
		`<link rel="canonical" href="https://rhythmo.example.com/delete-account">`,
		`<a href="/privacy">`,
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("delete-account page lacks %q", want)
		}
	}
	if body := page(NewPublicPages(data, fixedPresigner{}, AnonymousLimits{})); strings.Contains(body, "mailto:") {
		t.Fatal("delete-account page links an empty contact")
	}

	// The privacy policy explains in-app deletion and links here, and every
	// page's footer does too.
	privacy := get(NewHandler(Config{Public: NewPublicPages(data, fixedPresigner{}, AnonymousLimits{})}), "/privacy").Body.String()
	for _, want := range []string{"حذف حساب کاربری</strong>", `<a href="/delete-account">صفحه‌ی حذف حساب کاربری</a>`, `<a href="/delete-account">حذف حساب</a>`} {
		if !strings.Contains(privacy, want) {
			t.Fatalf("privacy page lacks %q", want)
		}
	}
}

func TestPublicPagesUseTheConfiguredSiteOrigin(t *testing.T) {
	token := strings.Repeat("A", 22)
	data := &sharingStore{token: &token, public: true, name: "mix", tracks: []store.Track{{ID: "t1", Title: "song"}}}
	site := NewHandler(Config{Public: NewPublicPages(data, fixedPresigner{}, AnonymousLimits{}).
		WithSite("https://rhythmo.ir/")})

	// The request arrives under another host, as through an IP or an old domain.
	for path, want := range map[string]string{
		"/":                       `<link rel="canonical" href="https://rhythmo.ir/">`,
		"/p/" + token:             `<link rel="canonical" href="https://rhythmo.ir/p/` + token + `">`,
		"/privacy":                `<meta property="og:image" content="https://rhythmo.ir/social.png">`,
		"/sitemap.xml":            `<loc>https://rhythmo.ir/sitemaps/playlists.xml</loc>`,
		"/sitemaps/playlists.xml": `<loc>https://rhythmo.ir/p/` + token + `</loc>`,
		"/robots.txt":             `Sitemap: https://rhythmo.ir/sitemap.xml`,
		"/delete-account":         `<link rel="canonical" href="https://rhythmo.ir/delete-account">`,
	} {
		body := get(site, path).Body.String()
		if !strings.Contains(body, want) || strings.Contains(body, "rhythmo.example.com") {
			t.Errorf("%s does not use the site origin:\n%s", path, body)
		}
	}
}

func TestWithSiteIgnoresAnythingButAnOrigin(t *testing.T) {
	for _, bad := range []string{"", "rhythmo.ir", "ftp://rhythmo.ir", "https://rhythmo.ir/app", "https://u@rhythmo.ir", "https://rhythmo.ir?x=1"} {
		if got := (&PublicPages{}).WithSite(bad).site; got != "" {
			t.Errorf("WithSite(%q) = %q, want the request host", bad, got)
		}
	}
	if got := (&PublicPages{}).WithSite(" http://localhost:8080/ ").site; got != "http://localhost:8080" {
		t.Errorf("WithSite kept %q", got)
	}
}

func TestSitemapListsTheStaticPages(t *testing.T) {
	body := fullSitemap(t, publicSite(&sharingStore{}, AnonymousLimits{}))
	for _, want := range []string{
		"<loc>https://rhythmo.example.com/</loc>",
		"<loc>https://rhythmo.example.com/privacy</loc>",
		"<loc>https://rhythmo.example.com/delete-account</loc>",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("sitemap lacks %s:\n%s", want, body)
		}
	}
}

func TestUnknownPathsAreABrandedNoIndexPage(t *testing.T) {
	site := publicSite(&sharingStore{}, AnonymousLimits{})

	response := get(site, "/no/such/page")
	body := response.Body.String()
	if response.Code != http.StatusNotFound || !strings.HasPrefix(response.Header().Get("Content-Type"), "text/html") {
		t.Fatalf("unknown page = %d %s", response.Code, response.Header().Get("Content-Type"))
	}
	for _, want := range []string{`<meta name="robots" content="noindex">`, "این صفحه پیدا نشد", `href="/"`} {
		if !strings.Contains(body, want) {
			t.Errorf("404 page lacks %s", want)
		}
	}

	// API clients keep getting JSON.
	api := get(site, "/api/v1/no-such-endpoint")
	if api.Code != http.StatusNotFound || !strings.Contains(api.Body.String(), `"error":"not_found"`) {
		t.Fatalf("unknown API path = %d %s", api.Code, api.Body.String())
	}
}

func TestFrontPageCarriesSearchConsoleVerification(t *testing.T) {
	plain := get(publicSite(&sharingStore{}, AnonymousLimits{}), "/").Body.String()
	if strings.Contains(plain, "site-verification") || strings.Contains(plain, "msvalidate") {
		t.Fatal("verification tags without tokens")
	}

	site := NewHandler(Config{Public: NewPublicPages(&sharingStore{}, fixedPresigner{}, AnonymousLimits{}).
		WithVerification(" g-token\"><x ", "b-token")})
	home := get(site, "/").Body.String()
	for _, want := range []string{
		`<meta name="google-site-verification" content="g-token&#34;&gt;&lt;x">`,
		`<meta name="msvalidate.01" content="b-token">`,
	} {
		if !strings.Contains(home, want) {
			t.Errorf("front page lacks %s:\n%s", want, home)
		}
	}
	// Only the front page needs them.
	if privacy := get(site, "/privacy").Body.String(); strings.Contains(privacy, "b-token") {
		t.Error("verification tags leak onto other pages")
	}
}

func TestFrontPageExplainsRhythmoWithFAQ(t *testing.T) {
	site := NewHandler(Config{Public: NewPublicPages(&sharingStore{}, fixedPresigner{}, AnonymousLimits{}).
		WithQuota(2 << 30).WithAndroidApp("https://cafebazaar.ir/app/ir.mhdolatabadi.nafir")})
	page := get(site, "/").Body.String()

	for _, want := range []string{
		"<title>ریتمو | پخش آنلاین موسیقی و فضای ابری برای آهنگ‌هایت</title>",
		"<h1>ریتمو، کتابخانه‌ی موسیقی ابری تو</h1>",
		"کتابخانه‌ی ابری با کیفیت اصلی",
		`<h2 class="section" id="playlists">فهرست‌های پخش محبوب</h2>`,
		`<h2 class="section" id="faq">پرسش‌های رایج</h2>`,
		"بله. هر حساب ۲ گیگابایت فضای ابری برای موسیقی دارد.",
		`href="https://cafebazaar.ir/app/ir.mhdolatabadi.nafir"`,
		`<meta name="twitter:card" content="summary_large_image">`,
		`<meta property="og:image" content="https://rhythmo.example.com/social.png">`,
		`<meta property="og:image:width" content="1200">`,
	} {
		if !strings.Contains(page, want) {
			t.Errorf("front page lacks %s", want)
		}
	}
	// Each feature fits on a 360 px screen: the grid never forces a column
	// wider than the screen.
	if !strings.Contains(page, "minmax(min(100%,250px),1fr)") {
		t.Error("feature grid can overflow narrow screens")
	}

	data := jsonLD(t, page)
	if site := graphNode(t, data, "WebSite"); site["url"] != "https://rhythmo.example.com/" || site["inLanguage"] != "fa" {
		t.Errorf("WebSite = %v", site)
	}
	if org := graphNode(t, data, "Organization"); org["logo"] != "https://rhythmo.example.com/rhythmo.png" {
		t.Errorf("Organization = %v", org)
	}
	faq := graphNode(t, data, "FAQPage")
	questions, _ := faq["mainEntity"].([]any)
	if len(questions) < 4 {
		t.Fatalf("FAQ = %v", faq)
	}
	first := questions[0].(map[string]any)
	answer := first["acceptedAnswer"].(map[string]any)
	if first["@type"] != "Question" || answer["@type"] != "Answer" || !strings.Contains(answer["text"].(string), "۲ گیگابایت") {
		t.Errorf("first question = %v", first)
	}
	// Every visible question is in the structured data, and the other way round.
	for _, q := range questions {
		name := q.(map[string]any)["name"].(string)
		if !strings.Contains(page, "<h3>"+name+"</h3>") {
			t.Errorf("structured question %q is not on the page", name)
		}
	}
}

func TestFrontPageOffersAndroidOnlyForAnHTTPSLink(t *testing.T) {
	for _, link := range []string{"", "http://example.com/app.apk", "javascript:alert(1)", "https://user@example.com/"} {
		site := NewHandler(Config{Public: NewPublicPages(&sharingStore{}, fixedPresigner{}, AnonymousLimits{}).WithAndroidApp(link)})
		if page := get(site, "/").Body.String(); strings.Contains(page, "دریافت اپ اندروید") {
			t.Errorf("Android button shown for %q", link)
		}
	}
}

func TestQuotaText(t *testing.T) {
	for bytes, want := range map[int64]string{1 << 30: "۱ گیگابایت", 5 << 30: "۵ گیگابایت", 500 << 20: "۵۰۰ مگابایت", 1<<30 + 1: "۱۰۲۵ مگابایت"} {
		if got := quotaText(bytes); got != want {
			t.Errorf("quotaText(%d) = %q, want %q", bytes, got, want)
		}
	}
}

func TestSocialImageIsALargeCachedPNG(t *testing.T) {
	response := get(publicSite(&sharingStore{}, AnonymousLimits{}), "/social.png")
	if response.Code != http.StatusOK || response.Header().Get("Content-Type") != "image/png" ||
		!strings.Contains(response.Header().Get("Cache-Control"), "max-age=604800") {
		t.Fatalf("social.png = %d %v", response.Code, response.Header())
	}
	config, err := png.DecodeConfig(response.Body)
	if err != nil || config.Width != 1200 || config.Height != 630 {
		t.Fatalf("social.png is %dx%d (%v), want 1200x630", config.Width, config.Height, err)
	}
}

func TestPublicPagesLoadTheirOwnFont(t *testing.T) {
	site := publicSite(&sharingStore{}, AnonymousLimits{})
	page := get(site, "/")
	body := page.Body.String()
	for _, want := range []string{`<link rel="preload" href="/fonts/vazirmatn-regular.woff2" as="font" type="font/woff2" crossorigin>`,
		`src:url(/fonts/vazirmatn-bold.woff2) format("woff2")`, "font-display:swap"} {
		if !strings.Contains(body, want) {
			t.Errorf("front page lacks %q", want)
		}
	}
	if !strings.Contains(page.Header().Get("Content-Security-Policy"), "font-src 'self'") {
		t.Error("the page's policy blocks its own font")
	}
	for _, name := range []string{"vazirmatn-regular.woff2", "vazirmatn-bold.woff2"} {
		font := get(site, "/fonts/"+name)
		if font.Code != http.StatusOK || font.Header().Get("Content-Type") != "font/woff2" ||
			!strings.HasPrefix(font.Body.String(), "wOF2") {
			t.Errorf("%s = %d %s", name, font.Code, font.Header().Get("Content-Type"))
		}
	}
	if get(site, "/fonts/other.woff2").Code != http.StatusNotFound {
		t.Error("an unknown font was served")
	}
}

func TestUnchangedPublicPagesRevalidateCheaply(t *testing.T) {
	token := strings.Repeat("A", 22)
	data := &sharingStore{token: &token, public: true, name: "Road trip"}
	site := publicSite(data, AnonymousLimits{})
	first := get(site, "/p/"+token)
	etag := first.Header().Get("ETag")
	if etag == "" {
		t.Fatal("no ETag on a public page")
	}
	revalidate := func(header string) *httptest.ResponseRecorder {
		request := httptest.NewRequest(http.MethodGet, "/p/"+token, nil)
		request.Host = "rhythmo.example.com"
		request.Header.Set("X-Forwarded-Proto", "https")
		request.Header.Set("If-None-Match", header)
		response := httptest.NewRecorder()
		site.ServeHTTP(response, request)
		return response
	}
	if response := revalidate(`"other", W/` + etag); response.Code != http.StatusNotModified || response.Body.Len() != 0 {
		t.Fatalf("unchanged page = %d with %d bytes", response.Code, response.Body.Len())
	}
	data.name = "Renamed"
	if response := revalidate(etag); response.Code != http.StatusOK || !strings.Contains(response.Body.String(), "Renamed") {
		t.Fatalf("changed page = %d", response.Code)
	}
	// Not-found pages are never revalidated into a 304.
	if missing := get(site, "/nowhere"); missing.Header().Get("ETag") != "" {
		t.Error("a 404 page has an ETag")
	}
}

func TestPublicPagesShareCurrentBrandInHeaderAndFooter(t *testing.T) {
	token := strings.Repeat("A", 22)
	site := publicSite(&sharingStore{token: &token, public: true, name: "mix"}, AnonymousLimits{})
	for _, path := range []string{"/", "/p/" + token, "/privacy", "/delete-account"} {
		page := get(site, path).Body.String()
		if strings.Count(page, `d="M135 179A34`) != 2 {
			t.Errorf("%s must use the current r monogram in header and footer", path)
		}
		if strings.Contains(page, `rotate(-35`) {
			t.Errorf("%s still contains the old logo", path)
		}
	}
}

func TestSitemapIndexPagesTheStore(t *testing.T) {
	site, catalog := storeSite(t, AnonymousLimits{})
	index := get(site, "/sitemap.xml")
	body := index.Body.String()
	if index.Header().Get("Content-Type") != "application/xml; charset=utf-8" ||
		!strings.Contains(body, `<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">`) {
		t.Fatalf("sitemap index = %s", body)
	}
	for _, file := range []string{"pages.xml", "playlists.xml", "songs-1.xml", "artists-1.xml", "albums-1.xml"} {
		if !strings.Contains(body, "<loc>https://rhythmo.example.com/sitemaps/"+file+"</loc>") {
			t.Errorf("index lacks %s", file)
		}
	}
	// The fake catalog has one item at every offset, so every kind has the
	// most pages and the next one is never listed.
	if !strings.Contains(body, "songs-10.xml") || strings.Contains(body, "songs-11.xml") {
		t.Errorf("songs are not paged up to the cap:\n%s", body)
	}
	get(site, "/sitemaps/songs-3.xml")
	if catalog.query.Offset != 2*sitemapPageSize || catalog.query.Limit != sitemapPageSize {
		t.Errorf("songs-3 asked for %+v", catalog.query)
	}
	for _, path := range []string{"/sitemaps/songs-11.xml", "/sitemaps/songs-0.xml", "/sitemaps/other.xml", "/sitemaps/pages-2.xml"} {
		if response := get(site, path); response.Code != http.StatusNotFound {
			t.Errorf("%s = %d", path, response.Code)
		}
	}
	// An empty later page is not a sitemap.
	catalog.hidden = true
	if response := get(site, "/sitemaps/songs-2.xml"); response.Code != http.StatusNotFound {
		t.Errorf("an empty songs page = %d", response.Code)
	}
	// Without a store, only the site's own sitemaps exist.
	plain := get(publicSite(&sharingStore{}, AnonymousLimits{}), "/sitemap.xml").Body.String()
	if strings.Contains(plain, "songs-") || get(publicSite(&sharingStore{}, AnonymousLimits{}), "/sitemaps/songs-1.xml").Code != http.StatusNotFound {
		t.Errorf("a site without a store lists store sitemaps:\n%s", plain)
	}
}
