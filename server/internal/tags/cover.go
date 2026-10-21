package tags

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"encoding/binary"
	"io"
	"strings"
)

// Cover reads embedded artwork without reading or changing audio samples.
// MP4 boxes are addressed directly, including moov after a large mdat.
func Cover(r io.ReaderAt, size int64) ([]byte, error) {
	if size < 4 {
		return nil, nil
	}
	header := make([]byte, min(size, 12))
	if _, err := r.ReadAt(header, 0); err != nil {
		return nil, err
	}
	br := bufio.NewReader(io.NewSectionReader(r, 0, min(size, maxTagBytes+4096)))
	switch {
	case bytes.HasPrefix(header, []byte("ID3")):
		tag, err := readID3(br)
		if err != nil {
			return nil, err
		}
		var fallback []byte
		for _, frame := range tag.frames {
			if string(frame[:4]) != "APIC" {
				continue
			}
			body, ok := frameBody(tag.major, frame)
			if !ok {
				continue
			}
			picture, front := apicPicture(body)
			if front && len(picture) > 0 {
				return picture, nil
			}
			if len(fallback) == 0 {
				fallback = picture
			}
		}
		return fallback, nil
	case string(header[:4]) == "fLaC":
		blocks, err := readFLACMetadata(br)
		if err != nil {
			return nil, err
		}
		var fallback []byte
		for _, block := range blocks {
			if block.kind != 6 {
				continue
			}
			picture, front := flacPicture(block.data)
			if front && len(picture) > 0 {
				return picture, nil
			}
			if len(fallback) == 0 {
				fallback = picture
			}
		}
		return fallback, nil
	case string(header[:4]) == "OggS":
		// Only the first two packets are needed. Audio can share a page
		// with the comment, unlike the stricter tag rewrite path.
		var packet []byte
		for packets, pages := 0, 0; packets < 2 && pages < 512; pages++ {
			page, err := readOggPage(br)
			if err != nil {
				return nil, err
			}
			offset := 0
			for _, lace := range page.segments {
				packet = append(packet, page.data[offset:offset+int(lace)]...)
				offset += int(lace)
				if len(packet) > maxTagBytes {
					return nil, malformed("cover comment too large")
				}
				if lace == 255 {
					continue
				}
				packets++
				for _, prefix := range []string{"OpusTags", "\x03vorbis"} {
					if bytes.HasPrefix(packet, []byte(prefix)) {
						vc, _, err := parseVorbisComment(packet[len(prefix):])
						if err != nil {
							return nil, err
						}
						return commentPicture(vc), nil
					}
				}
				packet = nil
				if packets >= 2 {
					return nil, nil
				}
			}
		}
	case len(header) >= 8 && string(header[4:8]) == "ftyp":
		budget := maxTagBytes
		boxes := 512
		return mp4Cover(r, 0, size, 0, &budget, &boxes, false)
	}
	return nil, nil
}

func apicPicture(body []byte) ([]byte, bool) {
	if len(body) < 4 {
		return nil, false
	}
	encoding := body[0]
	end := bytes.IndexByte(body[1:], 0)
	if end < 0 || end+2 >= len(body) {
		return nil, false
	}
	// Linked pictures are URLs, never fetched.
	if string(body[1:1+end]) == "-->" {
		return nil, false
	}
	kind := body[end+2]
	desc := body[end+3:]
	skip := -1
	if encoding == 1 || encoding == 2 {
		for i := 0; i+1 < len(desc); i += 2 {
			if desc[i] == 0 && desc[i+1] == 0 {
				skip = i + 2
				break
			}
		}
	} else if i := bytes.IndexByte(desc, 0); i >= 0 {
		skip = i + 1
	}
	if skip < 0 {
		return nil, false
	}
	return desc[skip:], kind == 3
}

func flacPicture(b []byte) ([]byte, bool) {
	if len(b) < 4 {
		return nil, false
	}
	front := binary.BigEndian.Uint32(b) == 3
	b = b[4:]
	// MIME and description are length-prefixed.
	for range 2 {
		if len(b) < 4 {
			return nil, false
		}
		n := uint64(binary.BigEndian.Uint32(b))
		if n > uint64(len(b)-4) {
			return nil, false
		}
		b = b[4+int(n):]
	}
	// Width, height, depth, palette size, then the picture length.
	if len(b) < 20 {
		return nil, false
	}
	n := uint64(binary.BigEndian.Uint32(b[16:20]))
	if n > uint64(len(b)-20) || n > maxTagBytes {
		return nil, false
	}
	return b[20 : 20+int(n)], front
}

func commentPicture(vc vorbisComment) []byte {
	var fallback []byte
	for _, field := range vc.fields {
		key, value, _ := strings.Cut(field, "=")
		if !strings.EqualFold(key, "METADATA_BLOCK_PICTURE") {
			continue
		}
		decoded, err := base64.StdEncoding.DecodeString(value)
		if err != nil {
			continue
		}
		picture, front := flacPicture(decoded)
		if front && len(picture) > 0 {
			return picture
		}
		if len(fallback) == 0 {
			fallback = picture
		}
	}
	return fallback
}

func mp4Cover(r io.ReaderAt, start, end int64, depth int, budget, boxes *int, inCover bool) ([]byte, error) {
	if depth > 8 {
		return nil, malformed("MP4 cover nesting too deep")
	}
	for offset := start; offset+8 <= end; {
		*boxes--
		if *boxes < 0 {
			return nil, malformed("too many MP4 boxes")
		}
		var h [16]byte
		if _, err := r.ReadAt(h[:8], offset); err != nil {
			return nil, err
		}
		n := int64(binary.BigEndian.Uint32(h[:4]))
		header := int64(8)
		if n == 1 {
			if _, err := r.ReadAt(h[8:], offset+8); err != nil {
				return nil, err
			}
			large := binary.BigEndian.Uint64(h[8:])
			if large > uint64(end-offset) {
				return nil, malformed("MP4 box overruns file")
			}
			n, header = int64(large), 16
		} else if n == 0 {
			n = end - offset
		}
		if n < header || n > end-offset {
			return nil, malformed("invalid MP4 box size")
		}
		kind := string(h[4:8])
		if kind == "data" && inCover {
			length := n - header - 8 // full-box type and locale
			if length <= 0 || length > int64(*budget) {
				return nil, malformed("MP4 cover too large")
			}
			*budget -= int(length)
			data := make([]byte, int(length))
			_, err := r.ReadAt(data, offset+header+8)
			return data, err
		}
		switch kind {
		case "moov", "udta", "meta", "ilst", "covr":
			child := offset + header
			if kind == "meta" {
				child += 4 // full-box version and flags
			}
			picture, err := mp4Cover(r, child, offset+n, depth+1, budget, boxes, kind == "covr")
			if err != nil || len(picture) > 0 {
				return picture, err
			}
		}
		offset += n
	}
	return nil, nil
}
