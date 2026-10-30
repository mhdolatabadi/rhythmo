package linkimport

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestPublicBaleFlightData(t *testing.T) {
	payload := `a:["$","component",null,{"peer":{"type":2,"id":1538049842},"messages":[{"rid":"-623376230265534491","date":1792673112764,"message":{"documentMessage":{"name":"lecture.mp3","mimeType":"audio/mpeg","fileSize":37903990,"caption":{"text":"🎙 #سخنرانی_کامل\n📋 عنوان؛ جلسه اول"}}}}]}]`
	// Next.js can split a JSON object between independent script chunks.
	a, _ := json.Marshal([]any{1, payload[:90]})
	b, _ := json.Marshal([]any{1, payload[90:]})
	page, err := readBalePage(strings.NewReader(`<html><script>self.__next_f.push(` + string(a) + `)</script><script>self.__next_f.push(` + string(b) + `)</script></html>`))
	if err != nil || page.Peer.ID != 1538049842 || len(page.Messages) != 1 || page.Messages[0].RID != "-623376230265534491" {
		t.Fatalf("page %+v, %v", page, err)
	}
	if !strings.Contains(page.Messages[0].Message.Document.Caption.Text, "📋") {
		t.Fatal("lost unicode caption")
	}
	for _, body := range []string{"<html>login required</html>", `<script>self.__next_f.push([1,"broken"])</script>`, strings.Repeat("x", maxPageBytes+1)} {
		if _, err := readBalePage(strings.NewReader(body)); err == nil {
			t.Fatal("changed/oversize page accepted")
		}
	}
}
func TestBaleGatewayAllowlist(t *testing.T) {
	for _, tc := range []struct {
		u  string
		ok bool
	}{
		{"https://file-gw6.ble.ir/proxy_download/abc?u=xyz", true},
		{"http://file-gw6.ble.ir/proxy_download/abc", false},
		{"https://file-gw6.ble.ir.evil.test/proxy_download/abc", false},
		{"https://localhost/proxy_download/abc", false},
		{"https://file-gw6.ble.ir:8443/proxy_download/abc", false},
		{"https://user@file-gw6.ble.ir/proxy_download/abc", false},
	} {
		if got := BaleMediaURL(tc.u); got != tc.ok {
			t.Errorf("%s => %v", tc.u, got)
		}
	}
}
