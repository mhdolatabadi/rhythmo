package httpapi

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The browser regression consumes HTML from the real handlers and templates.
// Normal unit runs need no browser or filesystem output.
func TestPublicDesignPreview(t *testing.T) {
	dir := os.Getenv("RHYTHMO_PUBLIC_PREVIEW_DIR")
	if dir == "" {
		t.Skip("browser preview export not requested")
	}
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	site, catalog := storeSite(t, AnonymousLimits{})
	catalog.entry.Track.Title = "آهنگ با عنوان بسیار طولانی " + strings.Repeat("LongTitle", 20)
	for name, path := range map[string]string{
		"home": "/", "playlist": "/p/" + strings.Repeat("A", 22),
		"store": "/store", "artists": "/store/artists",
		"song":    "/store/t/" + storeEntryID,
		"privacy": "/privacy", "delete": "/delete-account",
	} {
		response := get(site, path)
		if response.Code != 200 {
			t.Fatalf("%s returned %d", path, response.Code)
		}
		if err := os.WriteFile(filepath.Join(dir, name+".html"), response.Body.Bytes(), 0600); err != nil {
			t.Fatal(err)
		}
	}
}
