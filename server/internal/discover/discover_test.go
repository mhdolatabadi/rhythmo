package discover

import (
	"fmt"
	"testing"
	"time"

	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

var now = time.Date(2026, 11, 13, 20, 0, 0, 0, time.UTC)

func ptr(s string) *string { return &s }

func track(id, artist, album, genre string, addedDaysAgo int) store.Track {
	t := store.Track{ID: id, Title: id, Status: store.TrackReady, CreatedAt: now.Add(-time.Duration(addedDaysAgo) * 24 * time.Hour)}
	if artist != "" {
		t.Artist = ptr(artist)
	}
	if album != "" {
		t.Album = ptr(album)
	}
	if genre != "" {
		t.Genre = ptr(genre)
	}
	return t
}

func plays(id string, n int, daysAgo int) []Play {
	var out []Play
	for i := range n {
		out = append(out, Play{TrackID: id, PlayedAt: now.Add(-time.Duration(daysAgo)*24*time.Hour - time.Duration(i)*time.Minute)})
	}
	return out
}

func ids(tracks []store.Track) []string {
	out := make([]string, len(tracks))
	for i, t := range tracks {
		out[i] = t.ID
	}
	return out
}

func TestSmartPlaylists(t *testing.T) {
	s := Signals{Tracks: []store.Track{
		track("fresh", "a", "", "", 3),
		track("loved", "a", "", "", 100),
		track("liked", "b", "", "", 100),
		track("old-heard", "c", "", "", 200),
		track("never", "c", "", "", 90),
		track("young-unheard", "c", "", "", 40),
	}}
	s.Plays = append(s.Plays, plays("loved", 5, 2)...)
	s.Plays = append(s.Plays, plays("liked", 2, 10)...)
	s.Plays = append(s.Plays, plays("liked", 9, 45)...) // too long ago for «پرپخش‌ترین‌ها»
	s.Plays = append(s.Plays, plays("old-heard", 1, 70)...)
	lists := Smart(s, now)
	got := map[string][]string{}
	for _, l := range lists {
		got[l.Key] = ids(l.Tracks)
	}
	want := map[string][]string{
		"most-played":    {"loved", "liked"},
		"recently-added": {"fresh"},
		"not-heard":      {"old-heard", "never"},
	}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("smart = %v, want %v", got, want)
	}
	if len(Smart(Signals{}, now)) != 0 {
		t.Fatal("an empty library got smart playlists")
	}
}

func TestSmartPlaylistsAreCapped(t *testing.T) {
	var s Signals
	for i := range SmartLimit + 10 {
		s.Tracks = append(s.Tracks, track(fmt.Sprintf("t%03d", i), "", "", "", 1))
	}
	if l := Smart(s, now); len(l) != 1 || len(l[0].Tracks) != SmartLimit {
		t.Fatalf("smart = %d lists", len(l))
	}
}

func library(n int) Signals {
	var s Signals
	artists := []string{"Shajarian", "Homayoun", "Kayhan", "Googoosh", "Ebi", "Dariush", "Moein"}
	for i := range n {
		a := artists[i%len(artists)]
		s.Tracks = append(s.Tracks, track(fmt.Sprintf("t%03d", i), a, a+" album", "pop", 10+i))
	}
	s.Plays = append(s.Plays, plays("t000", 8, 1)...)
	s.Plays = append(s.Plays, plays("t001", 4, 3)...)
	return s
}

