package httpapi

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

// fakePublicProfiles has one visible profile, @sara, with a long bio and a
// playlist with a long name, to stress the page's layout.
type fakePublicProfiles struct{}

func (fakePublicProfiles) ByHandle(_ context.Context, handle, _ string) (store.Profile, error) {
	if handle != "sara" {
		return store.Profile{}, store.ErrNotFound
	}
	return store.Profile{UserID: "u1", Handle: "sara", DisplayName: "سارا",
		Bio: "موسیقی سنتی و " + strings.Repeat("آواز ", 30), Followers: 1200, Following: 3,
		HasAvatar: true, AvatarAt: time.Unix(1700000000, 0)}, nil
}

func (fakePublicProfiles) Playlists(context.Context, string, int) ([]store.ProfilePlaylist, error) {
	return []store.ProfilePlaylist{
		{ShareToken: strings.Repeat("B", 22), Name: "شب‌های " + strings.Repeat("LongName", 15), TrackCount: 12},
	}, nil
}

func (fakePublicProfiles) Listed(context.Context, int) ([]store.Profile, error) {
	return []store.Profile{{Handle: "sara"}}, nil
}

func TestPublicProfilePage(t *testing.T) {
	site, _ := storeSite(t, AnonymousLimits{})
	page := get(site, "/u/Sara")
	body := page.Body.String()
	if page.Code != http.StatusOK || !strings.Contains(body, "@sara") || !strings.Contains(body, "/p/"+strings.Repeat("B", 22)) {
		t.Fatalf("profile page = %d", page.Code)
	}
	if !strings.Contains(body, `"ProfilePage"`) || strings.Contains(body, "@example.com") {
		t.Fatal("structured data missing or an email leaked")
	}
	if code := get(site, "/u/nobody").Code; code != http.StatusNotFound {
		t.Fatalf("missing profile = %d", code)
	}
	if code := get(site, "/u/x!").Code; code != http.StatusNotFound {
		t.Fatalf("bad handle = %d", code)
	}
	sitemap := get(site, "/sitemaps/people.xml").Body.String()
	if !strings.Contains(sitemap, "/u/sara") {
		t.Fatalf("people.xml = %s", sitemap)
	}
	if index := get(site, "/sitemap.xml").Body.String(); !strings.Contains(index, "people.xml") {
		t.Fatalf("index misses people.xml: %s", index)
	}
}
