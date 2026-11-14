package lyrics

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"log/slog"
	"math"
	"strings"
	"time"
	"unicode"
)

// ErrNotCached means the cache has nothing for the track.
var ErrNotCached = errors.New("no cached lyrics")

const (
	// DefaultFoundTTL is how long found lyrics are kept before asking
	// LRCLIB again; lyrics rarely change.
	DefaultFoundTTL = 30 * 24 * time.Hour
	// DefaultMissTTL is how long "not found" is kept; LRCLIB grows, so a
	// miss is retried sooner.
	DefaultMissTTL = 24 * time.Hour
	// maxCandidates is how many alternatives the owner is offered.
	maxCandidates = 20
	// durationSlack is how far a record's length may be from the track's
	// and still be the same recording.
	durationSlack = 5 * time.Second
	// exactLookupBudget bounds LRCLIB's exact lookup, so a lookup that
	// falls back to search still finishes well inside the app's timeout.
	exactLookupBudget = 4 * time.Second
)

// Song is one track to find lyrics for.
type Song struct {
	TrackID string
	Query
}

// Entry is the cached answer for one track: found lyrics, or a cached miss.
type Entry struct {
	TrackID string
	// MatchKey is MatchKey of the title, artist and album the entry was
	// looked up for; editing any of them makes the entry stale.
	MatchKey string
	Found    bool
	// Record is the LRCLIB entry when Found.
	Record Record
	// Chosen is set when the track's owner picked Record by hand.
	Chosen    bool
	FetchedAt time.Time
	ExpiresAt time.Time
}

// Cache keeps one Entry per track; *store.Lyrics implements it.
type Cache interface {
	// Lyrics returns the track's entry, or ErrNotCached.
	Lyrics(ctx context.Context, trackID string) (Entry, error)
	// SaveLyrics replaces the track's entry. Saving for a track deleted in
	// the meantime is not an error.
	SaveLyrics(ctx context.Context, entry Entry) error
}

// Service finds lyrics for tracks, through the cache.
type Service struct {
	source   Source
	cache    Cache
	foundTTL time.Duration
	missTTL  time.Duration
	now      func() time.Time
}

// NewService caches found lyrics for foundTTL and misses for missTTL; zero
// picks the defaults.
func NewService(source Source, cache Cache, foundTTL, missTTL time.Duration) *Service {
	if foundTTL <= 0 {
		foundTTL = DefaultFoundTTL
	}
	if missTTL <= 0 {
		missTTL = DefaultMissTTL
	}
	return &Service{source: source, cache: cache, foundTTL: foundTTL, missTTL: missTTL, now: time.Now}
}

// ForSong returns the song's lyrics: from the cache while it is fresh and
// still matches the track's title, artist and album, otherwise from LRCLIB.
// A miss is an Entry with Found false. When LRCLIB can't be reached, an
// expired entry for the same metadata is still served; with none, the
// error is ErrUnavailable.
func (s *Service) ForSong(ctx context.Context, song Song) (Entry, error) {
	key := MatchKey(song.Query)
	cached, err := s.cache.Lyrics(ctx, song.TrackID)
	hasCached := err == nil && cached.MatchKey == key
	if err != nil && !errors.Is(err, ErrNotCached) {
		return Entry{}, err
	}
	if hasCached && s.now().Before(cached.ExpiresAt) {
		return cached, nil
	}

	var record Record
	if hasCached && cached.Chosen {
		// Refresh the owner's own pick rather than searching again.
		record, err = s.source.ByID(ctx, cached.Record.ID)
	} else {
		record, err = s.lookup(ctx, song.Query)
	}
	entry := Entry{TrackID: song.TrackID, MatchKey: key, FetchedAt: s.now()}
	switch {
	case err == nil:
		entry.Found, entry.Record = true, clean(record)
		entry.Chosen = hasCached && cached.Chosen
		entry.ExpiresAt = entry.FetchedAt.Add(s.foundTTL)
	case errors.Is(err, ErrNotFound):
		entry.ExpiresAt = entry.FetchedAt.Add(s.missTTL)
	default:
		if hasCached {
			slog.Warn("lyrics lookup failed, serving stale entry", "track", song.TrackID, "error", err)
			return cached, nil
		}
		return Entry{}, err
	}
	if err := s.cache.SaveLyrics(ctx, entry); err != nil {
		return Entry{}, err
	}
	return entry, nil
}

// Candidates lists LRCLIB records the owner may pick from when the match is
// wrong: a search for text when given, otherwise for the song itself.
func (s *Service) Candidates(ctx context.Context, q Query, text string) ([]Record, error) {
	search := Query{Title: q.Title, Artist: q.Artist}
	if text = strings.TrimSpace(text); text != "" {
		search = Query{Text: text}
	}
	if strings.TrimSpace(search.Title) == "" && search.Text == "" {
		return []Record{}, nil
	}
	records, err := s.source.Search(ctx, search)
	if errors.Is(err, ErrNotFound) {
		return []Record{}, nil
	}
	if err != nil {
		return nil, err
	}
	candidates := make([]Record, 0, min(len(records), maxCandidates))
	for _, r := range records {
		r = clean(r)
		if r.ID <= 0 || !r.HasLyrics() {
			continue
		}
		candidates = append(candidates, r)
		if len(candidates) == maxCandidates {
			break
		}
	}
	return candidates, nil
}

