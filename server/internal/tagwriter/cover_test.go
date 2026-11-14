package tagwriter

import (
	"bytes"
	"image"
	"image/jpeg"
	"testing"

	"github.com/mhdolatabadi/rhythmo/server/internal/store"
	"github.com/mhdolatabadi/rhythmo/server/internal/tags"
)

// A cover the owner chose is written into the file, so a download carries
// it; later edits keep it (#225).
func TestRewriteEmbedsChosenCover(t *testing.T) {
	h := newHarness(t, Config{})
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, image.NewGray(image.Rect(0, 0, 40, 40)), nil); err != nil {
		t.Fatal(err)
	}
	cover := buf.Bytes()
	for _, tc := range []struct{ fixture, name, contentType string }{
		{"v23-cover-id3v1.mp3", "song.mp3", "audio/mpeg"},
		{"tagged.flac", "song.flac", "audio/flac"},
		{"tagged.opus", "song.opus", "audio/ogg"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			track := h.upload(t, tc.fixture, tc.name, tc.contentType)
			withCover, err := h.tracks.SetTrackCover(h.ctx, h.owner, track.ID, track.MetadataVersion, cover, store.TagPending)
			if err != nil {
				t.Fatal(err)
			}
			if withCover.MetadataVersion != track.MetadataVersion+1 || withCover.TagStatus != store.TagPending {
				t.Fatalf("cover did not count as an edit: %+v", withCover)
			}
			if !h.runOnce(t) {
				t.Fatal("no rewrite was queued for the cover")
			}
			done := h.reload(t, track.ID)
			if done.TagStatus != store.TagWritten {
				t.Fatalf("tag status %s", done.TagStatus)
			}
			data, _ := h.objects.get(done.StorageKey)
			got, err := tags.Cover(bytes.NewReader(data), int64(len(data)))
			if err != nil || !bytes.Equal(got, cover) {
				t.Fatalf("downloaded file carries %d cover bytes (%v), want the chosen cover", len(got), err)
			}

			// A later title edit keeps the chosen cover.
			h.edit(t, done, "تازه")
			h.runOnce(t)
			again := h.reload(t, track.ID)
			data, _ = h.objects.get(again.StorageKey)
			if got, _ := tags.Cover(bytes.NewReader(data), int64(len(data))); !bytes.Equal(got, cover) {
				t.Fatal("a later edit lost the chosen cover")
			}
			if embedded(t, h, again).Title != "تازه" {
				t.Fatal("title not written")
			}
		})
	}
}

func TestSetTrackCoverChecksOwnerAndVersion(t *testing.T) {
	h := newHarness(t, Config{})
	track := h.upload(t, "v24.mp3", "song.mp3", "audio/mpeg")
	if _, err := h.tracks.SetTrackCover(h.ctx, h.owner, track.ID, track.MetadataVersion+5, []byte{1}, store.TagPending); err != store.ErrVersionConflict {
		t.Fatalf("stale version: %v", err)
	}
	other := "00000000-0000-0000-0000-000000000000"
	if _, err := h.tracks.SetTrackCover(h.ctx, other, track.ID, track.MetadataVersion, []byte{1}, store.TagPending); err != store.ErrNotFound {
		t.Fatalf("another owner: %v", err)
	}
	if got, err := h.tracks.TrackCover(h.ctx, track.ID); err != nil || got != nil {
		t.Fatalf("no cover yet: %v %v", got, err)
	}
	// Deleting the track removes its cover.
	if _, err := h.tracks.SetTrackCover(h.ctx, h.owner, track.ID, track.MetadataVersion, []byte{1, 2}, store.TagPending); err != nil {
		t.Fatal(err)
	}
	if err := h.tracks.Delete(h.ctx, h.owner, track.ID); err != nil {
		t.Fatal(err)
	}
	var n int
	if err := h.pool.QueryRow(h.ctx, `SELECT count(*) FROM track_covers`).Scan(&n); err != nil || n != 0 {
		t.Fatalf("covers left after delete: %d %v", n, err)
	}
}
