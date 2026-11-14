package httpapi

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/mhdolatabadi/rhythmo/server/internal/storage"
)

type memoryMedia map[string][]byte

func (m memoryMedia) Size(_ context.Context, key string) (int64, error) {
	return int64(len(m[key])), nil
}

func (m memoryMedia) Head(_ context.Context, key string, n int64) ([]byte, error) {
	return m[key][:min(int(n), len(m[key]))], nil
}

func (m memoryMedia) PresignGet(_ context.Context, key string) (string, time.Time, error) {
	return "https://storage.example/" + key, time.Now().Add(time.Hour), nil
}

type nopReaderAt struct{ *bytes.Reader }

func (nopReaderAt) Close() error { return nil }

func (m memoryMedia) OpenReaderAt(_ context.Context, key string) (storage.ReaderAtCloser, error) {
	return nopReaderAt{bytes.NewReader(m[key])}, nil
}

// id3 is an ID3v2.3 tag of n bytes in all, as a cover makes it.
func id3(n int) []byte {
	body := n - 10
	tag := []byte{'I', 'D', '3', 3, 0, 0,
		byte(body >> 21 & 0x7f), byte(body >> 14 & 0x7f), byte(body >> 7 & 0x7f), byte(body & 0x7f)}
	return append(tag, bytes.Repeat([]byte{0xAA}, body)...)
}

func TestWebStreamsSkipLargeID3Tags(t *testing.T) {
	audioBytes := bytes.Repeat([]byte{0xff, 0xfb, 0x90, 0x64, 1, 2, 3, 4}, 4096)
	objects := memoryMedia{
		"u/covered.mp3": append(id3(200<<10), audioBytes...),
		"u/small.mp3":   append(id3(2<<10), audioBytes...),
		"u/song.flac":   append(id3(200<<10), audioBytes...),
	}
	media := NewMediaStreams(objects)
	mux := http.NewServeMux()
	media.register(mux)
	handler := markWebStreams(mux)
	web := context.WithValue(context.Background(), webStreamKey{}, true)

	link, _, err := media.PresignGet(web, "u/covered.mp3")
	if err != nil || !strings.HasPrefix(link, "/api/v1/media/") {
		t.Fatalf("web link = %q, %v", link, err)
	}
	for _, c := range []struct {
		ctx  context.Context
		key  string
		name string
	}{
		{context.Background(), "u/covered.mp3", "android keeps the stored file"},
		{web, "u/small.mp3", "small tags start fast already"},
		{web, "u/song.flac", "only MP3"},
	} {
		if got, _, _ := media.PresignGet(c.ctx, c.key); !strings.HasPrefix(got, "https://storage.example/") {
			t.Errorf("%s: %q", c.name, got)
		}
	}

	get := func(path, rangeHeader string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodGet, path, nil)
		if rangeHeader != "" {
			req.Header.Set("Range", rangeHeader)
		}
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		return rec
	}
	full := get(link, "")
	if full.Code != http.StatusOK || !bytes.Equal(full.Body.Bytes(), audioBytes) {
		t.Fatalf("full = %d, %d bytes; want the audio frames byte for byte", full.Code, full.Body.Len())
	}
	if full.Header().Get("Content-Type") != "audio/mpeg" || full.Header().Get("Accept-Ranges") != "bytes" {
		t.Fatalf("headers = %v", full.Header())
	}
	part := get(link, "bytes=8-15")
	if part.Code != http.StatusPartialContent || !bytes.Equal(part.Body.Bytes(), audioBytes[8:16]) {
		t.Fatalf("range = %d %x", part.Code, part.Body.Bytes())
	}

	tampered := strings.Replace(link, "/media/e", "/media/f", 1)
	if tampered == link {
		tampered = link[:len(link)-2] + "AA"
	}
	if rec := get(tampered, ""); rec.Code != http.StatusNotFound {
		t.Fatalf("tampered link = %d", rec.Code)
	}
	media.now = func() time.Time { return time.Now().Add(mediaLinkTTL + time.Minute) }
	if rec := get(link, ""); rec.Code != http.StatusNotFound {
		t.Fatalf("expired link = %d", rec.Code)
	}
	if _, err := io.Copy(io.Discard, full.Body); err != nil {
		t.Fatal(err)
	}
}

func TestWebClientsAreMarked(t *testing.T) {
	var seen []bool
	handler := markWebStreams(http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) {
		seen = append(seen, forWeb(r.Context()))
	}))
	for _, path := range []string{"/api/v1/tracks/x/stream?client=web", "/api/v1/tracks/x/stream", "/p/token/t/x/stream"} {
		handler.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, path, nil))
	}
	if seen[0] != true || seen[1] != false || seen[2] != true {
		t.Fatalf("web = %v", seen)
	}
}
