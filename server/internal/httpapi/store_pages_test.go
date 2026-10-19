package httpapi

import (
	"net/http"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

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
	for _, path := range []string{"/store", "/store?q=باران", "/store/t/" + storeEntryID,
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

	page := get(site, "/store/t/"+storeEntryID).Body.String()
	for _, want := range []string{"<h1 dir=\"auto\">باران</h1>", `href="/store/artists/AC%2FDC"`,
		`href="/store/albums/Seasons?artist=AC%2FDC"`, "۴:۰۵", "FLAC", "۳۰٫۴ مگابایت",
		`src="/store/t/` + storeEntryID + `/stream"`, `href="/app/?store=` + storeEntryID + `"`,
		`<link rel="canonical" href="https://rhythmo.example.com/store/t/` + storeEntryID + `">`} {
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
	if response := get(site, "/store/t/"+storeEntryID); response.Code != http.StatusNotFound ||
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
	if response := get(site, "/store/t/"+storeEntryID); response.Code != http.StatusTooManyRequests {
		t.Fatalf("past the view limit = %d", response.Code)
	}
	get(site, "/store/t/"+storeEntryID+"/stream")
	if response := get(site, "/store/t/"+storeEntryID+"/stream"); response.Code != http.StatusTooManyRequests {
		t.Fatalf("past the stream limit = %d", response.Code)
	}
}

func TestSitemapListsTheStore(t *testing.T) {
	site, _ := storeSite(t, AnonymousLimits{})
	sitemap := get(site, "/sitemap.xml").Body.String()
	for _, want := range []string{"https://rhythmo.example.com/store</loc>", "/store/artists</loc>", "/store/albums</loc>",
		"/store/artists/Kayhan</loc>", "/store/t/" + storeEntryID + "</loc>"} {
		if !strings.Contains(sitemap, want) {
			t.Errorf("sitemap lacks %q", want)
		}
	}
}

func TestStorePagesNeedNoScript(t *testing.T) {
	site, _ := storeSite(t, AnonymousLimits{})
	scriptTag := regexp.MustCompile(`<script[^>]*>`)
	for _, path := range []string{"/store", "/store/t/" + storeEntryID, "/store/artists", "/store/albums"} {
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
	if !strings.Contains(get(site, "/store/t/"+storeEntryID).Body.String(), "۳۰٫۴ مگابایت") {
		t.Fatal("song details must retain file size")
	}
}

func TestArtistOverviewWithAndWithoutAlbums(t *testing.T) {
	for _, withAlbums := range []bool{true, false} {
		site, catalog := storeSite(t, AnonymousLimits{})
		catalog.artistAlbums = []store.StoreAlbum{}
		if withAlbums {
			catalog.artistAlbums = append(catalog.artistAlbums, store.StoreAlbum{Name: "باران <آرام>", Artist: str("AC/DC"), TrackCount: 1})
		}
		page := get(site, "/store/artists/AC%2FDC").Body.String()
		if !strings.Contains(page, "۱ آهنگ") || catalog.albumArtist != "AC/DC" {
			t.Fatal("artist totals or album filter missing")
		}
		artist := graphNode(t, jsonLD(t, page), "MusicGroup")
		if artist["name"] != "AC/DC" {
			t.Fatalf("artist = %v", artist)
		}
		if withAlbums {
			if !strings.Contains(page, "۱ آلبوم") || !strings.Contains(page, "باران &lt;آرام&gt;") {
				t.Fatal("album summary missing or unescaped")
			}
		} else if !strings.Contains(page, "۰ آلبوم") || !strings.Contains(page, "هنوز آلبومی از این هنرمند") {
			t.Fatal("empty albums state missing")
		}
	}
}

func TestArtistAlbumPagingKeepsSongPage(t *testing.T) {
	site, catalog := storeSite(t, AnonymousLimits{})
	catalog.artistAlbums = make([]store.StoreAlbum, storePageSize+1)
	for i := range catalog.artistAlbums {
		catalog.artistAlbums[i] = store.StoreAlbum{Name: "Album", Artist: str("AC/DC"), TrackCount: 1}
	}
	page := get(site, "/store/artists/AC%2FDC?page=2").Body.String()
	if !strings.Contains(page, `href="/store/artists/AC%2FDC?albumPage=2&amp;page=2"`) {
		t.Fatal("album pager lost song page")
	}
	page = get(site, "/store/artists/AC%2FDC?albumPage=2&page=2").Body.String()
	if catalog.albumOffset != storePageSize || !strings.Contains(page, `href="/store/artists/AC%2FDC?albumPage=2&amp;page=3"`) {
		t.Fatal("song pager lost album page")
	}
}
