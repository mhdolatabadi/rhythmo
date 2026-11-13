// Package discover builds the listener's «برای تو» lists from their own
// library and listening (#226): smart playlists that keep themselves up to
// date, up to three daily mixes, and radio that carries on after a queue
// ends. Everything here is a pure function of the user's own tracks and
// plays, so it is deterministic and easy to test.
package discover

import (
	"hash/fnv"
	"math/rand/v2"
	"sort"
	"strings"
	"time"

	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

// Play is one listen of one of the user's tracks.
type Play struct {
	TrackID  string
	PlayedAt time.Time
}

// Signals are what the lists are built from: the user's ready tracks and
// their plays of them.
type Signals struct {
	Tracks []store.Track
	Plays  []Play
}

const (
	// SmartLimit caps each smart playlist.
	SmartLimit = 50
	// MaxMixes is how many daily mixes a listener gets at most.
	MaxMixes = 3
	// MinMix and MaxMix bound a daily mix's length.
	MinMix = 20
	MaxMix = 30
	// RadioLimit is how many tracks one radio request adds.
	RadioLimit = 20

	recentWindow   = 30 * 24 * time.Hour
	forgottenAfter = 60 * 24 * time.Hour
	// coPlayWindow is how close two plays must be to count as played
	// together.
	coPlayWindow = 30 * time.Minute
)

// List is one generated list.
type List struct {
	// Key is stable for a kind of list: "most-played", "recently-added",
	// "not-heard" or "mix-1" to "mix-3".
	Key    string
	Title  string
	Tracks []store.Track
}

type stats struct {
	recent int
	total  int
	last   time.Time
}

func (s Signals) stats(now time.Time) map[string]stats {
	byTrack := map[string]stats{}
	for _, p := range s.Plays {
		st := byTrack[p.TrackID]
		st.total++
		if now.Sub(p.PlayedAt) <= recentWindow {
			st.recent++
		}
		if p.PlayedAt.After(st.last) {
			st.last = p.PlayedAt
		}
		byTrack[p.TrackID] = st
	}
	return byTrack
}

func ready(tracks []store.Track) []store.Track {
	out := make([]store.Track, 0, len(tracks))
	for _, t := range tracks {
		if t.Status == "" || t.Status == store.TrackReady {
			out = append(out, t)
		}
	}
	return out
}

// Smart builds «پرپخش‌ترین‌ها», «تازه‌اضافه‌شده» and «مدتی است
// نشنیده‌ای»; an empty one is left out.
func Smart(s Signals, now time.Time) []List {
	tracks := ready(s.Tracks)
	st := s.stats(now)
	var mostPlayed, added, forgotten []store.Track
	for _, t := range tracks {
		if st[t.ID].recent > 0 {
			mostPlayed = append(mostPlayed, t)
		}
		if now.Sub(t.CreatedAt) <= recentWindow {
			added = append(added, t)
		}
		if now.Sub(t.CreatedAt) >= forgottenAfter && (st[t.ID].last.IsZero() || now.Sub(st[t.ID].last) >= forgottenAfter) {
			forgotten = append(forgotten, t)
		}
	}
	sort.SliceStable(mostPlayed, func(i, j int) bool {
		a, b := st[mostPlayed[i].ID], st[mostPlayed[j].ID]
		if a.recent != b.recent {
			return a.recent > b.recent
		}
		if !a.last.Equal(b.last) {
			return a.last.After(b.last)
		}
		return mostPlayed[i].ID < mostPlayed[j].ID
	})
	sort.SliceStable(added, func(i, j int) bool {
		if !added[i].CreatedAt.Equal(added[j].CreatedAt) {
			return added[i].CreatedAt.After(added[j].CreatedAt)
		}
		return added[i].ID < added[j].ID
	})
	// Heard long ago first, then never heard, oldest added first.
	sort.SliceStable(forgotten, func(i, j int) bool {
		a, b := st[forgotten[i].ID].last, st[forgotten[j].ID].last
		if a.IsZero() != b.IsZero() {
			return !a.IsZero()
		}
		if !a.Equal(b) {
			return a.Before(b)
		}
		if !forgotten[i].CreatedAt.Equal(forgotten[j].CreatedAt) {
			return forgotten[i].CreatedAt.Before(forgotten[j].CreatedAt)
		}
		return forgotten[i].ID < forgotten[j].ID
	})
	var lists []List
	for _, l := range []List{
		{Key: "most-played", Title: "پرپخش‌ترین‌ها", Tracks: mostPlayed},
		{Key: "recently-added", Title: "تازه‌اضافه‌شده", Tracks: added},
		{Key: "not-heard", Title: "مدتی است نشنیده‌ای", Tracks: forgotten},
	} {
		if len(l.Tracks) > SmartLimit {
			l.Tracks = l.Tracks[:SmartLimit]
		}
		if len(l.Tracks) > 0 {
			lists = append(lists, l)
		}
	}
	return lists
}

func key(s *string) string {
	if s == nil {
		return ""
	}
	return strings.ToLower(strings.TrimSpace(*s))
}

func artistOf(t store.Track) string {
	if a := key(t.Artist); a != "" {
		return a
	}
	return key(t.AlbumArtist)
}

func albumOf(t store.Track) string {
	if a := key(t.Album); a != "" {
		return artistOf(t) + "|" + a
	}
	return ""
}

// weight is how much the listener cares for t lately: recent plays count
// most, any play some, and a track added in the last month a little.
func weight(t store.Track, st stats, now time.Time) float64 {
	w := 1 + 3*float64(st.recent) + 0.5*float64(st.total)
	if now.Sub(t.CreatedAt) <= recentWindow {
		w++
	}
	return w
}

// Seed is the day's random seed for userID: the same all day, different
// the next.
func Seed(userID string, day time.Time) uint64 {
	h := fnv.New64a()
	h.Write([]byte(userID))
	h.Write([]byte(day.UTC().Format("2006-01-02")))
	return h.Sum64()
}

// DailyMixes builds up to three mixes of 20 to 30 tracks for the day of
// now, each around one artist the listener plays a lot, with their albums
// and songs of the same genre around it. The same user, library and day
// always give the same mixes. A library of fewer than 20 tracks gets none.
func DailyMixes(userID string, s Signals, now time.Time) []List {
	tracks := ready(s.Tracks)
	if len(tracks) < MinMix {
		return nil
	}
	// Everything is measured from the start of the day, so the mixes hold
	// all day.
	now = now.UTC().Truncate(24 * time.Hour)
	rng := rand.New(rand.NewPCG(Seed(userID, now), 0x726879746d6f))
	st := s.stats(now)
	sort.SliceStable(tracks, func(i, j int) bool { return tracks[i].ID < tracks[j].ID })

	artistWeight := map[string]float64{}
	genres := map[string]map[string]float64{}
	for _, t := range tracks {
		a := artistOf(t)
		if a == "" {
			continue
		}
		w := weight(t, st[t.ID], now)
		artistWeight[a] += w
		if g := key(t.Genre); g != "" {
			if genres[a] == nil {
				genres[a] = map[string]float64{}
			}
			genres[a][g] += w
		}
	}
	artists := make([]string, 0, len(artistWeight))
	for a := range artistWeight {
		artists = append(artists, a)
	}
	sort.Slice(artists, func(i, j int) bool {
		if artistWeight[artists[i]] != artistWeight[artists[j]] {
			return artistWeight[artists[i]] > artistWeight[artists[j]]
		}
		return artists[i] < artists[j]
	})
	// The day's anchors: drawn from the six artists played most, weighted,
	// so the mixes change from day to day without wandering off.
	pool := artists[:min(len(artists), 6)]
	count := min(MaxMixes, len(tracks)/MinMix)
	var anchors []string
	for len(anchors) < count && len(pool) > 0 {
		total := 0.0
		for _, a := range pool {
			total += artistWeight[a]
		}
		pick, at := rng.Float64()*total, 0
		for i, a := range pool {
			pick -= artistWeight[a]
			if pick <= 0 {
				at = i
				break
			}
		}
		anchors = append(anchors, pool[at])
		pool = append(pool[:at:at], pool[at+1:]...)
	}
	if len(anchors) == 0 {
		// A library without artist tags still gets one mix.
		anchors = []string{""}
	}

	var mixes []List
	for n, anchor := range anchors {
		size := min(len(tracks), MinMix+rng.IntN(MaxMix-MinMix+1))
		genre := topKey(genres[anchor])
		albums := map[string]bool{}
		for _, t := range tracks {
			if anchor != "" && artistOf(t) == anchor && albumOf(t) != "" {
				albums[albumOf(t)] = true
			}
		}
		type scored struct {
			t     store.Track
			score float64
		}
		candidates := make([]scored, 0, len(tracks))
		for _, t := range tracks {
			factor := 1.0
			switch {
			case anchor != "" && artistOf(t) == anchor:
				factor = 4
			case albums[albumOf(t)]:
				factor = 3
			case genre != "" && key(t.Genre) == genre:
				factor = 2
			}
			candidates = append(candidates, scored{t, weight(t, st[t.ID], now) * factor * (0.5 + rng.Float64())})
		}
		sort.SliceStable(candidates, func(i, j int) bool { return candidates[i].score > candidates[j].score })
		// No one artist fills a mix: the anchor takes half at most, any
		// other artist a fifth.
		perArtist := map[string]int{}
		var picked []store.Track
		for _, c := range candidates {
			if len(picked) == size {
				break
			}
			a := artistOf(c.t)
			limit := max(3, size/5)
			if a == anchor && anchor != "" {
				limit = (size + 1) / 2
			}
			if a != "" && perArtist[a] >= limit {
				continue
			}
			perArtist[a]++
			picked = append(picked, c.t)
		}
		// A small library may need the capped tracks to reach the length.
		if len(picked) < size {
			in := map[string]bool{}
			for _, t := range picked {
				in[t.ID] = true
			}
			for _, c := range candidates {
				if len(picked) == size {
					break
				}
				if !in[c.t.ID] {
					picked = append(picked, c.t)
				}
			}
		}
		rng.Shuffle(len(picked), func(i, j int) { picked[i], picked[j] = picked[j], picked[i] })
		mixes = append(mixes, List{Key: mixKey(n), Title: "میکس روزانه " + persianDigit(n+1), Tracks: picked})
	}
	return mixes
}

func topKey(m map[string]float64) string {
	best, bestW := "", 0.0
	for k, w := range m {
		if w > bestW || (w == bestW && k < best) {
			best, bestW = k, w
		}
	}
	return best
}

func mixKey(n int) string { return "mix-" + string(rune('1'+n)) }

func persianDigit(n int) string { return string(rune('۰' + n)) }

// Radio picks up to limit tracks to play after seeds: the same artist,
// album or genre, or tracks often played close to them. Tracks in exclude
// (already in the queue) and the seeds themselves are left out. When too
// few are similar, the listener's favourites fill up the rest, so the
// music goes on.
func Radio(s Signals, seeds []string, exclude map[string]bool, limit int, now time.Time) []store.Track {
	tracks := ready(s.Tracks)
	byID := map[string]store.Track{}
	for _, t := range tracks {
		byID[t.ID] = t
	}
	seedSet := map[string]bool{}
	var artists, albums, genres = map[string]bool{}, map[string]bool{}, map[string]bool{}
	for _, id := range seeds {
		t, ok := byID[id]
		if !ok {
			continue
		}
		seedSet[id] = true
		if a := artistOf(t); a != "" {
			artists[a] = true
		}
		if a := albumOf(t); a != "" {
			albums[a] = true
		}
		if g := key(t.Genre); g != "" {
			genres[g] = true
		}
	}
	// Plays within half an hour of a seed's play count as played together.
	var seedPlays []time.Time
	for _, p := range s.Plays {
		if seedSet[p.TrackID] {
			seedPlays = append(seedPlays, p.PlayedAt)
		}
	}
	coPlayed := map[string]int{}
	for _, p := range s.Plays {
		if seedSet[p.TrackID] {
			continue
		}
		for _, at := range seedPlays {
			if d := p.PlayedAt.Sub(at); d < coPlayWindow && d > -coPlayWindow {
				coPlayed[p.TrackID]++
				break
			}
		}
	}
	st := s.stats(now)
	type scored struct {
		t     store.Track
		score float64
	}
	var candidates []scored
	for _, t := range tracks {
		if seedSet[t.ID] || exclude[t.ID] {
			continue
		}
		score := 0.0
		if artists[artistOf(t)] {
			score += 3
		}
		if albums[albumOf(t)] {
			score += 2
		}
		if genres[key(t.Genre)] {
			score++
		}
		score += float64(min(coPlayed[t.ID], 3))
		// Played lately breaks ties and orders the fill.
		score += min(weight(t, st[t.ID], now), 999) / 1000
		candidates = append(candidates, scored{t, score})
	}
	sort.SliceStable(candidates, func(i, j int) bool {
		if candidates[i].score != candidates[j].score {
			return candidates[i].score > candidates[j].score
		}
		return candidates[i].t.ID < candidates[j].t.ID
	})
	var out []store.Track
	for _, c := range candidates {
		if len(out) == limit {
			break
		}
		out = append(out, c.t)
	}
	return out
}
