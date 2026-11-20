package tags

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"errors"
	"io"
	"strings"
	"unicode/utf16"
	"unicode/utf8"
)

// mp3Format writes an ID3v2 tag at the start of the file. An existing
// ID3v2.3 tag stays ID3v2.3 (with UTF-16 text, which that version needs for
// Persian) so its other frames can be kept byte for byte; anything else
// becomes ID3v2.4 with UTF-8 text. A trailing ID3v1 tag is dropped because
// it can only hold stale, Latin-1 copies of the edited fields.
type mp3Format struct{}

const (
	id3HeaderBytes = 10
	id3v1Bytes     = 128
)

type id3Tag struct {
	major byte
	// frames are complete raw frames, header included, in the tag's version.
	frames [][]byte
}

// managedID3Frames are replaced on rewrite. Comments are managed only when
// their description is empty; see managedComment.
var managedID3Frames = map[string]bool{
	"TIT2": true, "TPE1": true, "TALB": true, "TPE2": true, "TCOM": true, "TCON": true,
	"TRCK": true, "TPOS": true, "TYER": true, "TDRC": true, "TDAT": true, "TIME": true,
	"TRDA": true,
}

func (mp3Format) inspect(r io.Reader) (Info, error) {
	br := bufio.NewReader(r)
	tag, err := readID3(br)
	if err != nil {
		return Info{}, err
	}
	p := newPayload()
	if err := copyMP3Audio(p, br); err != nil {
		return Info{}, err
	}
	return p.info(tag.metadata()), nil
}

func (mp3Format) rewrite(dst io.Writer, src io.Reader, m Metadata, cover []byte) (Info, error) {
	br := bufio.NewReader(src)
	old, err := readID3(br)
	if err != nil {
		return Info{}, err
	}
	tag := old.with(m)
	if cover != nil {
		tag = tag.withCover(cover)
	}
	encoded, err := tag.bytes()
	if err != nil {
		return Info{}, err
	}
	if _, err := dst.Write(encoded); err != nil {
		return Info{}, err
	}
	p := newPayload()
	if err := copyMP3Audio(io.MultiWriter(dst, p), br); err != nil {
		return Info{}, err
	}
	return p.info(tag.metadata()), nil
}

// readID3 consumes a leading ID3v2 tag, if any. Without one it returns an
// empty ID3v2.4 tag and consumes nothing.
func readID3(br *bufio.Reader) (id3Tag, error) {
	header, err := br.Peek(id3HeaderBytes)
	if err != nil && !errors.Is(err, io.EOF) && !errors.Is(err, bufio.ErrBufferFull) {
		return id3Tag{}, err
	}
	if len(header) < id3HeaderBytes || string(header[:3]) != "ID3" {
		return id3Tag{major: 4}, nil
	}
	major, flags := header[3], header[5]
	size, ok := syncsafe(header[6:10])
	if !ok || header[4] == 0xFF {
		return id3Tag{}, malformed("bad ID3v2 header")
	}
	if size > maxTagBytes {
		return id3Tag{}, malformed("ID3v2 tag of %d bytes is too large", size)
	}
	if _, err := br.Discard(id3HeaderBytes); err != nil {
		return id3Tag{}, err
	}
	body := make([]byte, size)
	if _, err := io.ReadFull(br, body); err != nil {
		return id3Tag{}, malformed("truncated ID3v2 tag")
	}
	if major == 4 && flags&0x10 != 0 { // footer
		if _, err := br.Discard(id3HeaderBytes); err != nil {
			return id3Tag{}, malformed("truncated ID3v2 footer")
		}
	}
	if major != 3 && major != 4 {
		// ID3v2.2 uses different frames; start a fresh ID3v2.4 tag.
		return id3Tag{major: 4}, nil
	}
	if major == 3 && flags&0x80 != 0 {
		body = removeUnsync(body)
	}
	if flags&0x40 != 0 { // extended header, dropped on rewrite
		if len(body) < 4 {
			return id3Tag{}, malformed("truncated ID3v2 extended header")
		}
		skip := int(binary.BigEndian.Uint32(body[:4])) + 4
		if major == 4 {
			n, ok := syncsafe(body[:4])
			if !ok {
				return id3Tag{}, malformed("bad ID3v2 extended header")
			}
			skip = n
		}
		if skip > len(body) || skip < 4 {
			return id3Tag{}, malformed("bad ID3v2 extended header size")
		}
		body = body[skip:]
	}
	tag := id3Tag{major: major}
	for len(body) >= id3HeaderBytes && body[0] != 0 {
		var n int
		if major == 3 {
			n = int(binary.BigEndian.Uint32(body[4:8]))
		} else if n, ok = syncsafe(body[4:8]); !ok {
			return id3Tag{}, malformed("bad ID3v2 frame size")
		}
		if n < 0 || id3HeaderBytes+n > len(body) {
			return id3Tag{}, malformed("ID3v2 frame overruns the tag")
		}
		tag.frames = append(tag.frames, body[:id3HeaderBytes+n])
		body = body[id3HeaderBytes+n:]
	}
	return tag, nil
}

