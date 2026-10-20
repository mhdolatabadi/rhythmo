package httpapi

import (
	"net/http"
	"strings"
)

// apiContentSecurityPolicy fits JSON: a response rendered as a page can load
// nothing and can't be framed.
const apiContentSecurityPolicy = "default-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"

// pageContentSecurityPolicy fits the server-rendered public pages: no
// scripts (the JSON-LD block is data, not script), the inline styles the
// templates use, the site's own images and the track previews, which play
// from presigned storage URLs that may be on another https origin.
const pageContentSecurityPolicy = "default-src 'none'; style-src 'unsafe-inline'; img-src 'self' data:; font-src 'self'; " +
	"media-src 'self' https:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"

// securityHeaders sets the browser hardening headers on every response, so
// the API and public pages get them behind Caddy and the shared nginx alike.
// HSTS is ignored by browsers on plain http, so local development is safe.
func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Strict-Transport-Security", "max-age=31536000")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Referrer-Policy", "strict-origin-when-cross-origin")
		h.Set("Permissions-Policy", "camera=(), microphone=(), geolocation=(), payment=(), usb=(), interest-cohort=()")
		h.Set("Cross-Origin-Opener-Policy", "same-origin")
		if r.URL.Path == "/api" || strings.HasPrefix(r.URL.Path, "/api/") {
			h.Set("Content-Security-Policy", apiContentSecurityPolicy)
		} else {
			h.Set("Content-Security-Policy", pageContentSecurityPolicy)
		}
		next.ServeHTTP(w, r)
	})
}
