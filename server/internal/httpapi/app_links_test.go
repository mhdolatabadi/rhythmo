package httpapi

import (
	"encoding/json"
	"net/http"
	"testing"
)

const testCert = "AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89"

func TestAssetLinksVouchForTheAndroidApp(t *testing.T) {
	pages := NewPublicPages(&sharingStore{}, fixedPresigner{}, AnonymousLimits{}).
		WithAndroidCertFingerprints(" " + "ab:cd:ef:01:23:45:67:89:ab:cd:ef:01:23:45:67:89:ab:cd:ef:01:23:45:67:89:ab:cd:ef:01:23:45:67:89" + ", not-a-fingerprint,")
	res := get(NewHandler(Config{Public: pages}), "/.well-known/assetlinks.json")
	if res.Code != http.StatusOK || res.Header().Get("Content-Type") != "application/json" {
		t.Fatalf("status %d, type %q", res.Code, res.Header().Get("Content-Type"))
	}
	var links []assetLink
	if err := json.Unmarshal(res.Body.Bytes(), &links); err != nil {
		t.Fatal(err)
	}
	if len(links) != 1 || links[0].Target.PackageName != "ir.mhdolatabadi.nafir" ||
		links[0].Relation[0] != "delegate_permission/common.handle_all_urls" ||
		len(links[0].Target.Fingerprints) != 1 || links[0].Target.Fingerprints[0] != testCert {
		t.Fatalf("unexpected statement %+v", links)
	}
}

func TestAssetLinksMissingWithoutAFingerprint(t *testing.T) {
	pages := NewPublicPages(&sharingStore{}, fixedPresigner{}, AnonymousLimits{}).WithAndroidCertFingerprints("12:34")
	if res := get(NewHandler(Config{Public: pages}), "/.well-known/assetlinks.json"); res.Code != http.StatusNotFound {
		t.Fatalf("status %d, want 404", res.Code)
	}
}
