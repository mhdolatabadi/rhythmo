// Package audioinfo reads a stored file's format: codec, bitrate, sample
// rate, bit depth and length, so the app can show the quality a listener
// hears (#383). It reads only headers and, for Ogg, the last page; the file
// is never changed.
package audioinfo

import (
	"bytes"
	"encoding/binary"
	"errors"
	"io"
	"path"
	"strings"
	"time"
)

// ErrUnknown means the file's format details could not be read.
var ErrUnknown = errors.New("audio format not recognised")

// Info is what a listener may want to know about a file's quality. Zero
// values are unknown.
type Info struct {
	Codec       string
	BitrateKbps int
	SampleRate  int
	BitDepth    int
	Duration    time.Duration
}

// Probe reads the format of the size-byte file r, named fileName.
func Probe(r io.ReaderAt, size int64, fileName string) (Info, error) {
	var (
		info Info
		err  error
	)
	switch strings.ToLower(path.Ext(fileName)) {
	case ".mp3":
		info, err = probeMP3(r, size)
	case ".flac":
		info, err = probeFLAC(r, size)
	case ".wav":
		info, err = probeWAV(r, size)
	case ".ogg", ".opus":
		info, err = probeOgg(r, size)
	case ".m4a":
		info, err = probeMP4(r, size)
	case ".aac":
		info, err = probeADTS(r)
	case ".webm":
		info = Info{Codec: "WebM"}
	default:
		return Info{}, ErrUnknown
	}
	if err != nil {
		return Info{}, err
	}
	if info.BitrateKbps == 0 && info.Duration > 0 {
		info.BitrateKbps = int(float64(size) * 8 / info.Duration.Seconds() / 1000)
	}
	return info, nil
}

func readAt(r io.ReaderAt, offset int64, n int) ([]byte, error) {
	buf := make([]byte, n)
	got, err := r.ReadAt(buf, offset)
	if got == 0 && err != nil {
		return nil, ErrUnknown
	}
	return buf[:got], nil
}

func seconds(samples, rate int64) time.Duration {
	if rate <= 0 || samples <= 0 {
		return 0
	}
	return time.Duration(float64(samples) / float64(rate) * float64(time.Second))
}

// ---- MP3 ----

var mp3Bitrates = [2][3][16]int{
	{ // MPEG-1: layer I, II, III
		{0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448},
		{0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384},
		{0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320},
	},
	{ // MPEG-2 and 2.5
		{0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256},
		{0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160},
		{0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160},
	},
}

var mp3Rates = [3]int{44100, 48000, 32000}

type mp3Frame struct {
	mpeg1         bool
	layer         int // 1, 2 or 3
	bitrate, rate int
	mono          bool
}

func parseMP3Frame(h []byte) (mp3Frame, bool) {
	if len(h) < 4 || h[0] != 0xff || h[1]&0xe0 != 0xe0 {
		return mp3Frame{}, false
	}
	version := h[1] >> 3 & 3 // 0: 2.5, 2: 2, 3: 1
	layerBits := h[1] >> 1 & 3
	bitrateIndex := h[2] >> 4
	rateIndex := h[2] >> 2 & 3
	if version == 1 || layerBits == 0 || bitrateIndex == 0 || bitrateIndex == 15 || rateIndex == 3 {
		return mp3Frame{}, false
	}
	f := mp3Frame{mpeg1: version == 3, layer: 4 - int(layerBits), mono: h[3]>>6 == 3}
	table := 1
	if f.mpeg1 {
		table = 0
	}
	f.bitrate = mp3Bitrates[table][f.layer-1][bitrateIndex]
	f.rate = mp3Rates[rateIndex]
	switch version {
	case 2:
		f.rate /= 2
	case 0:
		f.rate /= 4
	}
	return f, true
}

func (f mp3Frame) samples() int64 {
	switch {
	case f.layer == 1:
		return 384
	case f.layer == 3 && !f.mpeg1:
		return 576
	}
	return 1152
}

