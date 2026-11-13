package httpapi

import (
	"net/http"
	"net/http/httptest"
	"regexp"
	"strings"
	"testing"

	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

func assertHardeningHeaders(t *testing.T, header http.Header, csp string) {
	t.Helper()
	for name, want := range map[string]string{
		"Strict-Transport-Security":  "max-age=31536000",
		"X-Content-Type-Options":     "nosniff",
		"X-Frame-Options":            "DENY",
		"Referrer-Policy":            "strict-origin-when-cross-origin",
		"Cross-Origin-Opener-Policy": "same-origin",
		"Content-Security-Policy":    csp,
	} {
		if got := header.Get(name); got != want {
			t.Errorf("%s = %q, want %q", name, got, want)
		}
	}
	if policy := header.Get("Permissions-Policy"); !strings.Contains(policy, "camera=()") || !strings.Contains(policy, "geolocation=()") {
		t.Errorf("Permissions-Policy = %q", policy)
	}
}

func TestAPIResponsesCarrySecurityHeaders(t *testing.T) {
	handler := NewHandler(Config{})
	for _, path := range []string{"/api/v1/health", "/api/v1/missing"} {
		response := get(handler, path)
		assertHardeningHeaders(t, response.Header(), apiContentSecurityPolicy)
	}
}

func TestPreflightCarriesSecurityHeaders(t *testing.T) {
	request := httptest.NewRequest(http.MethodOptions, "/api/v1/health", nil)
	request.Header.Set("Origin", "https://music.example.com")
	request.Header.Set("Access-Control-Request-Method", http.MethodGet)
	response := httptest.NewRecorder()
	NewHandler(Config{AllowedOrigin: "https://music.example.com"}).ServeHTTP(response, request)
	if response.Code != http.StatusNoContent {
		t.Fatalf("preflight = %d", response.Code)
	}
	assertHardeningHeaders(t, response.Header(), apiContentSecurityPolicy)
}

func TestPublicPagesCarryAStrictContentSecurityPolicy(t *testing.T) {
	token := strings.Repeat("A", 22)
	data := &sharingStore{token: &token, public: true, name: "mix", tracks: []store.Track{{ID: "t1", Title: "song"}}}
	site := publicSite(data, AnonymousLimits{})
	for _, path := range []string{"/", "/p/" + token, "/privacy", "/delete-account", "/no-such-page", "/sitemap.xml"} {
		response := get(site, path)
		assertHardeningHeaders(t, response.Header(), pageContentSecurityPolicy)
	}
}

// The page policy allows only the site's own list player, so the pages hold
// no inline script: besides the player, the only script element is the
// JSON-LD data block, which CSP leaves alone.
func TestPublicPagesNeedNoScript(t *testing.T) {
	token := strings.Repeat("A", 22)
	data := &sharingStore{token: &token, public: true, name: "mix", tracks: []store.Track{{ID: "t1", Title: "song"}}}
	site := publicSite(data, AnonymousLimits{})
	scriptTag := regexp.MustCompile(`<script[^>]*>`)
	handlerAttr := regexp.MustCompile(`\son[a-z]+=`)
	for _, path := range []string{"/", "/p/" + token, "/privacy", "/delete-account", "/no-such-page"} {
		page := get(site, path).Body.String()
		for _, tag := range scriptTag.FindAllString(page, -1) {
			if tag != `<script type="application/ld+json">` && tag != `<script src="/player.js" defer>` {
				t.Errorf("%s has an executable script: %s", path, tag)
			}
		}
		if handlerAttr.MatchString(page) {
			t.Errorf("%s has an inline event handler", path)
		}
		if strings.Contains(page, "javascript:") {
			t.Errorf("%s has a javascript: URL", path)
		}
	}
}
