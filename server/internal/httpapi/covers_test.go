package httpapi

import (
	"bytes"
	"context"
	"image"
	"image/jpeg"
	"image/png"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/mhdolatabadi/rhythmo/server/internal/auth"
	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

// coverTracks adds chosen covers to the in-memory track store.
type coverTracks struct {
	*memoryTracks
	covers map[string][]byte
}

func (c *coverTracks) SetTrackCover(ctx context.Context, ownerID, trackID string, version int64, image []byte, status store.TagStatus) (store.Track, error) {
	track, err := c.UpdateMetadata(ctx, ownerID, trackID, version, store.TrackMetadata{TagStatus: status})
	if err != nil {
		return track, err
	}
	c.covers[trackID] = image
	return track, nil
}

func (c *coverTracks) TrackCover(_ context.Context, trackID string) ([]byte, error) {
	return c.covers[trackID], nil
}

func TestSetTrackCover(t *testing.T) {
	tracks := &coverTracks{memoryTracks: &memoryTracks{tracks: []store.Track{
		{ID: "cv1", OwnerID: "alice", Status: store.TrackReady, Title: "Song", FileName: "song.mp3", StorageKey: "covers-test/cv1", ContentType: "audio/mpeg", MetadataVersion: 1, TagStatus: store.TagOriginal},
		{ID: "cv2", OwnerID: "alice", Status: store.TrackReady, Title: "M4A", FileName: "song.m4a", StorageKey: "covers-test/cv2", ContentType: "audio/mp4", MetadataVersion: 1, TagStatus: store.TagOriginal},
	}}, covers: map[string][]byte{}}
	tokens, err := auth.NewTokens([]byte(strings.Repeat("k", auth.MinSecretBytes)), time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	alice, _, _ := tokens.Issue("alice")
	bob, _, _ := tokens.Issue("bob")
	notifier := &countingNotifier{}
	objects := &fakeObjects{objects: map[string][]byte{"covers-test/cv1": []byte("no art"), "covers-test/cv2": []byte("no art")}}
	handler := NewHandler(Config{Tracks: NewTrackHandlers(tracks, objects, tokens, UploadLimits{}).WithTagRewrites(notifier)})
	t.Cleanup(func() { chosenCovers.Store(nil) })

	var picture bytes.Buffer
	if err := png.Encode(&picture, image.NewGray(image.Rect(0, 0, 1000, 500))); err != nil {
		t.Fatal(err)
	}
	put := func(id, token, version string, body []byte) *httptest.ResponseRecorder {
		request := httptest.NewRequest(http.MethodPut, "/api/v1/tracks/"+id+"/cover", bytes.NewReader(body))
		request.Header.Set("Authorization", "Bearer "+token)
		if version != "" {
			request.Header.Set("If-Match", version)
		}
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		return response
	}
	get := func(path, token string) *httptest.ResponseRecorder {
		request := httptest.NewRequest(http.MethodGet, path, nil)
		request.Header.Set("Authorization", "Bearer "+token)
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		return response
	}

	if code := get("/api/v1/tracks/cv1/artwork", alice).Code; code != http.StatusNotFound {
		t.Fatalf("artwork before a cover: %d", code)
	}
	expectError(t, put("cv1", alice, "", picture.Bytes()), http.StatusPreconditionRequired, "version_required")
	expectError(t, put("cv1", alice, "1", []byte("<svg/>")), http.StatusBadRequest, "invalid_image")
	expectError(t, put("cv1", alice, "1", make([]byte, maxCoverUploadBytes+1)), http.StatusRequestEntityTooLarge, "cover_too_large")
	if code := put("cv1", bob, "1", picture.Bytes()).Code; code != http.StatusNotFound {
		t.Fatalf("another owner: %d", code)
	}

	response := put("cv1", alice, "1", picture.Bytes())
	if response.Code != http.StatusOK {
		t.Fatalf("set cover: %d %s", response.Code, response.Body.String())
	}
	updated := decode[trackResponse](t, response)
	if updated.Version != 2 || updated.EmbeddedTags.Status != store.TagPending || notifier.calls != 1 {
		t.Fatalf("cover edit: version %d, %+v, %d notifications", updated.Version, updated.EmbeddedTags, notifier.calls)
	}
	stored := tracks.covers["cv1"]
	config, err := jpeg.DecodeConfig(bytes.NewReader(stored))
	if err != nil || config.Width != 512 || config.Height != 256 {
		t.Fatalf("stored cover %+v, %v; want a 512 px JPEG", config, err)
	}
	artwork := get("/api/v1/tracks/cv1/artwork", alice)
	if artwork.Code != http.StatusOK || !bytes.Equal(artwork.Body.Bytes(), stored) {
		t.Fatalf("artwork after a cover: %d", artwork.Code)
	}
	if code := get("/api/v1/tracks/cv1/artwork", bob).Code; code != http.StatusNotFound {
		t.Fatalf("another owner's artwork: %d", code)
	}

	// A stale version is a conflict, not an overwrite.
	if code := put("cv1", alice, "1", picture.Bytes()).Code; code != http.StatusConflict {
		t.Fatalf("stale version: %d", code)
	}
	// Formats without a tag writer still show the cover; nothing is queued.
	m4a := decode[trackResponse](t, put("cv2", alice, "1", picture.Bytes()))
	if m4a.EmbeddedTags.Status != store.TagUnsupported || notifier.calls != 1 {
		t.Fatalf("m4a cover: %+v, %d notifications", m4a.EmbeddedTags, notifier.calls)
	}
}
