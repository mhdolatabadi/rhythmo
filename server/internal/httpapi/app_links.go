package httpapi

import (
	"encoding/json"
	"net/http"
	"regexp"
	"strings"
)

// androidPackage is the Android application ID. It keeps its old name so
// existing installs keep updating.
const androidPackage = "ir.mhdolatabadi.nafir"

// certFingerprint is an upper-case SHA-256 signing certificate fingerprint
// in the colon-separated form keytool and the Play Console print.
var certFingerprint = regexp.MustCompile(`^([0-9A-F]{2}:){31}[0-9A-F]{2}$`)

// WithAndroidCertFingerprints sets the SHA-256 fingerprints of the
// certificates the Android app is signed with, comma-separated. With at
// least one, /.well-known/assetlinks.json lets Android open rhythmo links
// in the app instead of the browser. Malformed entries are dropped.
func (p *PublicPages) WithAndroidCertFingerprints(list string) *PublicPages {
	p.androidCerts = nil
	for _, raw := range strings.Split(list, ",") {
		fp := strings.ToUpper(strings.TrimSpace(raw))
		if certFingerprint.MatchString(fp) {
			p.androidCerts = append(p.androidCerts, fp)
		}
	}
	return p
}

type assetLink struct {
	Relation []string        `json:"relation"`
	Target   assetLinkTarget `json:"target"`
}

type assetLinkTarget struct {
	Namespace    string   `json:"namespace"`
	PackageName  string   `json:"package_name"`
	Fingerprints []string `json:"sha256_cert_fingerprints"`
}

// handleAssetLinks serves the Digital Asset Links statement Android
// verifies before it opens https links of this site in the app.
func (p *PublicPages) handleAssetLinks(w http.ResponseWriter, r *http.Request) {
	if len(p.androidCerts) == 0 {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "public, max-age=3600")
	_ = json.NewEncoder(w).Encode([]assetLink{{
		Relation: []string{"delegate_permission/common.handle_all_urls"},
		Target: assetLinkTarget{
			Namespace:    "android_app",
			PackageName:  androidPackage,
			Fingerprints: p.androidCerts,
		},
	}})
}
