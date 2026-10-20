package httpapi

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"image"
	"image/color"
	_ "image/gif"
	"image/jpeg"
	_ "image/png"
	"io"
	"net/http"
	"sync"
	"time"

	"github.com/mhdolatabadi/rhythmo/server/internal/store"
	"github.com/mhdolatabadi/rhythmo/server/internal/tags"
	"golang.org/x/sync/singleflight"
)

type artworkObjects interface {
	ReadRange(context.Context, string, int64, int64) ([]byte, error)
}

type artworkRangeReader struct {
	ctx     context.Context
	objects artworkObjects
	key     string
	size    int64
	offset  int64
	page    []byte
}

func (r *artworkRangeReader) ReadAt(p []byte, offset int64) (int, error) {
	if offset < 0 || offset >= r.size {
		return 0, io.EOF
	}
	if offset >= r.offset && offset+int64(len(p)) <= r.offset+int64(len(r.page)) {
		return copy(p, r.page[offset-r.offset:]), nil
	}
	data, err := r.objects.ReadRange(r.ctx, r.key, offset, min(r.size-offset, max(int64(len(p)), 64<<10)))
	if err != nil {
		return 0, err
	}
	r.offset, r.page = offset, data
	n := copy(p, data)
	if n < len(p) {
		return n, io.EOF
	}
	return n, nil
}

type artworkCache struct {
	mu     sync.Mutex
	values map[string][]byte
	order  []string
	bytes  int
	group  singleflight.Group
	slots  chan struct{}
}

var trackArtwork = artworkCache{values: make(map[string][]byte), slots: make(chan struct{}, 2)}

// Existing uploads are read on first use; no re-upload or audio rewrite.
func (c *artworkCache) load(ctx context.Context, objects artworkObjects, track store.Track) ([]byte, error) {
	key := track.StorageKey
	c.mu.Lock()
	cached, ok := c.values[key]
	c.mu.Unlock()
	if ok {
		return cached, nil
	}
	result := c.group.DoChan(key, func() (any, error) {
		select {
		case c.slots <- struct{}{}:
			defer func() { <-c.slots }()
		case <-ctx.Done():
			return nil, ctx.Err()
		}
		reader := &artworkRangeReader{ctx: ctx, objects: objects, key: key, size: track.SizeBytes}
		picture, err := tags.Cover(reader, track.SizeBytes)
		if errors.Is(err, tags.ErrMalformed) || errors.Is(err, tags.ErrUnsupported) {
			err, picture = nil, nil
		}
		if err != nil {
			return nil, err
		}
		thumbnail := artworkThumbnail(picture)
		c.mu.Lock()
		defer c.mu.Unlock()
		if previous, exists := c.values[key]; exists {
			return previous, nil
		}
		for len(c.order) > 0 && (len(c.order) >= 256 || c.bytes+len(thumbnail) > 16<<20) {
			old := c.order[0]
			c.order = c.order[1:]
			c.bytes -= len(c.values[old])
			delete(c.values, old)
		}
		c.values[key] = thumbnail
		c.order = append(c.order, key)
		c.bytes += len(thumbnail)
		return thumbnail, nil
	})
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case v := <-result:
		if v.Err != nil {
			return nil, v.Err
		}
		return v.Val.([]byte), nil
	}
}

// Reject image bombs before allocating pixels; re-encode inert thumbnails.
func artworkThumbnail(data []byte) []byte {
	if len(data) == 0 || len(data) > 16<<20 {
		return nil
	}
	config, _, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil || config.Width < 1 || config.Height < 1 ||
		int64(config.Width)*int64(config.Height) > 16<<20 {
		return nil
	}
	src, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return nil
	}
	width, height := config.Width, config.Height
	if max(width, height) > 512 {
		width = max(1, width*512/max(config.Width, config.Height))
		height = max(1, height*512/max(config.Width, config.Height))
	}
	dst := image.NewRGBA(image.Rect(0, 0, width, height))
	bounds := src.Bounds()
	for y := range height {
		for x := range width {
			r, g, b, a := src.At(bounds.Min.X+x*config.Width/width, bounds.Min.Y+y*config.Height/height).RGBA()
			background := uint32(24) * (65535 - a) / 255
			dst.SetRGBA(x, y, color.RGBA{uint8((r + background) >> 8), uint8((g + background) >> 8), uint8((b + background) >> 8), 255})
		}
	}
	var out bytes.Buffer
	if jpeg.Encode(&out, dst, &jpeg.Options{Quality: 88}) != nil {
		return nil
	}
	return out.Bytes()
}

// Authorization is checked by every caller before cache access.
func serveTrackArtwork(w http.ResponseWriter, r *http.Request, objects any, track store.Track) {
	w.Header().Set("Cache-Control", "private, max-age=300")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	source, ok := objects.(artworkObjects)
	if !ok {
		writeError(w, http.StatusServiceUnavailable, "artwork_unavailable")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()
	picture, err := trackArtwork.load(ctx, source, track)
	if err != nil {
		w.Header().Set("Cache-Control", "no-store")
		writeError(w, http.StatusServiceUnavailable, "artwork_unavailable")
		return
	}
	if len(picture) == 0 {
		writeError(w, http.StatusNotFound, "no_artwork")
		return
	}
	sum := sha256.Sum256(picture)
	etag := "\"" + hex.EncodeToString(sum[:16]) + "\""
	w.Header().Set("ETag", etag)
	if r.Header.Get("If-None-Match") == etag {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	w.Header().Set("Content-Type", "image/jpeg")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(picture)
}

func (h *TrackHandlers) handleArtwork(w http.ResponseWriter, r *http.Request) {
	track, ok := h.readyTrack(w, r)
	if ok {
		serveTrackArtwork(w, r, h.storage, track)
	}
}
