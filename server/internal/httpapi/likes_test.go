package httpapi

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/mhdolatabadi/rhythmo/server/internal/auth"
	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

// fakeLikes keeps likes in memory: own tracks by id, store songs by entry.
type fakeLikes struct {
	own    map[string]string // track id → owner
	liked  map[string]bool   // user|id
	listed map[string]bool   // listed store entries
	calls  int
}

func (f *fakeLikes) count(id string) int {
	n := 0
	for key, liked := range f.liked {
		if liked && strings.HasSuffix(key, "|"+id) {
			n++
		}
	}
	return n
}

func (f *fakeLikes) SetOwnLike(_ context.Context, userID, trackID string, liked bool) (store.LikeState, error) {
	f.calls++
	if f.own[trackID] != userID {
		return store.LikeState{}, store.ErrNotFound
	}
	f.liked[userID+"|"+trackID] = liked
	return store.LikeState{Count: f.count(trackID), Liked: liked}, nil
}

func (f *fakeLikes) SetStoreLike(_ context.Context, userID, entryID string, liked bool) (store.LikeState, error) {
	f.calls++
	if !f.listed[entryID] {
		return store.LikeState{}, store.ErrNotFound
	}
	f.liked[userID+"|"+entryID] = liked
	return store.LikeState{Count: f.count(entryID), Liked: liked}, nil
}

func (f *fakeLikes) EntryStates(_ context.Context, viewerID string, ids []string) (map[string]store.LikeState, error) {
	states := map[string]store.LikeState{}
	for _, id := range ids {
		states[id] = store.LikeState{Count: f.count(id), Liked: f.liked[viewerID+"|"+id]}
	}
	return states, nil
}

func (f *fakeLikes) OwnerStates(_ context.Context, ownerID string) (map[string]store.LikeState, error) {
	states := map[string]store.LikeState{}
	for id, owner := range f.own {
		if owner == ownerID {
			states[id] = store.LikeState{Count: f.count(id), Liked: f.liked[ownerID+"|"+id]}
		}
	}
	return states, nil
}

func (f *fakeLikes) Liked(_ context.Context, userID string, limit, offset int) ([]store.LikedSong, bool, error) {
	at := time.Date(2026, 10, 15, 12, 0, 0, 0, time.UTC)
	var songs []store.LikedSong
	for id, owner := range f.own {
		if owner == userID && f.liked[userID+"|"+id] {
			songs = append(songs, store.LikedSong{LikedAt: at, Track: store.Track{ID: id, OwnerID: owner, Title: "mine", FileName: "m.mp3"}})
		}
	}
	for id := range f.listed {
		if f.liked[userID+"|"+id] {
			entry := store.StoreEntry{ID: id, Track: store.Track{ID: "copy-of-" + id, OwnerID: "someone", Title: "theirs", FileName: "secret.mp3"}}
			songs = append(songs, store.LikedSong{LikedAt: at.Add(-time.Hour), Track: entry.Track, Entry: &entry})
		}
	}
	return songs, false, nil
}

type fakePublisher struct {
	published map[string]bool
	direct    bool
}

func (p *fakePublisher) SetPublished(_ context.Context, ownerID, trackID string, published, direct bool) (store.Track, error) {
	if ownerID != "alice" || trackID != "t1" {
		return store.Track{}, store.ErrNotFound
	}
	p.direct = direct
	track := store.Track{ID: trackID, OwnerID: ownerID}
	if published && !direct && !p.published[trackID] {
		pending := store.ReviewPending
		track.PublishReview = &pending
		return track, nil
	}
	p.published[trackID] = published
	if published {
		at := time.Now()
		track.PublishedAt = &at
	}
	return track, nil
}

func newLikesAPI(t *testing.T, rate *RateLimiter) (http.Handler, *fakeLikes, *fakePublisher, string, string) {
	t.Helper()
	tokens, _ := auth.NewTokens([]byte(strings.Repeat("k", auth.MinSecretBytes)), time.Hour)
	alice, _, _ := tokens.Issue("alice")
	bob, _, _ := tokens.Issue("bob")
	likes := &fakeLikes{own: map[string]string{"t1": "alice"}, liked: map[string]bool{}, listed: map[string]bool{storeEntryID: true}}
	publisher := &fakePublisher{published: map[string]bool{}}
	if rate == nil {
		rate = NewRateLimiter(RateLimit{Requests: 100, Window: time.Hour}, 100)
	}
	return NewHandler(Config{Likes: NewLikeHandlers(likes, publisher, tokens, rate)}), likes, publisher, alice, bob
}

