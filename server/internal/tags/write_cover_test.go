package tags

import (
	"bytes"
	"image"
	"image/color"
	"image/jpeg"
	"testing"
)

func testJPEG(t *testing.T, size int) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, size, size))
	for y := range size {
		for x := range size {
			img.Set(x, y, color.RGBA{uint8(x), uint8(y), 90, 255})
		}
	}
	var out bytes.Buffer
	if err := jpeg.Encode(&out, img, nil); err != nil {
		t.Fatal(err)
	}
	return out.Bytes()
}

// The chosen cover replaces every embedded picture, keeps the audio and the
// other tags, and is what readers and FFmpeg then find (#225).
func TestRewriteWithCoverReplacesPictures(t *testing.T) {
	// Big enough that the Ogg comment spans several pages.
	cover := testJPEG(t, 300)
	if len(cover) < 70_000 {
		cover = append(cover, make([]byte, 70_000)...) // trailing bytes after EOI are kept as is
	}
	for _, name := range []string{"v23-cover-id3v1.mp3", "v24.mp3", "notag.mp3", "tagged.flac", "tagged.ogg", "tagged.opus"} {
		t.Run(name, func(t *testing.T) {
			data := fixture(t, name)
			before, err := Inspect(bytes.NewReader(data), name)
			if err != nil {
				t.Fatal(err)
			}
			m := Metadata{Title: "کاور تازه", Artist: "هنرمند"}
			var out bytes.Buffer
			info, err := RewriteWithCover(&out, bytes.NewReader(data), name, m, cover)
			if err != nil {
				t.Fatal(err)
			}
			if info.PayloadSHA256 != before.PayloadSHA256 || info.Metadata != m {
				t.Fatal("cover rewrite changed the audio or the tags")
			}
			written := out.Bytes()
			got, err := Cover(bytes.NewReader(written), int64(len(written)))
			if err != nil || !bytes.Equal(got, cover) {
				t.Fatalf("Cover() = %d bytes, %v; want the new cover", len(got), err)
			}
			after, err := Inspect(bytes.NewReader(written), name)
			if err != nil || after.PayloadSHA256 != before.PayloadSHA256 || after.Metadata != m {
				t.Fatalf("re-reading the rewritten file: %v", err)
			}
			// Rewriting again with the same cover keeps exactly one picture.
			var again bytes.Buffer
			if _, err := RewriteWithCover(&again, bytes.NewReader(written), name, m, cover); err != nil {
				t.Fatal(err)
			}
			if probe := ffprobe(t, name, again.Bytes()); probe != nil {
				if name != "tagged.opus" && name != "tagged.ogg" && probe.attachedPictures() != 1 {
					t.Fatalf("ffprobe sees %d pictures, want 1", probe.attachedPictures())
				}
				if probe.tag("title") != m.Title {
					t.Fatalf("ffprobe title = %q", probe.tag("title"))
				}
				decodes(t, name, again.Bytes())
			}
		})
	}
}

func TestRewriteWithoutCoverKeepsPictures(t *testing.T) {
	data := fixture(t, "v23-cover-id3v1.mp3")
	original, err := Cover(bytes.NewReader(data), int64(len(data)))
	if err != nil || len(original) == 0 {
		t.Fatalf("fixture has no cover: %v", err)
	}
	written, _ := rewrite(t, "v23-cover-id3v1.mp3", data, Metadata{Title: "x"})
	got, err := Cover(bytes.NewReader(written), int64(len(written)))
	if err != nil || !bytes.Equal(got, original) {
		t.Fatal("a rewrite without a cover lost the embedded one")
	}
}

func TestRewriteWithCoverRefusesHugeCovers(t *testing.T) {
	var out bytes.Buffer
	_, err := RewriteWithCover(&out, bytes.NewReader(fixture(t, "v24.mp3")), "v24.mp3", Metadata{}, make([]byte, maxTagBytes))
	if err == nil {
		t.Fatal("a cover larger than the tag budget was accepted")
	}
}
