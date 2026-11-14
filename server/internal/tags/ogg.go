package tags

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"errors"
	"io"
)

// oggFormat rewrites the comment header packet of a single Ogg Vorbis or Opus
// stream. The header packets are paged again and every later page of the
// stream is copied with only its sequence number (and so its checksum)
// changed; audio packets and granule positions are untouched.
type oggFormat struct{}

const (
	oggHeaderBytes  = 27
	oggContinued    = 0x01
	oggBOS          = 0x02
	oggMaxSegments  = 255
	oggNoPacketEnds = ^uint64(0)
)

type oggPage struct {
	flags    byte
	granule  uint64
	serial   uint32
	sequence uint32
	segments []byte
	data     []byte
}

// oggHeaders is what precedes the audio in a stream.
type oggHeaders struct {
	first    *oggPage // the identification header, kept byte for byte
	serial   uint32
	opus     bool
	comment  vorbisComment
	trailing []byte // what follows the comment in its packet (Vorbis framing bit)
	setup    []byte // the Vorbis setup header packet
	pages    int    // pages the headers used, the first one included
}

func (oggFormat) inspect(r io.Reader) (Info, error) {
	br := bufio.NewReader(r)
	headers, err := readOggHeaders(br)
	if err != nil {
		return Info{}, err
	}
	p := newPayload()
	if err := copyOggAudio(io.Discard, p, br, headers.serial, 0); err != nil {
		return Info{}, err
	}
	return p.info(headers.comment.metadata()), nil
}

func (oggFormat) rewrite(dst io.Writer, src io.Reader, m Metadata, cover []byte) (Info, error) {
	br := bufio.NewReader(src)
	headers, err := readOggHeaders(br)
	if err != nil {
		return Info{}, err
	}
	comment := headers.comment.with(m)
	if cover != nil {
		comment = comment.withCover(cover)
	}
	var packet []byte
	if headers.opus {
		packet = append([]byte("OpusTags"), comment.bytes()...)
	} else {
		packet = append([]byte("\x03vorbis"), comment.bytes()...)
	}
	packet = append(packet, headers.trailing...)
	packets := [][]byte{packet}
	if !headers.opus {
		packets = append(packets, headers.setup)
	}
	if _, err := dst.Write(headers.first.bytes()); err != nil {
		return Info{}, err
	}
	pages := paginate(packets, headers.serial, 1)
	for _, page := range pages {
		if _, err := dst.Write(page.bytes()); err != nil {
			return Info{}, err
		}
	}
	shift := int64(len(pages)+1) - int64(headers.pages)
	p := newPayload()
	if err := copyOggAudio(dst, p, br, headers.serial, shift); err != nil {
		return Info{}, err
	}
	return p.info(comment.metadata()), nil
}

func readOggHeaders(br *bufio.Reader) (oggHeaders, error) {
	first, err := readOggPage(br)
	if errors.Is(err, io.EOF) {
		return oggHeaders{}, malformed("empty Ogg file")
	}
	if err != nil {
		return oggHeaders{}, err
	}
	if first.flags&oggBOS == 0 || len(first.segments) == 0 || first.segments[len(first.segments)-1] == 255 {
		return oggHeaders{}, malformed("bad first Ogg page")
	}
	headers := oggHeaders{first: first, serial: first.serial, pages: 1}
	var want int
	switch {
	case bytes.HasPrefix(first.data, []byte("OpusHead")):
		headers.opus, want = true, 1
	case bytes.HasPrefix(first.data, []byte("\x01vorbis")):
		want = 2
	default:
		return oggHeaders{}, ErrUnsupported
	}
	if len(first.segments) != 1+len(first.data)/255 {
		return oggHeaders{}, ErrUnsupported // more than the identification packet
	}

	var packets [][]byte
	var current []byte
	size := 0
	for len(packets) < want {
		page, err := readOggPage(br)
		if errors.Is(err, io.EOF) {
			return oggHeaders{}, malformed("truncated Ogg headers")
		}
		if err != nil {
			return oggHeaders{}, err
		}
		if page.serial != headers.serial || page.flags&oggBOS != 0 {
			return oggHeaders{}, ErrUnsupported // multiplexed streams
		}
		headers.pages++
		offset := 0
		for _, lace := range page.segments {
			if len(packets) == want {
				return oggHeaders{}, ErrUnsupported // audio shares a header page
			}
			current = append(current, page.data[offset:offset+int(lace)]...)
			offset += int(lace)
			if size += int(lace); size > maxTagBytes {
				return oggHeaders{}, malformed("Ogg headers too large")
			}
			if lace < 255 {
				packets = append(packets, current)
				current = nil
			}
		}
	}
	if current != nil {
		return oggHeaders{}, ErrUnsupported
	}

	comment := packets[0]
	var magic string
	if headers.opus {
		magic = "OpusTags"
	} else {
		magic = "\x03vorbis"
		headers.setup = packets[1]
		if !bytes.HasPrefix(headers.setup, []byte("\x05vorbis")) {
			return oggHeaders{}, malformed("missing Vorbis setup header")
		}
	}
	if !bytes.HasPrefix(comment, []byte(magic)) {
		return oggHeaders{}, malformed("missing Ogg comment header")
	}
	vc, rest, err := parseVorbisComment(comment[len(magic):])
	if err != nil {
		return oggHeaders{}, err
	}
	headers.comment, headers.trailing = vc, rest
	return headers, nil
}