func call(handler http.Handler, method, path, token string) *httptest.ResponseRecorder {
	request := httptest.NewRequest(method, path, nil)
	if token != "" {
		request.Header.Set("Authorization", "Bearer "+token)
	}
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	return response
}

func TestLikesNeedAnAccount(t *testing.T) {
	handler, likes, _, _, _ := newLikesAPI(t, nil)
	for _, c := range []struct{ method, path string }{
		{"PUT", "/api/v1/tracks/t1/like"}, {"DELETE", "/api/v1/tracks/t1/like"},
		{"PUT", "/api/v1/store/tracks/" + storeEntryID + "/like"}, {"DELETE", "/api/v1/store/tracks/" + storeEntryID + "/like"},
		{"PUT", "/api/v1/tracks/t1/published"}, {"DELETE", "/api/v1/tracks/t1/published"},
		{"GET", "/api/v1/likes"},
	} {
		expectError(t, call(handler, c.method, c.path, ""), http.StatusUnauthorized, "unauthorized")
	}
	if likes.calls != 0 {
		t.Fatal("an anonymous request reached the likes")
	}
}

func TestLikingIsIdempotentAndOnlyOnWhatYouMayLike(t *testing.T) {
	handler, _, _, alice, bob := newLikesAPI(t, nil)
	for range 2 {
		got := decode[trackLikeResponse](t, call(handler, "PUT", "/api/v1/store/tracks/"+storeEntryID+"/like", bob))
		if got != (trackLikeResponse{Liked: true, LikeCount: 1}) {
			t.Fatalf("bob likes the song = %+v", got)
		}
	}
	got := decode[trackLikeResponse](t, call(handler, "PUT", "/api/v1/store/tracks/"+storeEntryID+"/like", alice))
	if got.LikeCount != 2 {
		t.Fatalf("alice likes too = %+v", got)
	}
	got = decode[trackLikeResponse](t, call(handler, "DELETE", "/api/v1/store/tracks/"+storeEntryID+"/like", bob))
	if got != (trackLikeResponse{Liked: false, LikeCount: 1}) {
		t.Fatalf("bob unlikes = %+v", got)
	}
	expectError(t, call(handler, "PUT", "/api/v1/store/tracks/gone/like", bob), http.StatusNotFound, "not_found")
	// Someone else's library track is liked only through the store.
	expectError(t, call(handler, "PUT", "/api/v1/tracks/t1/like", bob), http.StatusNotFound, "not_found")
	if got := decode[trackLikeResponse](t, call(handler, "PUT", "/api/v1/tracks/t1/like", alice)); !got.Liked {
		t.Fatalf("alice likes her own track = %+v", got)
	}
}

func TestOnlyTheOwnerPublishes(t *testing.T) {
	handler, _, publisher, alice, bob := newLikesAPI(t, nil)
	expectError(t, call(handler, "PUT", "/api/v1/tracks/t1/published", bob), http.StatusNotFound, "not_found")
	got := decode[publishResponse](t, call(handler, "PUT", "/api/v1/tracks/t1/published", alice))
	if !got.Published || got.PublishedAt == nil || !publisher.published["t1"] {
		t.Fatalf("publish = %+v", got)
	}
	got = decode[publishResponse](t, call(handler, "DELETE", "/api/v1/tracks/t1/published", alice))
	if got.Published || got.PublishedAt != nil || publisher.published["t1"] {
		t.Fatalf("unpublish = %+v", got)
	}
}

func TestLikesAreRateLimitedPerAccount(t *testing.T) {
	handler, _, _, alice, bob := newLikesAPI(t, NewRateLimiter(RateLimit{Requests: 2, Window: time.Hour}, 100))
	call(handler, "PUT", "/api/v1/tracks/t1/like", alice)
	call(handler, "DELETE", "/api/v1/tracks/t1/like", alice)
	expectError(t, call(handler, "PUT", "/api/v1/tracks/t1/like", alice), http.StatusTooManyRequests, "rate_limited")
	expectError(t, call(handler, "PUT", "/api/v1/tracks/t1/published", alice), http.StatusTooManyRequests, "rate_limited")
	if response := call(handler, "PUT", "/api/v1/store/tracks/"+storeEntryID+"/like", bob); response.Code != http.StatusOK {
		t.Fatalf("bob was limited by alice's likes: %d", response.Code)
	}
}

