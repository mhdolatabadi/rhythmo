package tags

import (
	"bytes"
	"encoding/base64"
	"encoding/binary"
	"testing"
)

func coverPicture(kind uint32, image []byte) []byte {
	b := binary.BigEndian.AppendUint32(nil, kind)
	for _, value := range []string{"image/png", ""} {
		b = binary.BigEndian.AppendUint32(b, uint32(len(value)))
		b = append(b, value...)
	}
	for _, n := range []uint32{1, 1, 24, 0, uint32(len(image))} {
		b = binary.BigEndian.AppendUint32(b, n)
	}
	return append(b, image...)
}

func TestEmbeddedCoverFormats(t *testing.T) {
	picture := []byte("embedded image")
	for _, version := range []byte{3, 4} {
		t.Run(string(rune('0'+version)), func(t *testing.T) {
			back := append([]byte{0}, []byte("image/png\x00\x04\x00back")...)
			front := append([]byte{1}, []byte("image/png\x00\x03\xff\xfe\x00\x00")...)
			front = append(front, picture...)
			tag := id3Tag{major: version, frames: [][]byte{
				id3Frame(version, "APIC", back),
				id3Frame(version, "APIC", front),
			}}
			file, err := tag.bytes()
			if err != nil {
				t.Fatal(err)
			}
			got, err := Cover(bytes.NewReader(file), int64(len(file)))
			if err != nil || !bytes.Equal(got, picture) {
				t.Fatalf("cover = %q, %v", got, err)
			}
		})
	}
	flac := append([]byte("fLaC\x00\x00\x00\x22"), make([]byte, 34)...)
	block := coverPicture(3, picture)
	flac = append(flac, 0x86, byte(len(block)>>16), byte(len(block)>>8), byte(len(block)))
	flac = append(flac, block...)
	vc := vorbisComment{vendor: "test", fields: []string{
		"METADATA_BLOCK_PICTURE=" + base64.StdEncoding.EncodeToString(block),
	}}
	ogg := paginate([][]byte{[]byte("OpusHead")}, 1, 0)[0]
	ogg.flags = oggBOS
	opus := ogg.bytes()
	for _, page := range paginate([][]byte{append([]byte("OpusTags"), vc.bytes()...)}, 1, 1) {
		opus = append(opus, page.bytes()...)
	}
	box := func(kind string, body []byte) []byte {
		b := binary.BigEndian.AppendUint32(nil, uint32(8+len(body)))
		return append(append(b, kind...), body...)
	}
	m4a := box("ftyp", []byte("M4A "))
	m4a = append(m4a, box("mdat", bytes.Repeat([]byte{0}, 1024))...)
	m4a = append(m4a, box("moov", box("udta", box("meta", append(make([]byte, 4),
		box("ilst", box("covr", box("data", append(make([]byte, 8), picture...))))...))))...)
	for name, file := range map[string][]byte{"flac": flac, "opus": opus, "m4a-after-audio": m4a} {
		t.Run(name, func(t *testing.T) {
			got, err := Cover(bytes.NewReader(file), int64(len(file)))
			if err != nil || !bytes.Equal(got, picture) {
				t.Fatalf("cover = %q, %v", got, err)
			}
		})
	}
}

func TestCoverMissingMalformedAndLinked(t *testing.T) {
	for _, file := range [][]byte{nil, []byte("audio without picture")} {
		got, err := Cover(bytes.NewReader(file), int64(len(file)))
		if err != nil || len(got) != 0 {
			t.Fatalf("missing cover = %q, %v", got, err)
		}
	}
	if got, _ := apicPicture([]byte("\x00-->\x00\x03\x00https://example.com/private")); got != nil {
		t.Fatal("linked image must not be returned")
	}
	if got, _ := flacPicture([]byte{0, 0, 0, 3, 255, 255, 255, 255}); got != nil {
		t.Fatal("oversized field must not be accepted")
	}
	invalid := []byte("\x00\x00\x00\x04ftyp")
	if _, err := Cover(bytes.NewReader(invalid), int64(len(invalid))); err == nil {
		t.Fatal("invalid MP4 box accepted")
	}
}
