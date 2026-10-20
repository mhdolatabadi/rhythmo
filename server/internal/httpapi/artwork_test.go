package httpapi

import (
	"bytes"
	"context"
	"encoding/binary"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

func (f *fakeObjects) ReadRange(_ context.Context, key string, offset, size int64) ([]byte, error) {
	data := f.objects[key]
	if offset >= int64(len(data)) {
		return nil, nil
	}
	return data[offset:min(int64(len(data)), offset+size)], nil
}

func artworkMP3(t *testing.T) []byte {
	t.Helper()
	picture := image.NewRGBA(image.Rect(0, 0, 800, 400))
	picture.Set(1, 1, color.White)
	var out bytes.Buffer
	if err := png.Encode(&out, picture); err != nil {
		t.Fatal(err)
	}
	body := append([]byte("\x00image/png\x00\x03\x00"), out.Bytes()...)
	frame := append([]byte("APIC"), make([]byte, 6)...)
	binary.BigEndian.PutUint32(frame[4:8], uint32(len(body)))
	frame = append(frame, body...)
	n := len(frame)
	file := []byte{'I', 'D', '3', 3, 0, 0, byte(n >> 21 & 127), byte(n >> 14 & 127), byte(n >> 7 & 127), byte(n & 127)}
	return append(file, frame...)
}

func TestArtworkAuthorizationCacheAndMissing(t *testing.T) {
	api := newTracksAPI(t, &memoryTracks{leaky: true, tracks: []store.Track{
		{ID: "cover", OwnerID: "alice", Status: store.TrackReady, StorageKey: "artwork-test/cover"},
		{ID: "none", OwnerID: "alice", Status: store.TrackReady, StorageKey: "artwork-test/none", SizeBytes: 12},
		{ID: "pending", OwnerID: "alice", Status: store.TrackPending, StorageKey: "artwork-test/cover"},
	}})
	file := artworkMP3(t)
	api.tracks.tracks[0].SizeBytes = int64(len(file))
	api.objects.objects["artwork-test/cover"] = file
	api.objects.objects["artwork-test/none"] = []byte("no cover art")
	path := "/api/v1/tracks/cover/artwork"
	if got := api.get(t, path, "").Code; got != http.StatusUnauthorized {
		t.Fatalf("anonymous status %d", got)
	}
	got := api.get(t, path, api.alice)
	if got.Code != http.StatusOK || got.Header().Get("Content-Type") != "image/jpeg" {
		t.Fatalf("cover status %d: %s", got.Code, got.Body.String())
	}
	config, err := jpeg.DecodeConfig(bytes.NewReader(got.Body.Bytes()))
	if err != nil || config.Width != 512 || config.Height != 256 {
		t.Fatalf("thumbnail dimensions = %+v, %v", config, err)
	}
	// A warmed cache must never bypass ownership.
	if code := api.get(t, path, api.bob).Code; code != http.StatusNotFound {
		t.Fatalf("other owner status %d", code)
	}
	if code := api.get(t, "/api/v1/tracks/pending/artwork", api.alice).Code; code != http.StatusNotFound {
		t.Fatalf("pending status %d", code)
	}
	if code := api.get(t, "/api/v1/tracks/none/artwork", api.alice).Code; code != http.StatusNotFound {
		t.Fatalf("no picture status %d", code)
	}
	req := httptest.NewRequest(http.MethodGet, path, nil)
	req.Header.Set("Authorization", "Bearer "+api.alice)
	req.Header.Set("If-None-Match", got.Header().Get("ETag"))
	cached := httptest.NewRecorder()
	api.handler.ServeHTTP(cached, req)
	if cached.Code != http.StatusNotModified {
		t.Fatalf("conditional status %d", cached.Code)
	}
	if !bytes.Equal(file, api.objects.objects["artwork-test/cover"]) {
		t.Fatal("original audio changed")
	}
	api.tracks.tracks = nil
	if code := api.get(t, path, api.alice).Code; code != http.StatusNotFound {
		t.Fatalf("deleted cover status %d", code)
	}
}

func TestArtworkRejectsInvalidImage(t *testing.T) {
	for _, picture := range [][]byte{[]byte("<svg>active content</svg>"), []byte("broken image")} {
		if artworkThumbnail(picture) != nil {
			t.Fatal("invalid picture was served")
		}
	}
}
