package tags

import (
	"bufio"
	"io"
)

// flacFormat replaces the VORBIS_COMMENT metadata block and keeps every other
// block (stream info, seek table, cue sheet, pictures, application data) in
// its original order. Padding is dropped since the file is rewritten anyway.
type flacFormat struct{}

const (
	flacStreamInfo    = 0
	flacPadding       = 1
	flacVorbisComment = 4
	flacPictureBlock  = 6
	flacMaxBlockBytes = 1<<24 - 1
)

type flacBlock struct {
	kind byte
	data []byte
}

func (flacFormat) inspect(r io.Reader) (Info, error) {
	br := bufio.NewReader(r)
	blocks, err := readFLACMetadata(br)
	if err != nil {
		return Info{}, err
	}
	p := newPayload()
	if err := copyFLACFrames(p, br); err != nil {
		return Info{}, err
	}
	return p.info(flacComment(blocks).metadata()), nil
}

func (flacFormat) rewrite(dst io.Writer, src io.Reader, m Metadata, cover []byte) (Info, error) {
	br := bufio.NewReader(src)
	blocks, err := readFLACMetadata(br)
	if err != nil {
		return Info{}, err
	}
	comment := flacComment(blocks).with(m)
	encoded := comment.bytes()
	if len(encoded) > flacMaxBlockBytes {
		return Info{}, malformed("FLAC comment block too large")
	}
	out := []flacBlock{blocks[0], {kind: flacVorbisComment, data: encoded}}
	for _, block := range blocks[1:] {
		if block.kind == flacPadding || block.kind == flacVorbisComment ||
			(cover != nil && block.kind == flacPictureBlock) {
			continue
		}
		out = append(out, block)
	}
	if cover != nil {
		out = append(out, flacBlock{kind: flacPictureBlock, data: flacPictureData(cover)})
	}
	header := []byte("fLaC")
	for i, block := range out {
		kind := block.kind
		if i == len(out)-1 {
			kind |= 0x80
		}
		n := len(block.data)
		header = append(header, kind, byte(n>>16), byte(n>>8), byte(n))
		header = append(header, block.data...)
	}
	if _, err := dst.Write(header); err != nil {
		return Info{}, err
	}
	p := newPayload()
	if err := copyFLACFrames(io.MultiWriter(dst, p), br); err != nil {
		return Info{}, err
	}
	return p.info(comment.metadata()), nil
}

func readFLACMetadata(br *bufio.Reader) ([]flacBlock, error) {
	magic := make([]byte, 4)
	if _, err := io.ReadFull(br, magic); err != nil || string(magic) != "fLaC" {
		return nil, malformed("missing fLaC marker")
	}
	var blocks []flacBlock
	total := 0
	for {
		header := make([]byte, 4)
		if _, err := io.ReadFull(br, header); err != nil {
			return nil, malformed("truncated FLAC metadata")
		}
		last, kind := header[0]&0x80 != 0, header[0]&0x7F
		n := int(header[1])<<16 | int(header[2])<<8 | int(header[3])
		if kind == 127 {
			return nil, malformed("invalid FLAC metadata block")
		}
		if total += n; total > maxTagBytes {
			return nil, malformed("FLAC metadata too large")
		}
		data := make([]byte, n)
		if _, err := io.ReadFull(br, data); err != nil {
			return nil, malformed("truncated FLAC metadata block")
		}
		if len(blocks) == 0 && (kind != flacStreamInfo || n != 34) {
			return nil, malformed("FLAC must start with STREAMINFO")
		}
		blocks = append(blocks, flacBlock{kind: kind, data: data})
		if last {
			return blocks, nil
		}
	}
}

func flacComment(blocks []flacBlock) vorbisComment {
	for _, block := range blocks {
		if block.kind == flacVorbisComment {
			if vc, _, err := parseVorbisComment(block.data); err == nil {
				return vc
			}
		}
	}
	return vorbisComment{vendor: "rhythmo"}
}

// copyFLACFrames copies the audio frames, which must start with a frame
// sync code right after the metadata.
func copyFLACFrames(dst io.Writer, br *bufio.Reader) error {
	sync, err := br.Peek(2)
	if err != nil || sync[0] != 0xFF || sync[1]&0xFE != 0xF8 {
		return malformed("FLAC audio does not start with a frame")
	}
	_, err = io.Copy(dst, br)
	return err
}
