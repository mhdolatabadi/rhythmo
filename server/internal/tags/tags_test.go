package tags

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

var edited = Metadata{
	Title:       "آهنگ تازه",
	Artist:      "خواننده — Artist",
	Album:       "آلبوم",
	AlbumArtist: "Various",
	Composer:    "آهنگساز",
	Genre:       "Pop",
	Comment:     "خط اول\nLine two",
	Year:        2026,
	TrackNumber: 7,
	DiscNumber:  2,
}

func fixture(t *testing.T, name string) []byte {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func rewrite(t *testing.T, name string, data []byte, m Metadata) ([]byte, Info) {
	t.Helper()
	var out bytes.Buffer
	info, err := Rewrite(&out, bytes.NewReader(data), name, m)
	if err != nil {
		t.Fatalf("Rewrite(%s): %v", name, err)
	}
	return out.Bytes(), info
}

func TestRewriteKeepsAudioAndWritesEveryField(t *testing.T) {
	for _, name := range []string{"v24.mp3", "v23-cover-id3v1.mp3", "notag.mp3", "tagged.flac", "tagged.ogg", "tagged.opus"} {
		t.Run(name, func(t *testing.T) {
			original := fixture(t, name)
			before, err := Inspect(bytes.NewReader(original), name)
			if err != nil {
				t.Fatal(err)
			}
			out, written := rewrite(t, name, original, edited)
			if written.Metadata != edited {
				t.Fatalf("written metadata = %+v", written.Metadata)
			}
			after, err := Inspect(bytes.NewReader(out), name)
			if err != nil {
				t.Fatalf("rewritten file does not parse: %v", err)
			}
			if after.Metadata != edited {
				t.Fatalf("read back %+v, want %+v", after.Metadata, edited)
			}
			if after.PayloadSHA256 != before.PayloadSHA256 || after.PayloadBytes != before.PayloadBytes || written.PayloadSHA256 != before.PayloadSHA256 {
				t.Fatalf("audio changed: %d -> %d bytes", before.PayloadBytes, after.PayloadBytes)
			}
			if before.PayloadBytes == 0 {
				t.Fatal("no audio found")
			}
			// Rewriting is deterministic, so a retried job produces the same object.
			if again, _ := rewrite(t, name, original, edited); !bytes.Equal(again, out) {
				t.Fatal("rewrite is not deterministic")
			}
			probe := ffprobe(t, name, out)
			if probe != nil {
				for key, want := range map[string]string{
					"title": edited.Title, "artist": edited.Artist, "album": edited.Album,
					"album_artist": edited.AlbumArtist, "composer": edited.Composer, "genre": edited.Genre,
					"date": "2026", "track": "7", "disc": "2", "comment": edited.Comment,
				} {
					if got := probe.tag(key); got != want {
						t.Errorf("ffprobe %s = %q, want %q (tags %v)", key, got, want, probe.tags())
					}
				}
				decodes(t, name, out)
			}
		})
	}
}

func TestRewriteKeepsFieldsTheAppDoesNotEdit(t *testing.T) {
	cases := map[string]func(t *testing.T, out []byte, p *probeResult){
		"v24.mp3": func(t *testing.T, out []byte, p *probeResult) {
			if !bytes.Contains(out, []byte("TXXX")) || !bytes.Contains(out, []byte("keep")) {
				t.Error("custom TXXX frame lost")
			}
			if bytes.Contains(out, []byte("old comment")) || bytes.Contains(out, []byte("Old title")) {
				t.Error("stale tags survived")
			}
		},
		"v23-cover-id3v1.mp3": func(t *testing.T, out []byte, p *probeResult) {
			if !bytes.Contains(out, []byte("APIC")) || !bytes.Contains(out, []byte("\x89PNG")) {
				t.Error("cover art lost")
			}
			if out[3] != 3 {
				t.Errorf("ID3v2.3 became ID3v2.%d", out[3])
			}
			if len(out) >= id3v1Bytes && string(out[len(out)-id3v1Bytes:][:3]) == "TAG" {
				t.Error("stale ID3v1 tag kept")
			}
			if p != nil && p.attachedPictures() != 1 {
				t.Errorf("ffprobe sees %d cover images", p.attachedPictures())
			}
		},
		"tagged.flac": func(t *testing.T, out []byte, p *probeResult) {
			if !bytes.Contains(out, []byte("REPLAYGAIN_TRACK_GAIN=-3 dB")) {
				t.Error("ReplayGain lost")
			}
			if !bytes.Contains(out, []byte("\x89PNG")) {
				t.Error("FLAC picture lost")
			}
			if p != nil && p.attachedPictures() != 1 {
				t.Errorf("ffprobe sees %d cover images", p.attachedPictures())
			}
		},
		"tagged.ogg": func(t *testing.T, out []byte, p *probeResult) {
			if p != nil && p.tag("custom") != "keep me" {
				t.Errorf("custom comment lost: %v", p.tags())
			}
		},
		"tagged.opus": func(t *testing.T, out []byte, p *probeResult) {
			if p != nil && p.tag("custom") != "keep me" {
				t.Errorf("custom comment lost: %v", p.tags())
			}
		},
	}
	for name, check := range cases {
		t.Run(name, func(t *testing.T) {
			out, _ := rewrite(t, name, fixture(t, name), edited)
			check(t, out, ffprobe(t, name, out))
		})
	}
}

func TestRewriteWithEmptyFieldsRemovesTags(t *testing.T) {
	for _, name := range []string{"v24.mp3", "v23-cover-id3v1.mp3", "tagged.flac", "tagged.ogg", "tagged.opus"} {
		t.Run(name, func(t *testing.T) {
			withTags, _ := rewrite(t, name, fixture(t, name), edited)
			cleared, _ := rewrite(t, name, withTags, Metadata{Title: "Only title"})
			info, err := Inspect(bytes.NewReader(cleared), name)
			if err != nil {
				t.Fatal(err)
			}
			if info.Metadata != (Metadata{Title: "Only title"}) {
				t.Fatalf("cleared metadata = %+v", info.Metadata)
			}
			if p := ffprobe(t, name, cleared); p != nil {
				for _, key := range []string{"artist", "album", "comment", "date", "track"} {
					if got := p.tag(key); got != "" {
						t.Errorf("%s still %q", key, got)
					}
				}
				decodes(t, name, cleared)
			}
		})
	}
}

func TestOggCommentSpanningSeveralPages(t *testing.T) {
	for _, name := range []string{"tagged.ogg", "tagged.opus"} {
		t.Run(name, func(t *testing.T) {
			original := fixture(t, name)
			before, _ := Inspect(bytes.NewReader(original), name)
			// 255 segments of 255 bytes fill a page, so this needs three.
			long := Metadata{Title: "T", Comment: strings.Repeat("ک", 70_000)}
			out, _ := rewrite(t, name, original, long)
			after, err := Inspect(bytes.NewReader(out), name)
			if err != nil {
				t.Fatal(err)
			}
			if after.Metadata != long || after.PayloadSHA256 != before.PayloadSHA256 {
				t.Fatal("long comment did not survive")
			}
			sequences := oggSequences(t, out)
			for i, seq := range sequences {
				if seq != uint32(i) {
					t.Fatalf("page sequence numbers %v are not continuous", sequences)
				}
			}
			if len(sequences) < 5 {
				t.Fatalf("only %d pages", len(sequences))
			}
			if ffprobe(t, name, out) != nil {
				decodes(t, name, out)
			}
			// And back to a short comment: later pages move back again.
			short, _ := rewrite(t, name, out, edited)
			if again, err := Inspect(bytes.NewReader(short), name); err != nil || again.Metadata != edited || again.PayloadSHA256 != before.PayloadSHA256 {
				t.Fatalf("shrinking again: %+v %v", again.Metadata, err)
			}
		})
	}
}

func TestUnsupportedAndMalformedFiles(t *testing.T) {
	if Supported("song.m4a") || Supported("a.wav") || Supported("a.webm") || Supported("a.aac") {
		t.Fatal("formats without a writer must not be supported")
	}
	if !Supported("آهنگ.MP3") || !Supported("a.flac") || !Supported("a.opus") || !Supported("a.ogg") {
		t.Fatal("supported formats rejected")
	}
	if got := UnsupportedFields("song.m4a"); len(got) != len(Fields) {
		t.Fatalf("UnsupportedFields(m4a) = %v", got)
	}
	if got := UnsupportedFields("song.mp3"); got == nil || len(got) != 0 {
		t.Fatalf("UnsupportedFields(mp3) = %#v", got)
	}
	if _, err := Rewrite(&bytes.Buffer{}, bytes.NewReader(fixture(t, "sample.m4a")), "sample.m4a", edited); !errors.Is(err, ErrUnsupported) {
		t.Fatalf("m4a rewrite error = %v", err)
	}

	flac := fixture(t, "tagged.flac")
	ogg := fixture(t, "tagged.ogg")
	corrupt := append([]byte(nil), ogg...)
	corrupt[len(corrupt)-1] ^= 0xFF
	speex := (&oggPage{flags: oggBOS, serial: 1, segments: []byte{80}, data: append([]byte("Speex   "), make([]byte, 72)...)}).bytes()
	for name, tc := range map[string]struct {
		file string
		data []byte
		want error
	}{
		"not flac":           {"a.flac", []byte("OggS not a flac file"), ErrMalformed},
		"truncated flac":     {"a.flac", flac[:30], ErrMalformed},
		"flac without audio": {"a.flac", flac[:len(flac)-len(flac)+42], ErrMalformed},
		"truncated id3":      {"a.mp3", []byte("ID3\x04\x00\x00\x00\x00\x10\x00abc"), ErrMalformed},
		"bad id3 size":       {"a.mp3", []byte("ID3\x04\x00\x00\x80\x00\x00\x00"), ErrMalformed},
		"ogg checksum":       {"a.ogg", corrupt, ErrMalformed},
		"ogg speex":          {"a.ogg", speex, ErrUnsupported},
		"empty ogg":          {"a.ogg", nil, ErrMalformed},
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := Rewrite(&bytes.Buffer{}, bytes.NewReader(tc.data), tc.file, edited); !errors.Is(err, tc.want) {
				t.Fatalf("error = %v, want %v", err, tc.want)
			}
		})
	}
}