// copyMP3Audio copies everything left except a trailing ID3v1 tag.
func copyMP3Audio(dst io.Writer, r io.Reader) error {
	held := make([]byte, 0, id3v1Bytes)
	buf := make([]byte, 64<<10)
	for {
		n, err := r.Read(buf)
		chunk := append(held, buf[:n]...)
		if keep := len(chunk) - id3v1Bytes; keep > 0 {
			if _, werr := dst.Write(chunk[:keep]); werr != nil {
				return werr
			}
			held = append(held[:0], chunk[keep:]...)
		} else {
			held = chunk
		}
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return err
		}
	}
	if len(held) == id3v1Bytes && string(held[:3]) == "TAG" {
		return nil
	}
	_, err := dst.Write(held)
	return err
}

func (t id3Tag) with(m Metadata) id3Tag {
	major := t.major
	if major != 3 {
		major = 4
	}
	out := id3Tag{major: major}
	text := func(id, value string) {
		if value != "" {
			out.frames = append(out.frames, id3Frame(major, id, encodeID3Text(major, value)))
		}
	}
	text("TIT2", m.Title)
	text("TPE1", m.Artist)
	text("TALB", m.Album)
	text("TPE2", m.AlbumArtist)
	text("TCOM", m.Composer)
	text("TCON", m.Genre)
	if major == 3 {
		text("TYER", yearText(m.Year))
	} else {
		text("TDRC", yearText(m.Year))
	}
	text("TRCK", numberText(m.TrackNumber))
	text("TPOS", numberText(m.DiscNumber))
	if m.Comment != "" {
		out.frames = append(out.frames, id3Frame(major, "COMM", encodeID3Comment(major, m.Comment)))
	}
	for _, frame := range t.frames {
		id := string(frame[:4])
		if managedID3Frames[id] || (id == "COMM" && managedComment(t.major, frame)) ||
			(id == "TXXX" && managedUserText(t.major, frame)) {
			continue
		}
		out.frames = append(out.frames, frame)
	}
	return out
}

// withCover drops every embedded picture and adds cover as the front one.
func (t id3Tag) withCover(cover []byte) id3Tag {
	out := id3Tag{major: t.major}
	for _, frame := range t.frames {
		if string(frame[:4]) != "APIC" {
			out.frames = append(out.frames, frame)
		}
	}
	// Latin-1 text, the MIME type, picture type 3 (front cover), an empty
	// description, then the image.
	body := append([]byte{0}, "image/jpeg\x00"...)
	body = append(body, 3, 0)
	body = append(body, cover...)
	out.frames = append(out.frames, id3Frame(out.major, "APIC", body))
	return out
}

func (t id3Tag) bytes() ([]byte, error) {
	size := 0
	for _, frame := range t.frames {
		size += len(frame)
	}
	if size >= 1<<28 {
		return nil, malformed("ID3v2 tag too large")
	}
	out := make([]byte, 0, id3HeaderBytes+size)
	out = append(out, 'I', 'D', '3', t.major, 0, 0)
	out = appendSyncsafe(out, size)
	for _, frame := range t.frames {
		out = append(out, frame...)
	}
	return out, nil
}

func (t id3Tag) metadata() Metadata {
	var m Metadata
	var year string
	for _, frame := range t.frames {
		id := string(frame[:4])
		body, ok := frameBody(t.major, frame)
		if !ok {
			continue
		}
		set := func(into *string) {
			if *into == "" {
				*into = decodeID3Text(body)
			}
		}
		switch id {
		case "TIT2":
			set(&m.Title)
		case "TPE1":
			set(&m.Artist)
		case "TALB":
			set(&m.Album)
		case "TPE2":
			set(&m.AlbumArtist)
		case "TCOM":
			set(&m.Composer)
		case "TCON":
			set(&m.Genre)
		case "TYER", "TDRC":
			set(&year)
		case "TRCK":
			m.TrackNumber = leadingNumber(decodeID3Text(body), 4)
		case "TPOS":
			m.DiscNumber = leadingNumber(decodeID3Text(body), 4)
		case "COMM":
			if desc, text, ok := splitComment(body); ok && desc == "" && m.Comment == "" {
				m.Comment = text
			}
		}
	}
	m.Year = leadingNumber(year, 4)
	return m
}

func id3Frame(major byte, id string, body []byte) []byte {
	frame := append([]byte(id), 0, 0, 0, 0, 0, 0)
	if major == 3 {
		binary.BigEndian.PutUint32(frame[4:8], uint32(len(body)))
	} else {
		copy(frame[4:8], appendSyncsafe(nil, len(body)))
	}
	return append(frame, body...)
}

// frameBody returns a frame's content, undoing ID3v2.4 per-frame
// unsynchronisation; compressed or encrypted frames are not readable.
func frameBody(major byte, frame []byte) ([]byte, bool) {
	flags := binary.BigEndian.Uint16(frame[8:10])
	body := frame[id3HeaderBytes:]
	if major == 3 {
		return body, flags&0x00C0 == 0
	}
	if flags&0x000C != 0 { // compression, encryption
		return nil, false
	}
	if flags&0x0002 != 0 {
		body = removeUnsync(body)
	}
	if flags&0x0001 != 0 { // data length indicator
		if len(body) < 4 {
			return nil, false
		}
		body = body[4:]
	}
	return body, true
}

