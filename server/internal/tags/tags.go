// Package tags reads and rewrites the metadata embedded in audio files
// without touching the audio itself: the encoded audio bytes are streamed
// through unchanged, so nothing is transcoded.
//
// MP3 (ID3v2.3 and ID3v2.4), FLAC (Vorbis comments) and Ogg Vorbis and Opus
// (Vorbis comments) are supported. Other formats report every field as
// unsupported rather than pretending to store them. Embedded data the app
// does not edit, such as cover art, ReplayGain and custom fields, is kept.
package tags

import (
	"bufio"
	"crypto/sha256"
	"errors"
	"fmt"
	"hash"
	"io"
	"path"
	"strconv"
	"strings"
)

// Metadata is the embedded metadata the app edits. An empty string or zero
// number means the tag is absent, and writing it removes the tag.
type Metadata struct {
	Title       string
	Artist      string
	Album       string
	AlbumArtist string
	Composer    string
	Genre       string
	Comment     string
	Year        int
	TrackNumber int
	DiscNumber  int
}

// Fields are the editable embedded fields, named as in the API.
var Fields = []string{
	"title", "artist", "album", "albumArtist", "composer", "genre",
	"year", "trackNumber", "discNumber", "comment",
}

var (
	// ErrUnsupported means the file's format or layout has no safe writer,
	// for example an Ogg file that carries Speex or several streams.
	ErrUnsupported = errors.New("embedded tags are not supported for this file")
	// ErrMalformed means the file is not a well-formed file of its format.
	ErrMalformed = errors.New("malformed audio file")
)

// maxTagBytes bounds how much tag data is held in memory, cover art included.
const maxTagBytes = 16 << 20

type format interface {
	inspect(r io.Reader) (Info, error)
	rewrite(dst io.Writer, src io.Reader, m Metadata) (Info, error)
}

var formats = map[string]format{
	".mp3":  mp3Format{},
	".flac": flacFormat{},
	".ogg":  oggFormat{},
	".opus": oggFormat{},
}

// Supported reports whether files named like fileName can have their tags
// written. A supported extension can still turn out to hold an unsupported
// layout, which Rewrite reports as ErrUnsupported.
func Supported(fileName string) bool {
	_, ok := formats[strings.ToLower(path.Ext(fileName))]
	return ok
}

// UnsupportedFields lists the editable fields that cannot be embedded in
// files named like fileName.
func UnsupportedFields(fileName string) []string {
	if Supported(fileName) {
		return []string{}
	}
	return append([]string(nil), Fields...)
}

// Info describes a file: its embedded metadata and a fingerprint of the
// encoded audio, which a rewrite must leave unchanged.
type Info struct {
	Metadata      Metadata
	PayloadSHA256 [sha256.Size]byte
	PayloadBytes  int64
}

// ReadMetadata reads only the leading tag headers, without scanning or
// fingerprinting the audio payload. Upload completion must stay inexpensive.
func ReadMetadata(r io.Reader, fileName string) (Metadata, error) {
	br := bufio.NewReader(r)
	switch strings.ToLower(path.Ext(fileName)) {
	case ".mp3":
		tag, err := readID3(br)
		if err != nil {
			return Metadata{}, err
		}
		return tag.metadata(), nil
	case ".flac":
		blocks, err := readFLACMetadata(br)
		if err != nil {
			return Metadata{}, err
		}
		return flacComment(blocks).metadata(), nil
	case ".ogg", ".opus":
		headers, err := readOggHeaders(br)
		if err != nil {
			return Metadata{}, err
		}
		return headers.comment.metadata(), nil
	default:
		return Metadata{}, ErrUnsupported
	}
}

// Inspect reads the embedded metadata and fingerprints the audio of a file
// named like fileName, streaming it once.
func Inspect(r io.Reader, fileName string) (Info, error) {
	f, ok := formats[strings.ToLower(path.Ext(fileName))]
	if !ok {
		return Info{}, ErrUnsupported
	}
	return f.inspect(r)
}

// Rewrite streams src to dst with its embedded tags replaced by m and returns
// what was written. Nothing but the tags changes; the audio is copied as is.
func Rewrite(dst io.Writer, src io.Reader, fileName string, m Metadata) (Info, error) {
	f, ok := formats[strings.ToLower(path.Ext(fileName))]
	if !ok {
		return Info{}, ErrUnsupported
	}
	return f.rewrite(dst, src, m)
}

// payload hashes and counts the audio bytes copied through it.
type payload struct {
	hash  hash.Hash
	bytes int64
}

func newPayload() *payload { return &payload{hash: sha256.New()} }

func (p *payload) Write(b []byte) (int, error) {
	p.bytes += int64(len(b))
	return p.hash.Write(b)
}

func (p *payload) info(m Metadata) Info {
	info := Info{Metadata: m, PayloadBytes: p.bytes}
	copy(info.PayloadSHA256[:], p.hash.Sum(nil))
	return info
}

func malformed(format string, args ...any) error {
	return fmt.Errorf("%w: "+format, append([]any{ErrMalformed}, args...)...)
}

// leadingNumber parses the number at the start of values such as "7/12" or
// "2026-03-01", or returns 0.
func leadingNumber(value string, maxDigits int) int {
	value = strings.TrimSpace(value)
	end := 0
	for end < len(value) && end < maxDigits && value[end] >= '0' && value[end] <= '9' {
		end++
	}
	n, _ := strconv.Atoi(value[:end])
	return n
}

func numberText(n int) string {
	if n <= 0 {
		return ""
	}
	return strconv.Itoa(n)
}

func yearText(year int) string {
	if year <= 0 {
		return ""
	}
	return fmt.Sprintf("%04d", year)
}