// copyOggAudio copies the remaining pages, moving the stream's sequence
// numbers by shift, and fingerprints their segment tables and data.
func copyOggAudio(dst io.Writer, fingerprint io.Writer, br *bufio.Reader, serial uint32, shift int64) error {
	for {
		page, err := readOggPage(br)
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return err
		}
		if page.serial == serial && shift != 0 {
			page.sequence = uint32(int64(page.sequence) + shift)
		}
		if _, err := fingerprint.Write(page.segments); err != nil {
			return err
		}
		if _, err := fingerprint.Write(page.data); err != nil {
			return err
		}
		if _, err := dst.Write(page.bytes()); err != nil {
			return err
		}
	}
}

// paginate lays packets out on pages, starting at sequence number sequence.
// Every page that ends a packet has granule position 0, as header pages do.
func paginate(packets [][]byte, serial uint32, sequence uint32) []*oggPage {
	var pages []*oggPage
	page := &oggPage{serial: serial, sequence: sequence, granule: oggNoPacketEnds}
	flush := func(continued bool) {
		pages = append(pages, page)
		sequence++
		page = &oggPage{serial: serial, sequence: sequence, granule: oggNoPacketEnds}
		if continued {
			page.flags = oggContinued
		}
	}
	for _, packet := range packets {
		rest := packet
		for {
			if len(page.segments) == oggMaxSegments {
				flush(true)
			}
			n := min(len(rest), 255)
			page.segments = append(page.segments, byte(n))
			page.data = append(page.data, rest[:n]...)
			rest = rest[n:]
			if n < 255 {
				page.granule = 0
				break
			}
		}
		if len(page.segments) == oggMaxSegments {
			flush(false)
		}
	}
	if len(page.segments) > 0 {
		pages = append(pages, page)
	}
	return pages
}

func readOggPage(br *bufio.Reader) (*oggPage, error) {
	header := make([]byte, oggHeaderBytes)
	if _, err := io.ReadFull(br, header); err != nil {
		if errors.Is(err, io.EOF) {
			return nil, io.EOF
		}
		return nil, malformed("truncated Ogg page")
	}
	if string(header[:4]) != "OggS" || header[4] != 0 {
		return nil, malformed("bad Ogg page header")
	}
	page := &oggPage{
		flags:    header[5],
		granule:  binary.LittleEndian.Uint64(header[6:14]),
		serial:   binary.LittleEndian.Uint32(header[14:18]),
		sequence: binary.LittleEndian.Uint32(header[18:22]),
		segments: make([]byte, header[26]),
	}
	if _, err := io.ReadFull(br, page.segments); err != nil {
		return nil, malformed("truncated Ogg page")
	}
	size := 0
	for _, lace := range page.segments {
		size += int(lace)
	}
	page.data = make([]byte, size)
	if _, err := io.ReadFull(br, page.data); err != nil {
		return nil, malformed("truncated Ogg page")
	}
	if got, want := oggCRC(page.bytesWithoutCRC()), binary.LittleEndian.Uint32(header[22:26]); got != want {
		return nil, malformed("Ogg page checksum mismatch")
	}
	return page, nil
}

func (p *oggPage) bytesWithoutCRC() []byte {
	out := make([]byte, oggHeaderBytes, oggHeaderBytes+len(p.segments)+len(p.data))
	copy(out, "OggS")
	out[5] = p.flags
	binary.LittleEndian.PutUint64(out[6:14], p.granule)
	binary.LittleEndian.PutUint32(out[14:18], p.serial)
	binary.LittleEndian.PutUint32(out[18:22], p.sequence)
	out[26] = byte(len(p.segments))
	out = append(out, p.segments...)
	return append(out, p.data...)
}

func (p *oggPage) bytes() []byte {
	out := p.bytesWithoutCRC()
	binary.LittleEndian.PutUint32(out[22:26], oggCRC(out))
	return out
}

var oggCRCTable = func() [256]uint32 {
	var table [256]uint32
	for i := range table {
		crc := uint32(i) << 24
		for range 8 {
			if crc&0x80000000 != 0 {
				crc = crc<<1 ^ 0x04C11DB7
			} else {
				crc <<= 1
			}
		}
		table[i] = crc
	}
	return table
}()

// oggCRC is the CRC-32 Ogg uses: polynomial 0x04C11DB7, no reflection, zero
// initial value and no final XOR.
func oggCRC(b []byte) uint32 {
	var crc uint32
	for _, c := range b {
		crc = crc<<8 ^ oggCRCTable[byte(crc>>24)^c]
	}
	return crc
}