func TestLikedSongsList(t *testing.T) {
	handler, _, _, alice, _ := newLikesAPI(t, nil)
	call(handler, "PUT", "/api/v1/tracks/t1/like", alice)
	call(handler, "PUT", "/api/v1/store/tracks/"+storeEntryID+"/like", alice)
	response := call(handler, "GET", "/api/v1/likes", alice)
	body := response.Body.String()
	if response.Code != http.StatusOK || strings.Contains(body, "someone") || strings.Contains(body, "copy-of-") ||
		strings.Contains(body, "secret.mp3") {
		t.Fatalf("liked = %d %s", response.Code, body)
	}
	listed := decode[struct {
		Songs []likedSongResponse `json:"songs"`
	}](t, response)
	if len(listed.Songs) != 2 {
		t.Fatalf("liked = %+v", listed)
	}
	sources := map[string]bool{}
	for _, song := range listed.Songs {
		sources[song.Source] = true
		switch song.Source {
		case "library":
			if song.Track == nil || song.Track.ID != "t1" || !song.Track.Liked {
				t.Fatalf("own song = %+v", song)
			}
		case "store":
			if song.StoreTrack == nil || song.StoreTrack.ID != storeEntryID || !song.StoreTrack.Liked {
				t.Fatalf("store song = %+v", song)
			}
		}
	}
	if !sources["library"] || !sources["store"] {
		t.Fatalf("sources = %v", sources)
	}
}

func TestTheOwnersLibraryCarriesPublishedAndLikeCounts(t *testing.T) {
	tracks := &memoryTracks{}
	at := time.Now()
	tracks.tracks = []store.Track{
		{ID: "t1", OwnerID: "alice", Status: store.TrackReady, Title: "published", FileName: "p.mp3", PublishedAt: &at},
		{ID: "t2", OwnerID: "alice", Status: store.TrackReady, Title: "private", FileName: "q.mp3"},
	}
	likes := &fakeLikes{own: map[string]string{"t1": "alice", "t2": "alice"}, liked: map[string]bool{"bob|t1": true, "carol|t1": true, "alice|t2": true}}
	tokens, _ := auth.NewTokens([]byte(strings.Repeat("k", auth.MinSecretBytes)), time.Hour)
	alice, _, _ := tokens.Issue("alice")
	handler := NewHandler(Config{Tracks: NewTrackHandlers(tracks, &fakeObjects{objects: map[string][]byte{}}, tokens, UploadLimits{}).WithLikes(likes)})
	list := decode[trackListResponse](t, call(handler, "GET", "/api/v1/tracks", alice))
	byID := map[string]trackResponse{}
	for _, track := range list.Tracks {
		byID[track.ID] = track
	}
	if got := byID["t1"]; !got.Published || got.LikeCount != 2 || got.Liked {
		t.Fatalf("published track = %+v", got)
	}
	if got := byID["t2"]; got.Published || got.LikeCount != 1 || !got.Liked {
		t.Fatalf("private track = %+v", got)
	}
}

func TestStoreSongsCarryLikes(t *testing.T) {
	api := newStoreTestAPI(t, AnonymousLimits{})
	likes := &fakeLikes{own: map[string]string{}, liked: map[string]bool{api.memberID + "|" + storeEntryID: true, "x|" + storeEntryID: true}, listed: map[string]bool{storeEntryID: true}}
	tokens, _ := auth.NewTokens([]byte(strings.Repeat("k", auth.MinSecretBytes)), time.Hour)
	handler := NewHandler(Config{Store: NewCatalogHandlers(api.catalog, tokens, fixedPresigner{}, AnonymousLimits{
		View: NewRateLimiter(RateLimit{Requests: 100, Window: time.Hour}, 100),
	}).WithLikes(likes)})
	member, _, _ := tokens.Issue(api.memberID)
	for _, c := range []struct {
		token string
		liked bool
	}{{"", false}, {member, true}} {
		got := decode[storeTrackResponse](t, call(handler, "GET", "/api/v1/store/tracks/"+storeEntryID, c.token))
		if got.LikeCount != 2 || got.Liked != c.liked {
			t.Fatalf("token %q: %+v", c.token, got)
		}
		listed := decode[struct {
			Tracks []storeTrackResponse `json:"tracks"`
		}](t, call(handler, "GET", "/api/v1/store/tracks", c.token))
		if listed.Tracks[0].LikeCount != 2 || listed.Tracks[0].Liked != c.liked {
			t.Fatalf("listing for %q: %+v", c.token, listed.Tracks[0])
		}
	}
}