func probeMP3(r io.ReaderAt, size int64) (Info, error) {
	start := int64(0)
	for range 4 { // a file may carry more than one ID3v2 tag
		h, err := readAt(r, start, 10)
		if err != nil || len(h) < 10 || string(h[:3]) != "ID3" {
			break
		}
		n := int64(h[6]&0x7f)<<21 | int64(h[7]&0x7f)<<14 | int64(h[8]&0x7f)<<7 | int64(h[9]&0x7f)
		start += 10 + n
		if h[5]&0x10 != 0 {
			start += 10
		}
	}
	buf, err := readAt(r, start, 64<<10)
	if err != nil {
		return Info{}, err
	}
	for i := 0; i+4 <= len(buf); i++ {
		f, ok := parseMP3Frame(buf[i:])
		if !ok {
			continue
		}
		info := Info{Codec: "MP3", SampleRate: f.rate, BitrateKbps: f.bitrate}
		audioBytes := size - start - int64(i)
		if tail, _ := readAt(r, size-128, 3); string(tail) == "TAG" {
			audioBytes -= 128
		}
		if frames := vbrFrames(buf[i:], f); frames > 0 {
			info.Duration = seconds(frames*f.samples(), int64(f.rate))
			if info.Duration > 0 {
				info.BitrateKbps = int(float64(audioBytes) * 8 / info.Duration.Seconds() / 1000)
			}
		} else if f.bitrate > 0 {
			info.Duration = time.Duration(float64(audioBytes) * 8 / float64(f.bitrate*1000) * float64(time.Second))
		}
		return info, nil
	}
	return Info{}, ErrUnknown
}

// vbrFrames is the frame count in a Xing/Info or VBRI header, or 0.
func vbrFrames(frame []byte, f mp3Frame) int64 {
	side := 17
	switch {
	case f.mpeg1 && !f.mono:
		side = 32
	case !f.mpeg1 && f.mono:
		side = 9
	}
	if at := 4 + side; len(frame) >= at+12 {
		tag := string(frame[at : at+4])
		if (tag == "Xing" || tag == "Info") && binary.BigEndian.Uint32(frame[at+4:])&1 != 0 {
			return int64(binary.BigEndian.Uint32(frame[at+8:]))
		}
	}
	if at := 4 + 32; len(frame) >= at+18 && string(frame[at:at+4]) == "VBRI" {
		return int64(binary.BigEndian.Uint32(frame[at+14:]))
	}
	return 0
}

// ---- FLAC ----

func probeFLAC(r io.ReaderAt, size int64) (Info, error) {
	h, err := readAt(r, 0, 42)
	if err != nil || len(h) < 42 || string(h[:4]) != "fLaC" || h[4]&0x7f != 0 {
		return Info{}, ErrUnknown
	}
	si := h[8:]
	rate := int(si[10])<<12 | int(si[11])<<4 | int(si[12])>>4
	depth := int(si[12]&1)<<4 | int(si[13])>>4 + 1
	total := int64(si[13]&0x0f)<<32 | int64(binary.BigEndian.Uint32(si[14:]))
	return Info{Codec: "FLAC", SampleRate: rate, BitDepth: depth, Duration: seconds(total, int64(rate))}, nil
}

// ---- WAV ----

func probeWAV(r io.ReaderAt, size int64) (Info, error) {
	h, err := readAt(r, 0, 12)
	if err != nil || len(h) < 12 || string(h[:4]) != "RIFF" || string(h[8:12]) != "WAVE" {
		return Info{}, ErrUnknown
	}
	info := Info{Codec: "WAV"}
	byteRate := 0
	for at, n := int64(12), 0; at+8 <= size && n < 64; n++ {
		c, err := readAt(r, at, 8)
		if err != nil || len(c) < 8 {
			break
		}
		length := int64(binary.LittleEndian.Uint32(c[4:]))
		switch string(c[:4]) {
		case "fmt ":
			f, err := readAt(r, at+8, 16)
			if err != nil || len(f) < 16 {
				return Info{}, ErrUnknown
			}
			info.SampleRate = int(binary.LittleEndian.Uint32(f[4:]))
			byteRate = int(binary.LittleEndian.Uint32(f[8:]))
			info.BitDepth = int(binary.LittleEndian.Uint16(f[14:]))
			info.BitrateKbps = byteRate * 8 / 1000
		case "data":
			if byteRate > 0 {
				info.Duration = seconds(min(length, size-at-8), int64(byteRate))
			}
			return info, nil
		}
		at += 8 + length + length%2
	}
	if info.SampleRate == 0 {
		return Info{}, ErrUnknown
	}
	return info, nil
}

