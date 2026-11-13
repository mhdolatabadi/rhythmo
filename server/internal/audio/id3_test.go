package audio

import "testing"

func TestID3v2Size(t *testing.T) {
	for _, c := range []struct {
		name   string
		header []byte
		want   int64
	}{
		{"tag", []byte{'I', 'D', '3', 3, 0, 0, 0, 0, 0x02, 0x01}, 10 + 257},
		{"footer", []byte{'I', 'D', '3', 4, 0, 0x10, 0, 0, 0, 0x7f}, 10 + 127 + 10},
		{"big cover", []byte{'I', 'D', '3', 3, 0, 0, 0, 0x20, 0, 0}, 10 + 0x20<<14},
		{"no tag", []byte{0xff, 0xfb, 0x90, 0x64, 0, 0, 0, 0, 0, 0}, 0},
		{"not syncsafe", []byte{'I', 'D', '3', 3, 0, 0, 0x80, 0, 0, 0}, 0},
		{"short", []byte("ID3"), 0},
	} {
		if got := ID3v2Size(c.header); got != c.want {
			t.Errorf("%s: %d, want %d", c.name, got, c.want)
		}
	}
}
