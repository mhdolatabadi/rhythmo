package audio

// ID3v2HeaderBytes is how much of a file ID3v2Size needs per tag.
const ID3v2HeaderBytes = 10

// ID3v2Size returns the length of the ID3v2 tag that starts header, footer
// included, or 0 when header does not start with a valid ID3v2 tag. The
// size is a 28-bit "syncsafe" integer in bytes 6 to 9.
func ID3v2Size(header []byte) int64 {
	if len(header) < ID3v2HeaderBytes || string(header[:3]) != "ID3" ||
		header[3] == 0xff || header[4] == 0xff {
		return 0
	}
	var size int64
	for _, b := range header[6:10] {
		if b&0x80 != 0 {
			return 0
		}
		size = size<<7 | int64(b)
	}
	size += ID3v2HeaderBytes
	if header[5]&0x10 != 0 {
		size += ID3v2HeaderBytes // footer
	}
	return size
}
