package audioinfo

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func probeFile(t *testing.T, name string, prefix []byte) Info {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatal(err)
	}
	data = append(prefix, data...)
	info, err := Probe(bytes.NewReader(data), int64(len(data)), name)
	if err != nil {
		t.Fatalf("%s: %v", name, err)
	}
	return info
}

func near(got, want time.Duration) bool {
	d := got - want
	return d > -80*time.Millisecond && d < 80*time.Millisecond
}

func TestProbe(t *testing.T) {
	// A large ID3v2 tag, as a cover makes it, before the first frame.
	cover := append([]byte{'I', 'D', '3', 3, 0, 0, 0, 0x08, 0, 0}, make([]byte, 0x08<<14)...)
	for _, c := range []struct {
		file     string
		prefix   []byte
		codec    string
		rate     int
		depth    int
		kbpsLow  int
		kbpsHigh int
		duration time.Duration
	}{
		{"cbr.mp3", nil, "MP3", 44100, 0, 128, 128, 2037 * time.Millisecond},
		{"cbr.mp3", cover, "MP3", 44100, 0, 128, 128, 2037 * time.Millisecond},
		{"vbr.mp3", nil, "MP3", 44100, 0, 25, 45, 2037 * time.Millisecond},
		{"song.flac", nil, "FLAC", 44100, 16, 100, 170, 2 * time.Second},
		{"song.wav", nil, "WAV", 48000, 24, 1152, 1152, 250 * time.Millisecond},
		{"song.opus", nil, "Opus", 48000, 0, 50, 90, 2 * time.Second},
		{"song.ogg", nil, "Vorbis", 44100, 0, 25, 50, 2 * time.Second},
		{"song.m4a", nil, "AAC", 44100, 0, 80, 120, 2 * time.Second},
	} {
		info := probeFile(t, c.file, c.prefix)
		if info.Codec != c.codec || info.SampleRate != c.rate || info.BitDepth != c.depth ||
			info.BitrateKbps < c.kbpsLow || info.BitrateKbps > c.kbpsHigh || !near(info.Duration, c.duration) {
			t.Errorf("%s (prefix %d): %+v", c.file, len(c.prefix), info)
		}
	}
}

func TestProbeRejectsGarbage(t *testing.T) {
	for _, name := range []string{"x.mp3", "x.flac", "x.wav", "x.ogg", "x.m4a", "x.txt"} {
		junk := bytes.Repeat([]byte{0x12}, 4096)
		if _, err := Probe(bytes.NewReader(junk), int64(len(junk)), name); err == nil {
			t.Errorf("%s: garbage accepted", name)
		}
	}
	if _, err := Probe(bytes.NewReader(nil), 0, "empty.mp3"); err == nil {
		t.Error("empty file accepted")
	}
}
