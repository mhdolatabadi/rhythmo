package httpapi

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"path"
	"strings"
	"time"

	"github.com/mhdolatabadi/rhythmo/server/internal/audio"
	"github.com/mhdolatabadi/rhythmo/server/internal/storage"
)

// Browsers are slow to start an MP3 whose ID3v2 tag carries a cover: they
// treat the picture as a video stream and download about a minute of audio
// before playing (#375). For web players, MediaStreams serves such files
// from the first audio frame on: the stored file stays the same and every
// audio byte is sent unchanged, only the leading tag is left out. The app
// shows titles and covers from the API, not from the stream.

// minSkippedTag is the smallest tag worth serving around. Tags without a
// picture are a few kilobytes and start fast; skipping them would only move
// traffic from storage to the API.
const minSkippedTag = 32 << 10

// mediaLinkTTL is how long a media link plays; the app asks for a fresh
// link when one stops working.
const mediaLinkTTL = 6 * time.Hour

type mediaObjects interface {
	Size(ctx context.Context, key string) (int64, error)
	Head(ctx context.Context, key string, n int64) ([]byte, error)
	PresignGet(ctx context.Context, key string) (string, time.Time, error)
	OpenReaderAt(ctx context.Context, key string) (storage.ReaderAtCloser, error)
}

// MediaStreams is a StreamPresigner: it presigns storage links, except for
// web players of MP3s with a large ID3v2 tag, which get a signed link to
// /api/v1/media that starts at the first audio frame.
type MediaStreams struct {
	objects mediaObjects
	secret  []byte
	now     func() time.Time
}

// NewMediaStreams signs links with a key made at start-up: links from
// before a restart stop working, and the app asks for fresh ones.
func NewMediaStreams(objects mediaObjects) *MediaStreams {
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		panic(err)
	}
	return &MediaStreams{objects: objects, secret: secret, now: time.Now}
}

type webStreamKey struct{}

// markWebStreams tells MediaStreams that stream links in this request are
// for a browser: the server-rendered pages, and the web app, which asks
// with ?client=web.
func markWebStreams(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("client") == "web" ||
			!(r.URL.Path == "/api" || strings.HasPrefix(r.URL.Path, "/api/")) {
			r = r.WithContext(context.WithValue(r.Context(), webStreamKey{}, true))
		}
		next.ServeHTTP(w, r)
	})
}

func forWeb(ctx context.Context) bool {
	web, _ := ctx.Value(webStreamKey{}).(bool)
	return web
}

type mediaClaims struct {
	Key     string `json:"k"`
	Offset  int64  `json:"o"`
	Size    int64  `json:"n"`
	Expires int64  `json:"e"`
}

func (m *MediaStreams) PresignGet(ctx context.Context, key string) (string, time.Time, error) {
	if !forWeb(ctx) || !strings.EqualFold(path.Ext(key), ".mp3") {
		return m.objects.PresignGet(ctx, key)
	}
	header, err := m.objects.Head(ctx, key, audio.ID3v2HeaderBytes)
	if err != nil {
		return m.objects.PresignGet(ctx, key)
	}
	offset := audio.ID3v2Size(header)
	if offset < minSkippedTag {
		return m.objects.PresignGet(ctx, key)
	}
	size, err := m.objects.Size(ctx, key)
	if err != nil || offset >= size {
		return m.objects.PresignGet(ctx, key)
	}
	expires := m.now().Add(mediaLinkTTL).Truncate(time.Second)
	claims, _ := json.Marshal(mediaClaims{Key: key, Offset: offset, Size: size, Expires: expires.Unix()})
	return "/api/v1/media/" + m.sign(claims), expires, nil
}

func (m *MediaStreams) sign(claims []byte) string {
	mac := hmac.New(sha256.New, m.secret)
	mac.Write(claims)
	return base64.RawURLEncoding.EncodeToString(claims) + "." +
		base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

func (m *MediaStreams) verify(token string) (mediaClaims, bool) {
	body, sig, ok := strings.Cut(token, ".")
	if !ok {
		return mediaClaims{}, false
	}
	claims, err1 := base64.RawURLEncoding.DecodeString(body)
	got, err2 := base64.RawURLEncoding.DecodeString(sig)
	if err1 != nil || err2 != nil {
		return mediaClaims{}, false
	}
	mac := hmac.New(sha256.New, m.secret)
	mac.Write(claims)
	if !hmac.Equal(got, mac.Sum(nil)) {
		return mediaClaims{}, false
	}
	var c mediaClaims
	if json.Unmarshal(claims, &c) != nil || c.Offset < 0 || c.Offset >= c.Size ||
		m.now().Unix() >= c.Expires {
		return mediaClaims{}, false
	}
	return c, true
}

func (m *MediaStreams) register(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/v1/media/{token}", m.handleMedia)
}

// handleMedia serves the audio after the tag, with byte ranges.
func (m *MediaStreams) handleMedia(w http.ResponseWriter, r *http.Request) {
	claims, ok := m.verify(r.PathValue("token"))
	if !ok {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	object, err := m.objects.OpenReaderAt(r.Context(), claims.Key)
	if err != nil {
		internalError(w, "open media", err)
		return
	}
	defer object.Close()
	// A song streams for minutes on a slow link, longer than the server's
	// usual write timeout.
	if err := http.NewResponseController(w).SetWriteDeadline(time.Now().Add(30 * time.Minute)); err != nil {
		slog.Debug("media write deadline", "error", err)
	}
	h := w.Header()
	h.Set("Content-Type", "audio/mpeg")
	h.Set("Cache-Control", "private, no-transform, max-age=3600")
	h.Del("Content-Security-Policy")
	http.ServeContent(w, r, "", time.Time{}, io.NewSectionReader(object, claims.Offset, claims.Size-claims.Offset))
}