func TestOggCRCMatchesKnownPage(t *testing.T) {
	// The first page of a real file carries a checksum made by libogg.
	data := fixture(t, "tagged.opus")
	page, err := readOggPage(bufioReader(data))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(page.bytes(), data[:len(page.bytes())]) {
		t.Fatal("re-encoding an unchanged page changed it")
	}
}

func oggSequences(t *testing.T, data []byte) []uint32 {
	t.Helper()
	br := bufioReader(data)
	var sequences []uint32
	for {
		page, err := readOggPage(br)
		if err != nil {
			return sequences
		}
		sequences = append(sequences, page.sequence)
	}
}

type probeResult struct {
	Format struct {
		Tags map[string]string `json:"tags"`
	} `json:"format"`
	Streams []struct {
		CodecType   string            `json:"codec_type"`
		Tags        map[string]string `json:"tags"`
		Disposition map[string]int    `json:"disposition"`
	} `json:"streams"`
}

func (p *probeResult) tags() map[string]string {
	all := map[string]string{}
	for _, s := range p.Streams {
		if s.CodecType == "audio" {
			for k, v := range s.Tags {
				all[strings.ToLower(k)] = v
			}
		}
	}
	for k, v := range p.Format.Tags {
		all[strings.ToLower(k)] = v
	}
	return all
}

