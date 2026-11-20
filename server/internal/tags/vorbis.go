package tags

import (
	"encoding/base64"
	"encoding/binary"
	"strings"
)

// vorbisComment is the KEY=value tag block used by FLAC, Ogg Vorbis and Opus.
type vorbisComment struct {
	vendor string
	fields []string
}

// managedVorbisKeys are replaced on rewrite, including common aliases so no
// stale copy of an edited field survives.
var managedVorbisKeys = map[string]bool{
	"TITLE": true, "ARTIST": true, "ALBUM": true, "ALBUMARTIST": true, "ALBUM ARTIST": true,
	"COMPOSER": true, "GENRE": true, "DATE": true, "YEAR": true, "TRACKNUMBER": true,
	"DISCNUMBER": true, "COMMENT": true, "DESCRIPTION": true,
}

// parseVorbisComment parses a comment block and returns the bytes after it.
func parseVorbisComment(b []byte) (vorbisComment, []byte, error) {
	read := func() (string, bool) {
		if len(b) < 4 {
			return "", false
		}
		n := binary.LittleEndian.Uint32(b)
		if uint64(n) > uint64(len(b)-4) {
			return "", false
		}
		s := string(b[4 : 4+n])
		b = b[4+n:]
		return s, true
	}
	vendor, ok := read()
	if !ok || len(b) < 4 {
		return vorbisComment{}, nil, malformed("bad Vorbis comment vendor")
	}
	count := binary.LittleEndian.Uint32(b)
	b = b[4:]
	if uint64(count) > uint64(len(b)/4) {
		return vorbisComment{}, nil, malformed("bad Vorbis comment count")
	}
	vc := vorbisComment{vendor: vendor, fields: make([]string, 0, count)}
	for range count {
		field, ok := read()
		if !ok {
			return vorbisComment{}, nil, malformed("truncated Vorbis comment")
		}
		vc.fields = append(vc.fields, field)
	}
	return vc, b, nil
}

func (vc vorbisComment) bytes() []byte {
	out := binary.LittleEndian.AppendUint32(nil, uint32(len(vc.vendor)))
	out = append(out, vc.vendor...)
	out = binary.LittleEndian.AppendUint32(out, uint32(len(vc.fields)))
	for _, field := range vc.fields {
		out = binary.LittleEndian.AppendUint32(out, uint32(len(field)))
		out = append(out, field...)
	}
	return out
}

func vorbisKey(field string) string {
	key, _, _ := strings.Cut(field, "=")
	return strings.ToUpper(key)
}

func (vc vorbisComment) with(m Metadata) vorbisComment {
	out := vorbisComment{vendor: vc.vendor}
	add := func(key, value string) {
		if value != "" {
			out.fields = append(out.fields, key+"="+value)
		}
	}
	add("TITLE", m.Title)
	add("ARTIST", m.Artist)
	add("ALBUM", m.Album)
	add("ALBUMARTIST", m.AlbumArtist)
	add("COMPOSER", m.Composer)
	add("GENRE", m.Genre)
	add("DATE", yearText(m.Year))
	add("TRACKNUMBER", numberText(m.TrackNumber))
	add("DISCNUMBER", numberText(m.DiscNumber))
	add("COMMENT", m.Comment)
	for _, field := range vc.fields {
		if !managedVorbisKeys[vorbisKey(field)] {
			out.fields = append(out.fields, field)
		}
	}
	return out
}

// withCover drops every embedded picture and adds cover as the front one.
func (vc vorbisComment) withCover(cover []byte) vorbisComment {
	out := vorbisComment{vendor: vc.vendor}
	for _, field := range vc.fields {
		switch vorbisKey(field) {
		case "METADATA_BLOCK_PICTURE", "COVERART", "COVERARTMIME":
			continue
		}
		out.fields = append(out.fields, field)
	}
	out.fields = append(out.fields,
		"METADATA_BLOCK_PICTURE="+base64.StdEncoding.EncodeToString(flacPictureData(cover)))
	return out
}

func (vc vorbisComment) metadata() Metadata {
	values := map[string]string{}
	for _, field := range vc.fields {
		key := vorbisKey(field)
		if _, seen := values[key]; !seen {
			_, value, _ := strings.Cut(field, "=")
			values[key] = value
		}
	}
	first := func(keys ...string) string {
		for _, key := range keys {
			if value := values[key]; value != "" {
				return value
			}
		}
		return ""
	}
	return Metadata{
		Title:       values["TITLE"],
		Artist:      values["ARTIST"],
		Album:       values["ALBUM"],
		AlbumArtist: first("ALBUMARTIST", "ALBUM ARTIST"),
		Composer:    values["COMPOSER"],
		Genre:       values["GENRE"],
		Comment:     first("COMMENT", "DESCRIPTION"),
		Year:        leadingNumber(first("DATE", "YEAR"), 4),
		TrackNumber: leadingNumber(values["TRACKNUMBER"], 4),
		DiscNumber:  leadingNumber(values["DISCNUMBER"], 4),
	}
}