// Choose makes LRCLIB record id the song's lyrics, as its owner picked. The
// pick holds until the title, artist or album is edited.
func (s *Service) Choose(ctx context.Context, song Song, id int64) (Entry, error) {
	if id <= 0 {
		return Entry{}, ErrNotFound
	}
	record, err := s.source.ByID(ctx, id)
	if err != nil {
		return Entry{}, err
	}
	record = clean(record)
	if !record.HasLyrics() {
		return Entry{}, ErrNotFound
	}
	now := s.now()
	entry := Entry{
		TrackID: song.TrackID, MatchKey: MatchKey(song.Query), Found: true, Record: record,
		Chosen: true, FetchedAt: now, ExpiresAt: now.Add(s.foundTTL),
	}
	if err := s.cache.SaveLyrics(ctx, entry); err != nil {
		return Entry{}, err
	}
	return entry, nil
}

// lookup asks LRCLIB for the song: the exact lookup when the artist and
// length are known, then a search judged by BestMatch.
func (s *Service) lookup(ctx context.Context, q Query) (Record, error) {
	if strings.TrimSpace(q.Title) == "" {
		return Record{}, ErrNotFound
	}
	if q.Artist != "" && q.Duration > 0 {
		// LRCLIB's exact lookup can hang while it asks other providers; it
		// gets a short budget so the search below still answers in time.
		getCtx, cancel := context.WithTimeout(ctx, exactLookupBudget)
		record, err := s.source.Get(getCtx, q)
		cancel()
		switch {
		case err == nil:
			if record = clean(record); record.HasLyrics() {
				return record, nil
			}
		case errors.Is(err, ErrNotFound):
		case ctx.Err() != nil:
			return Record{}, err
		default:
			// A failed exact lookup is not a failed lookup: try the search.
			slog.Warn("exact lyrics lookup failed, searching instead", "error", err)
		}
	}
	records, err := s.source.Search(ctx, q)
	if err != nil {
		return Record{}, err
	}
	best, ok := BestMatch(q, records)
	if !ok {
		return Record{}, ErrNotFound
	}
	return best, nil
}

// BestMatch picks the record most likely to be the song: its title must
// match, and so must its artist and length when they are known. Synced
// lyrics, a matching album and a closer length win ties.
func BestMatch(q Query, records []Record) (Record, bool) {
	title, artist, album := normalize(q.Title), normalize(q.Artist), normalize(q.Album)
	var best Record
	bestScore := math.Inf(-1)
	for _, r := range records {
		r = clean(r)
		if !r.HasLyrics() || !similar(normalize(r.TrackName), title) {
			continue
		}
		if artist != "" && !similar(normalize(r.ArtistName), artist) {
			continue
		}
		score := 0.0
		if q.Duration > 0 && r.Duration > 0 {
			off := math.Abs(r.Duration - q.Duration.Seconds())
			if off > durationSlack.Seconds() {
				continue
			}
			score += 1 - off/durationSlack.Seconds()
		}
		if normalize(r.TrackName) == title {
			score += 2
		}
		if nonEmpty(r.SyncedLyrics) {
			score += 2
		}
		if album != "" && normalize(r.AlbumName) == album {
			score++
		}
		if score > bestScore {
			best, bestScore = r, score
		}
	}
	return best, !math.IsInf(bestScore, -1)
}

// MatchKey identifies the metadata lyrics were looked up for.
func MatchKey(q Query) string {
	sum := sha256.Sum256([]byte(normalize(q.Title) + "\x00" + normalize(q.Artist) + "\x00" + normalize(q.Album)))
	return hex.EncodeToString(sum[:])
}

// similar is true when one name contains the other, so "Song" matches
// "Song (Remastered)" but not "Another Song" only by sharing a word.
func similar(a, b string) bool {
	if a == "" || b == "" {
		return false
	}
	return a == b || strings.Contains(a, b) || strings.Contains(b, a)
}

// normalize folds case, punctuation, spacing, and the Arabic forms of
// Persian letters, so the same name typed differently compares equal.
func normalize(s string) string {
	s = strings.NewReplacer("ي", "ی", "ى", "ی", "ك", "ک", "ة", "ه", "‌", " ").Replace(s)
	var b strings.Builder
	space := false
	for _, r := range strings.ToLower(s) {
		if unicode.IsLetter(r) || unicode.IsNumber(r) {
			if space && b.Len() > 0 {
				b.WriteByte(' ')
			}
			b.WriteRune(r)
			space = false
		} else {
			space = true
		}
	}
	return b.String()
}

// clean drops lyrics that are too long to be a song's, and bounds the
// names, so nothing unreasonable is stored or sent to the app.
func clean(r Record) Record {
	for _, text := range []**string{&r.PlainLyrics, &r.SyncedLyrics} {
		if *text != nil && (len(**text) > MaxLyricsBytes || strings.TrimSpace(**text) == "") {
			*text = nil
		}
	}
	for _, name := range []*string{&r.TrackName, &r.ArtistName, &r.AlbumName} {
		*name = truncate(strings.TrimSpace(*name), maxFieldLength)
	}
	if r.Duration < 0 || math.IsNaN(r.Duration) || math.IsInf(r.Duration, 0) {
		r.Duration = 0
	}
	return r
}

func truncate(s string, max int) string {
	runes := []rune(s)
	if len(runes) <= max {
		return s
	}
	return string(runes[:max])
}