func (p *probeResult) tag(key string) string {
	return p.tags()[key]
}

func (p *probeResult) attachedPictures() int {
	n := 0
	for _, s := range p.Streams {
		if s.Disposition["attached_pic"] == 1 {
			n++
		}
	}
	return n
}

// ffprobe reads data with FFmpeg, an independent implementation, when it is
// installed; it returns nil otherwise.
func ffprobe(t *testing.T, name string, data []byte) *probeResult {
	t.Helper()
	if _, err := exec.LookPath("ffprobe"); err != nil {
		return nil
	}
	file := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(file, data, 0o600); err != nil {
		t.Fatal(err)
	}
	out, err := exec.Command("ffprobe", "-v", "error", "-show_format", "-show_streams", "-of", "json", file).Output()
	if err != nil {
		t.Fatalf("ffprobe: %v", err)
	}
	var result probeResult
	if err := json.Unmarshal(out, &result); err != nil {
		t.Fatal(err)
	}
	return &result
}

// decodes checks that FFmpeg decodes every audio packet without an error.
func decodes(t *testing.T, name string, data []byte) {
	t.Helper()
	file := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(file, data, 0o600); err != nil {
		t.Fatal(err)
	}
	out, err := exec.Command("ffmpeg", "-v", "error", "-i", file, "-map", "0:a", "-f", "null", "-").CombinedOutput()
	if err != nil || len(bytes.TrimSpace(out)) != 0 {
		t.Fatalf("ffmpeg could not decode the rewritten file: %v %s", err, out)
	}
}

func bufioReader(data []byte) *bufio.Reader {
	return bufio.NewReader(bytes.NewReader(data))
}

func TestReadMetadataMatchesInspect(t *testing.T) {
	for _, name := range []string{"v24.mp3", "v23-cover-id3v1.mp3", "notag.mp3", "tagged.flac", "tagged.ogg", "tagged.opus"} {
		t.Run(name, func(t *testing.T) {
			data := fixture(t, name)
			info, err := Inspect(bytes.NewReader(data), name)
			if err != nil {
				t.Fatal(err)
			}
			got, err := ReadMetadata(bytes.NewReader(data), name)
			if err != nil {
				t.Fatal(err)
			}
			if got != info.Metadata {
				t.Fatalf("metadata = %+v, want %+v", got, info.Metadata)
			}
		})
	}
}