// ---- Ogg Vorbis and Opus ----

func probeOgg(r io.ReaderAt, size int64) (Info, error) {
	h, err := readAt(r, 0, 512)
	if err != nil || len(h) < 28 || string(h[:4]) != "OggS" {
		return Info{}, ErrUnknown
	}
	packet := h[27+int(h[26]):]
	var info Info
	var granuleRate, preSkip int64
	switch {
	case len(packet) >= 28 && string(packet[:7]) == "\x01vorbis":
		info.Codec = "Vorbis"
		info.SampleRate = int(binary.LittleEndian.Uint32(packet[12:]))
		granuleRate = int64(info.SampleRate)
	case len(packet) >= 19 && string(packet[:8]) == "OpusHead":
		info.Codec = "Opus"
		info.SampleRate = 48000
		granuleRate = 48000
		preSkip = int64(binary.LittleEndian.Uint16(packet[10:]))
	default:
		return Info{}, ErrUnknown
	}
	tailAt := max(0, size-64<<10)
	tail, err := readAt(r, tailAt, int(size-tailAt))
	if err == nil {
		if i := bytes.LastIndex(tail, []byte("OggS")); i >= 0 && len(tail) >= i+14 {
			granule := int64(binary.LittleEndian.Uint64(tail[i+6:]))
			info.Duration = seconds(granule-preSkip, granuleRate)
		}
	}
	return info, nil
}

// ---- MP4 / M4A ----

func probeMP4(r io.ReaderAt, size int64) (Info, error) {
	for at := int64(0); at+8 <= size; {
		h, err := readAt(r, at, 16)
		if err != nil || len(h) < 8 {
			break
		}
		length := int64(binary.BigEndian.Uint32(h))
		if length == 1 && len(h) >= 16 {
			length = int64(binary.BigEndian.Uint64(h[8:]))
		} else if length == 0 {
			length = size - at
		}
		if length < 8 {
			break
		}
		if string(h[4:8]) == "moov" {
			if length > 8<<20 {
				return Info{Codec: "AAC"}, nil
			}
			moov, err := readAt(r, at, int(length))
			if err != nil {
				return Info{}, err
			}
			return parseMoov(moov), nil
		}
		at += length
	}
	return Info{}, ErrUnknown
}

func parseMoov(moov []byte) Info {
	info := Info{Codec: "AAC"}
	if bytes.Contains(moov, []byte("alac")) {
		info.Codec = "ALAC"
	}
	// mdhd: the first track's own clock is its sample rate for audio.
	if i := bytes.Index(moov, []byte("mdhd")); i >= 0 {
		box := moov[i+4:]
		var scale, length int64
		switch {
		case len(box) >= 24 && box[0] == 0:
			scale = int64(binary.BigEndian.Uint32(box[12:]))
			length = int64(binary.BigEndian.Uint32(box[16:]))
		case len(box) >= 36 && box[0] == 1:
			scale = int64(binary.BigEndian.Uint32(box[20:]))
			length = int64(binary.BigEndian.Uint64(box[24:]))
		}
		info.SampleRate = int(scale)
		info.Duration = seconds(length, scale)
	}
	return info
}

// ---- ADTS AAC ----

var adtsRates = []int{96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350}

func probeADTS(r io.ReaderAt) (Info, error) {
	h, err := readAt(r, 0, 7)
	if err != nil || len(h) < 7 || h[0] != 0xff || h[1]&0xf6 != 0xf0 {
		return Info{}, ErrUnknown
	}
	info := Info{Codec: "AAC"}
	if i := int(h[2] >> 2 & 0x0f); i < len(adtsRates) {
		info.SampleRate = adtsRates[i]
	}
	return info, nil
}
