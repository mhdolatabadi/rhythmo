// Package moderation catches clearly unacceptable words in text that is
// about to be listed publicly (#207). It is a coarse first filter: a hit is
// rejected at once, and everything else still goes to an admin.
package moderation

import (
	_ "embed"
	"strings"
	"unicode"
	"unicode/utf8"
)

//go:embed words_fa.txt
var persianWords string

//go:embed words_en.txt
var englishWords string

type list struct {
	// whole match only as an entire word; part also inside one.
	whole map[string]bool
	part  []string
}

var words = load(persianWords + "\n" + englishWords)

func load(text string) list {
	l := list{whole: map[string]bool{}}
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if word, ok := strings.CutPrefix(line, "="); ok {
			l.whole[normalizeWord(word)] = true
			continue
		}
		l.part = append(l.part, normalizeWord(line))
	}
	return l
}

// Check returns the first unacceptable word found in any of texts, as it
// was matched (normalized), and whether there was one.
func Check(texts ...string) (string, bool) {
	for _, text := range texts {
		for _, token := range tokens(text) {
			if words.whole[token] {
				return token, true
			}
			for _, part := range words.part {
				if strings.Contains(token, part) {
					return part, true
				}
			}
		}
	}
	return "", false
}

// tokens splits text into normalized words. Letters spelled out one by one
// ("f u c k", "ک ی ر") are joined back into one word.
func tokens(text string) []string {
	var out []string
	var spelled strings.Builder
	flush := func() {
		if spelled.Len() > 0 {
			out = append(out, collapse(spelled.String()))
			spelled.Reset()
		}
	}
	for _, field := range strings.FieldsFunc(text, isSeparator) {
		word := normalizeWord(field)
		if word == "" {
			continue
		}
		if utf8.RuneCountInString(word) == 1 {
			spelled.WriteString(word)
			continue
		}
		flush()
		out = append(out, word)
	}
	flush()
	return out
}

func isSeparator(r rune) bool {
	return unicode.IsSpace(r) || r == '/' || r == '|' || r == ',' || r == '،' || r == '(' || r == ')' ||
		r == '[' || r == ']' || r == '«' || r == '»' || r == '"' || r == '!' || r == '?' || r == '؟' || r == ':'
}

var leet = map[rune]rune{'0': 'o', '1': 'i', '3': 'e', '4': 'a', '5': 's', '7': 't', '@': 'a', '$': 's'}

// normalizeWord folds one word to the form the lists are kept in: lower
// case, Persian letters for their Arabic look-alikes, no diacritics,
// joiners or inserted punctuation, common digit-for-letter swaps undone and
// repeated letters collapsed.
func normalizeWord(word string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(word) {
		switch {
		case r == 'ي' || r == 'ى':
			r = 'ی'
		case r == 'ك':
			r = 'ک'
		case r == 'ة' || r == 'ہ':
			r = 'ه'
		}
		if mapped, ok := leet[r]; ok {
			r = mapped
		}
		switch {
		case r == '‌' || r == '‍' || r == 'ـ': // ZWNJ, ZWJ, tatweel
			continue
		case unicode.Is(unicode.Mn, r): // diacritics
			continue
		case unicode.IsLetter(r):
			b.WriteRune(r)
		}
		// Dots, dashes, stars and the like inside a word are dropped.
	}
	return collapse(b.String())
}

// collapse turns runs of one letter into a single letter.
func collapse(word string) string {
	var b strings.Builder
	var last rune = -1
	for _, r := range word {
		if r != last {
			b.WriteRune(r)
		}
		last = r
	}
	return b.String()
}