func managedComment(major byte, frame []byte) bool {
	body, ok := frameBody(major, frame)
	if !ok {
		return false
	}
	desc, _, ok := splitComment(body)
	return ok && desc == ""
}

// managedUserTextNames are TXXX descriptions that other tools use for the
// fields the app edits; such frames would show stale values next to ours.
var managedUserTextNames = map[string]bool{
	"title": true, "artist": true, "album": true, "albumartist": true, "album artist": true,
	"album_artist": true, "composer": true, "genre": true, "date": true, "year": true,
	"track": true, "tracknumber": true, "disc": true, "discnumber": true, "comment": true,
	"description": true,
}

func managedUserText(major byte, frame []byte) bool {
	body, ok := frameBody(major, frame)
	if !ok || len(body) < 1 {
		return false
	}
	end, _ := terminator(body[0], body[1:])
	if end < 0 {
		return false
	}
	return managedUserTextNames[strings.ToLower(decodeText(body[0], body[1:1+end]))]
}

// splitComment splits a COMM frame body into its description and text.
func splitComment(body []byte) (string, string, bool) {
	if len(body) < 4 {
		return "", "", false
	}
	encoding, rest := body[0], body[4:]
	end, width := terminator(encoding, rest)
	if end < 0 {
		return "", "", false
	}
	desc := decodeText(encoding, rest[:end])
	text := decodeText(encoding, rest[end+width:])
	return desc, text, true
}

// terminator finds the end of the first string in b for encoding.
func terminator(encoding byte, b []byte) (int, int) {
	if encoding == 1 || encoding == 2 {
		for i := 0; i+1 < len(b); i += 2 {
			if b[i] == 0 && b[i+1] == 0 {
				return i, 2
			}
		}
		return -1, 0
	}
	return bytes.IndexByte(b, 0), 1
}

func encodeID3Text(major byte, value string) []byte {
	if major == 3 {
		return append([]byte{1}, utf16LE(value)...)
	}
	return append([]byte{3}, value...)
}

func encodeID3Comment(major byte, value string) []byte {
	if major == 3 {
		body := []byte{1, 'u', 'n', 'd', 0xFF, 0xFE, 0, 0}
		return append(body, utf16LE(value)...)
	}
	body := []byte{3, 'u', 'n', 'd', 0}
	return append(body, value...)
}

func utf16LE(value string) []byte {
	out := []byte{0xFF, 0xFE}
	for _, unit := range utf16.Encode([]rune(value)) {
		out = binary.LittleEndian.AppendUint16(out, unit)
	}
	return out
}

// decodeID3Text decodes a text frame body, taking its first value.
func decodeID3Text(body []byte) string {
	if len(body) == 0 {
		return ""
	}
	encoding, rest := body[0], body[1:]
	if end, _ := terminator(encoding, rest); end >= 0 {
		rest = rest[:end]
	}
	return decodeText(encoding, rest)
}

func decodeText(encoding byte, b []byte) string {
	switch encoding {
	case 0: // ISO-8859-1
		runes := make([]rune, len(b))
		for i, c := range b {
			runes[i] = rune(c)
		}
		return strings.TrimRight(string(runes), "\x00")
	case 1, 2:
		order := binary.ByteOrder(binary.BigEndian)
		if len(b) >= 2 && b[0] == 0xFF && b[1] == 0xFE {
			order, b = binary.LittleEndian, b[2:]
		} else if len(b) >= 2 && b[0] == 0xFE && b[1] == 0xFF {
			b = b[2:]
		}
		units := make([]uint16, 0, len(b)/2)
		for i := 0; i+1 < len(b); i += 2 {
			units = append(units, order.Uint16(b[i:]))
		}
		return strings.TrimRight(string(utf16.Decode(units)), "\x00")
	default:
		s := strings.TrimRight(string(b), "\x00")
		if !utf8.ValidString(s) {
			return strings.ToValidUTF8(s, "�")
		}
		return s
	}
}

func syncsafe(b []byte) (int, bool) {
	n := 0
	for _, c := range b {
		if c&0x80 != 0 {
			return 0, false
		}
		n = n<<7 | int(c)
	}
	return n, true
}

func appendSyncsafe(out []byte, n int) []byte {
	return append(out, byte(n>>21)&0x7F, byte(n>>14)&0x7F, byte(n>>7)&0x7F, byte(n)&0x7F)
}

// removeUnsync undoes ID3 unsynchronisation: every 0xFF 0x00 becomes 0xFF.
func removeUnsync(b []byte) []byte {
	out := make([]byte, 0, len(b))
	for i := 0; i < len(b); i++ {
		out = append(out, b[i])
		if b[i] == 0xFF && i+1 < len(b) && b[i+1] == 0 {
			i++
		}
	}
	return out
}
