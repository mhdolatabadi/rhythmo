package transcription

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

type fakeObjects struct{ opened bool }

func (o *fakeObjects) Open(context.Context, string) (io.ReadCloser, error) {
	o.opened = true
	return io.NopCloser(strings.NewReader("audio")), nil
}
func TestExtract(t *testing.T) {
	for _, tc := range []struct {
		name, body string
		status     int
		ok         bool
	}{
		{"Persian timed text", `{"plain":"یا حسین","synced":"[00:01.00]یا حسین"}`, 200, true},
		{"long Persian lecture text", `{"plain":"` + strings.Repeat("ا", 40000) + `"}`, 200, true},
		{"empty", `{"plain":""}`, 200, false},
		{"invalid JSON", `oops`, 200, false},
		{"service error", `{}`, 503, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Header.Get("Authorization") != "Bearer "+strings.Repeat("x", 32) {
					t.Error("missing private token")
				}
				audio, _ := io.ReadAll(r.Body)
				if string(audio) != "audio" {
					t.Error("wrong audio")
				}
				w.WriteHeader(tc.status)
				io.WriteString(w, tc.body)
			}))
			defer server.Close()
			worker, err := New(nil, &fakeObjects{}, server.URL, strings.Repeat("x", 32))
			if err != nil {
				t.Fatal(err)
			}
			result, err := worker.extract(context.Background(), Job{Size: 5})
			if (err == nil) != tc.ok {
				t.Fatalf("result=%+v err=%v", result, err)
			}
			if tc.ok && result.State != "done" {
				t.Fatal(result)
			}
		})
	}
}
func TestRejectOversizedBeforeReading(t *testing.T) {
	objects := &fakeObjects{}
	worker, _ := New(nil, objects, "http://internal:8090", strings.Repeat("x", 32))
	if _, err := worker.extract(context.Background(), Job{Size: MaxFileBytes + 1}); err == nil || objects.opened {
		t.Fatal("oversized object opened")
	}
}
