// Package balearchive imports curated, public full lectures from Bale.
package balearchive

import (
	"regexp"
	"strconv"
	"strings"
	"unicode"

	"github.com/mhdolatabadi/rhythmo/server/internal/linkimport"
)

const ProviderName = "bale_archive"

var fullTagRE = regexp.MustCompile(`#سخنرانی_کامل(?:$|[^\pL\pN_‌])`)

var sessionRE = regexp.MustCompile(`(?:[؛;،,:：\-–—]\s*|\s+)جلسه(?:\s|‌|ٔ|ی|\.)*`)
var sessionTailRE = regexp.MustCompile(`\s*[-–—:؛(（].*$`)

var digitsRE = regexp.MustCompile(`^[0-9]+$`)

func Normalize(s string) string {
	s = strings.Map(func(r rune) rune {
		switch {
		case r == 'ي' || r == 'ى':
			return 'ی'
		case r == 'ك':
			return 'ک'
		case r == '\u200c' || r == '\u200e' || r == '\u200f':
			return ' '
		case r >= '۰' && r <= '۹':
			return '0' + r - '۰'
		case r >= '٠' && r <= '٩':
			return '0' + r - '٠'
		case r >= 0x064b && r <= 0x065f || r == 0x0640:
			return -1
		}
		return r
	}, s)
	return strings.Join(strings.Fields(s), " ")
}

// FullLecture deliberately requires BOTH owner-specified markers and an
// actual audio attachment; quoted posts and video captions don't qualify.
func FullLecture(m linkimport.BaleMessage) bool {
	d := m.Message.Document
	if d == nil || !strings.HasPrefix(strings.ToLower(d.MIMEType), "audio/") {
		return false
	}
	return strings.Contains(d.Caption.Text, "🎙") && fullTagRE.MatchString(d.Caption.Text)
}

// Topic uses the caption's explicit title line, never the filename or a
// guessed category. Empty topic/zero session request human review.
func Topic(caption string) (string, int, string) {
	for _, line := range strings.Split(caption, "\n") {
		if !strings.Contains(line, "📋") {
			continue
		}
		title := Normalize(strings.Trim(strings.TrimSpace(strings.SplitN(line, "📋", 2)[1]), "* _"))
		if title == "" {
			break
		}
		if at := sessionRE.FindStringIndex(title); at != nil {
			topic := strings.TrimSpace(title[:at[0]])
			sessionText := sessionTailRE.ReplaceAllString(title[at[1]:], "")
			num := ordinal(strings.Trim(sessionText, "* _؛،.-() "))
			if num == 0 && strings.TrimSpace(title[at[0]:at[1]]) == "جلسه" {
				return title, 0, title
			}
			return topic, num, title
		}
		return title, 0, title
	}
	return "", 0, ""
}

func ordinal(s string) int {
	s = Normalize(s)
	if digitsRE.MatchString(s) {
		n, _ := strconv.Atoi(s)
		if n > 0 && n <= 10000 {
			return n
		}
		return 0
	}
	words := map[string]int{"اول": 1, "یکم": 1, "دوم": 2, "سوم": 3, "چهارم": 4, "پنجم": 5, "ششم": 6, "هفتم": 7, "هشتم": 8, "نهم": 9, "دهم": 10, "یازدهم": 11, "دوازدهم": 12, "سیزدهم": 13, "چهاردهم": 14, "پانزدهم": 15, "شانزدهم": 16, "هفدهم": 17, "هجدهم": 18, "نوزدهم": 19, "بیستم": 20, "سی ام": 30, "چهلم": 40, "پنجاهم": 50, "شصتم": 60, "هفتادم": 70, "هشتادم": 80, "نودم": 90, "صدم": 100}
	if n := words[s]; n > 0 {
		return n
	}
	tens := map[string]int{"بیست": 20, "سی": 30, "چهل": 40, "پنجاه": 50, "شصت": 60, "هفتاد": 70, "هشتاد": 80, "نود": 90, "صد": 100}
	for prefix, n := range tens {
		if rest, ok := strings.CutPrefix(s, prefix+" و "); ok {
			if k := ordinal(rest); k > 0 && k < 20 {
				return n + k
			}
		}
	}
	return 0
}

func ValidTopic(s string) bool {
	return len([]rune(s)) > 0 && len([]rune(s)) <= 180 && !strings.ContainsFunc(s, unicode.IsControl)
}