func TestDailyMixes(t *testing.T) {
	if mixes := DailyMixes("u", library(MinMix-1), now); mixes != nil {
		t.Fatalf("a library of %d tracks got %d mixes", MinMix-1, len(mixes))
	}
	if mixes := DailyMixes("u", Signals{}, now); mixes != nil {
		t.Fatal("an empty library got mixes")
	}
	if n := len(DailyMixes("u", library(45), now)); n != 2 {
		t.Fatalf("45 tracks got %d mixes, want 2", n)
	}

	s := library(200)
	mixes := DailyMixes("u", s, now)
	if len(mixes) != MaxMixes {
		t.Fatalf("got %d mixes", len(mixes))
	}
	for i, m := range mixes {
		if m.Key != fmt.Sprintf("mix-%d", i+1) || len(m.Tracks) < MinMix || len(m.Tracks) > MaxMix {
			t.Fatalf("mix %d = %s with %d tracks", i, m.Key, len(m.Tracks))
		}
		seen := map[string]bool{}
		perArtist := map[string]int{}
		for _, tr := range m.Tracks {
			if seen[tr.ID] {
				t.Fatalf("%s repeats %s", m.Key, tr.ID)
			}
			seen[tr.ID] = true
			perArtist[*tr.Artist]++
		}
		for a, n := range perArtist {
			if n > (len(m.Tracks)+1)/2 {
				t.Fatalf("%s gives %s %d of %d", m.Key, a, n, len(m.Tracks))
			}
		}
	}

	// The same day gives the same mixes, even later that day and with the
	// library listed in another order; another day or user may not.
	shuffled := Signals{Plays: s.Plays}
	for i := len(s.Tracks) - 1; i >= 0; i-- {
		shuffled.Tracks = append(shuffled.Tracks, s.Tracks[i])
	}
	again := DailyMixes("u", shuffled, now.Add(3*time.Hour))
	if fmt.Sprint(mixIDs(again)) != fmt.Sprint(mixIDs(mixes)) {
		t.Fatal("the mixes changed within the day")
	}
	if fmt.Sprint(mixIDs(DailyMixes("u", s, now.Add(24*time.Hour)))) == fmt.Sprint(mixIDs(mixes)) {
		t.Fatal("the next day's mixes are the same")
	}
}

func TestDailyMixesSkipDeletedAndUntaggedTracks(t *testing.T) {
	s := library(MinMix)
	s.Tracks[0].Status = store.TrackPending
	if mixes := DailyMixes("u", s, now); mixes != nil {
		t.Fatal("a track that isn't ready counted toward a mix")
	}
	var untagged Signals
	for i := range 25 {
		untagged.Tracks = append(untagged.Tracks, track(fmt.Sprintf("u%02d", i), "", "", "", 5))
	}
	mixes := DailyMixes("u", untagged, now)
	if len(mixes) != 1 || len(mixes[0].Tracks) < MinMix {
		t.Fatalf("untagged library got %v", mixIDs(mixes))
	}
}

func mixIDs(mixes []List) [][]string {
	var out [][]string
	for _, m := range mixes {
		out = append(out, ids(m.Tracks))
	}
	return out
}

func TestRadio(t *testing.T) {
	s := Signals{Tracks: []store.Track{
		track("seed", "Shajarian", "Bidad", "classical", 50),
		track("same-album", "Shajarian", "Bidad", "classical", 50),
		track("same-artist", "Shajarian", "Other", "", 50),
		track("same-genre", "Alizadeh", "", "classical", 50),
		track("co-played", "Ebi", "", "pop", 50),
		track("queued", "Shajarian", "Bidad", "classical", 50),
		track("unrelated", "Moein", "", "pop", 50),
	}}
	s.Plays = []Play{
		{TrackID: "seed", PlayedAt: now.Add(-48 * time.Hour)},
		{TrackID: "co-played", PlayedAt: now.Add(-48*time.Hour + 5*time.Minute)},
		{TrackID: "unrelated", PlayedAt: now.Add(-24 * time.Hour)},
	}
	got := ids(Radio(s, []string{"seed", "deleted"}, map[string]bool{"queued": true}, 10, now))
	// A co-played and a same-genre track score the same; plays break the tie.
	want := []string{"same-album", "same-artist", "co-played", "same-genre", "unrelated"}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("radio = %v, want %v", got, want)
	}
	if got := Radio(s, []string{"seed"}, nil, 2, now); len(got) != 2 {
		t.Fatalf("radio ignored its limit: %v", ids(got))
	}
	if got := Radio(Signals{}, []string{"seed"}, nil, 10, now); len(got) != 0 {
		t.Fatalf("radio from an empty library = %v", ids(got))
	}
}
