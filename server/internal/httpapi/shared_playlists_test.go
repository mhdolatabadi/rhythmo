package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/mhdolatabadi/rhythmo/server/internal/auth"
	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

// sharingStore holds one playlist owned by alice with one track in it.
type sharingStore struct {
	name    string
	token   *string
	public  bool
	review  *string
	tracks  []store.Track
	outside store.Track
	likers  map[string]bool
	limit   int
}

func (s *sharingStore) ListForUser(context.Context, string) ([]store.Playlist, error) {
	return nil, nil
}
func (s *sharingStore) ForUser(context.Context, string, string) (store.Playlist, error) {
	return store.Playlist{}, store.ErrNotFound
}
func (s *sharingStore) SetCollabToken(context.Context, string, string, *string) (store.Playlist, error) {
	return store.Playlist{}, errors.New("unused")
}
func (s *sharingStore) Join(context.Context, string, string) (store.Playlist, error) {
	return store.Playlist{}, errors.New("unused")
}
func (s *sharingStore) RemoveMember(context.Context, string, string, string) error {
	return errors.New("unused")
}
func (s *sharingStore) PlaylistTrack(context.Context, string, string, string) (store.Track, error) {
	return store.Track{}, errors.New("unused")
}
func (s *sharingStore) Create(context.Context, string, string) (store.Playlist, error) {
	return store.Playlist{}, errors.New("unused")
}
func (s *sharingStore) Rename(context.Context, string, string, string) (store.Playlist, error) {
	return store.Playlist{}, errors.New("unused")
}
func (s *sharingStore) ReplaceTracks(context.Context, string, string, []string) error {
	return errors.New("unused")
}
func (s *sharingStore) Delete(context.Context, string, string) error { return errors.New("unused") }

func (s *sharingStore) Share(_ context.Context, ownerID, playlistID, token string, public *bool, direct bool) (store.Playlist, error) {
	if ownerID != "alice" || playlistID != "p1" {
		return store.Playlist{}, store.ErrNotFound
	}
	if s.token == nil {
		s.token = &token
	}
	switch {
	case public == nil:
	case *public && !direct && !s.public:
		pending := store.ReviewPending
		s.review = &pending
	default:
		s.public, s.review = *public, nil
	}
	return store.Playlist{ID: "p1", OwnerID: "alice", ShareToken: s.token, IsPublic: s.public, PublicReview: s.review}, nil
}

func (s *sharingStore) Unshare(_ context.Context, ownerID, playlistID string) error {
	if ownerID != "alice" || playlistID != "p1" {
		return store.ErrNotFound
	}
	s.token, s.public = nil, false
	return nil
}

func (s *sharingStore) ForShareToken(_ context.Context, token string) (store.SharedPlaylist, error) {
	if s.token == nil || *s.token != token {
		return store.SharedPlaylist{}, store.ErrNotFound
	}
	return store.SharedPlaylist{
		Playlist: store.Playlist{
			ID: "p1", OwnerID: "alice", Name: s.displayName(), Tracks: s.tracks, IsPublic: s.public, ShareToken: s.token,
		},
		OwnerEmail: "alice@example.com",
	}, nil
}

func (s *sharingStore) SharedTrack(_ context.Context, token, trackID string, publicOnly bool) (store.Track, error) {
	if s.token == nil || *s.token != token || (publicOnly && !s.public) {
		return store.Track{}, store.ErrNotFound
	}
	for _, t := range s.tracks {
		if t.ID == trackID {
			return t, nil
		}
	}
	return store.Track{}, store.ErrNotFound
}

func (s *sharingStore) SaveShared(_ context.Context, userID, token string, maxOwnerBytes int64, _ store.ObjectCopier) (store.Playlist, error) {
	if s.token == nil || *s.token != token {
		return store.Playlist{}, store.ErrNotFound
	}
	if userID == "alice" {
		return store.Playlist{}, store.ErrOwnPlaylist
	}
	if maxOwnerBytes < 100 {
		return store.Playlist{}, store.ErrQuotaExceeded
	}
	return store.Playlist{ID: "copy", OwnerID: userID, Name: "mix", Tracks: s.tracks}, nil
}

func (s *sharingStore) LikesFor(_ context.Context, playlistID, userID string) (store.Likes, error) {
	return store.Likes{Count: len(s.likers), Liked: s.likers[userID]}, nil
}

func (s *sharingStore) SetLike(_ context.Context, userID, token string, liked bool) (store.Likes, error) {
	if s.token == nil || *s.token != token {
		return store.Likes{}, store.ErrNotFound
	}
	if s.likers == nil {
		s.likers = map[string]bool{}
	}
	if liked {
		s.likers[userID] = true
	} else {
		delete(s.likers, userID)
	}
	return store.Likes{Count: len(s.likers), Liked: liked}, nil
}

func (s *sharingStore) Popular(_ context.Context, userID string, limit int) ([]store.PublicPlaylist, error) {
	s.limit = limit
	if s.token == nil || !s.public {
		return nil, nil
	}
	return []store.PublicPlaylist{{
		ShareToken: *s.token, Name: s.displayName(), OwnerID: "alice", OwnerEmail: "alice@example.com",
		TrackCount: len(s.tracks), Likes: store.Likes{Count: len(s.likers), Liked: s.likers[userID]},
	}}, nil
}

func (s *sharingStore) displayName() string {
	if s.name == "" {
		return "mix"
	}
	return s.name
}

type noCopies struct{}

func (noCopies) Copy(context.Context, string, string) error { return nil }
func (noCopies) Remove(context.Context, string) error       { return nil }

type fixedPresigner struct{}

func (fixedPresigner) PresignGet(_ context.Context, key string) (string, time.Time, error) {
	return "https://music.example.com/nafir-music/" + key + "?sig", time.Now().Add(time.Hour), nil
}

func TestSharingAPlaylistEndToEnd(t *testing.T) {
	tokens, _ := auth.NewTokens([]byte(strings.Repeat("k", auth.MinSecretBytes)), time.Hour)
	alice, _, _ := tokens.Issue("alice")
	bob, _, _ := tokens.Issue("bob")
	data := &sharingStore{
		tracks:  []store.Track{{ID: "t1", Title: "in", StorageKey: "users/alice/tracks/t1/a.mp3", Status: store.TrackReady}},
		outside: store.Track{ID: "t2"},
	}
	handler := NewHandler(Config{Playlists: NewPlaylistHandlers(data, tokens).WithSharing(data, fixedPresigner{}, SavePolicy{Objects: noCopies{}, MaxOwnerBytes: 1000, Enabled: true})})
	call := func(method, path, token string) *httptest.ResponseRecorder {
		request := httptest.NewRequest(method, path, nil)
		if token != "" {
			request.Header.Set("Authorization", "Bearer "+token)
		}
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		return response
	}

	if response := call(http.MethodPost, "/api/v1/playlists/p1/share", bob); response.Code != http.StatusNotFound {
		t.Fatalf("bob sharing alice's playlist = %d", response.Code)
	}
	response := call(http.MethodPost, "/api/v1/playlists/p1/share", alice)
	var shared shareResponse
	json.NewDecoder(response.Body).Decode(&shared)
	if response.Code != http.StatusOK || !validShareToken(shared.ShareToken) {
		t.Fatalf("share = %d %+v", response.Code, shared)
	}
	link := "/api/v1/shared-playlists/" + shared.ShareToken

	if response := call(http.MethodGet, link, ""); response.Code != http.StatusUnauthorized {
		t.Fatalf("viewing signed out = %d", response.Code)
	}
	response = call(http.MethodGet, link, bob)
	var view sharedPlaylistResponse
	json.NewDecoder(response.Body).Decode(&view)
	if response.Code != http.StatusOK || view.Name != "mix" || view.Owner != "a***@example.com" ||
		view.IsOwner || view.TrackCount != 1 || strings.Contains(response.Body.String(), "users/alice") {
		t.Fatalf("bob's view = %d %+v", response.Code, view)
	}
	if response := call(http.MethodGet, link, alice); !strings.Contains(response.Body.String(), `"isOwner":true`) {
		t.Fatalf("owner's view = %s", response.Body)
	}

	if response := call(http.MethodGet, link+"/tracks/t1/stream", bob); response.Code != http.StatusOK {
		t.Fatalf("stream a track in the playlist = %d", response.Code)
	}
	if response := call(http.MethodGet, link+"/tracks/t2/stream", bob); response.Code != http.StatusNotFound {
		t.Fatalf("stream a track outside the playlist = %d", response.Code)
	}
	for _, bad := range []string{"not-a-token", strings.Repeat("A", 22), "abc%21def"} {
		if response := call(http.MethodGet, "/api/v1/shared-playlists/"+bad, bob); response.Code != http.StatusNotFound {
			t.Fatalf("malformed link %q = %d", bad, response.Code)
		}
	}

	if response := call(http.MethodDelete, "/api/v1/playlists/p1/share", bob); response.Code != http.StatusNotFound {
		t.Fatalf("bob unsharing = %d", response.Code)
	}
	if response := call(http.MethodDelete, "/api/v1/playlists/p1/share", alice); response.Code != http.StatusNoContent {
		t.Fatalf("unshare = %d", response.Code)
	}
	if response := call(http.MethodGet, link, bob); response.Code != http.StatusNotFound {
		t.Fatalf("revoked link = %d", response.Code)
	}
	if response := call(http.MethodGet, link+"/tracks/t1/stream", bob); response.Code != http.StatusNotFound {
		t.Fatalf("stream after revoking = %d", response.Code)
	}
}

func TestSavingASharedPlaylistEndpoint(t *testing.T) {
	tokens, _ := auth.NewTokens([]byte(strings.Repeat("k", auth.MinSecretBytes)), time.Hour)
	alice, _, _ := tokens.Issue("alice")
	bob, _, _ := tokens.Issue("bob")
	token := strings.Repeat("A", 22)
	data := &sharingStore{token: &token, tracks: []store.Track{{ID: "t1", Title: "in"}}}
	serve := func(policy SavePolicy, user string) *httptest.ResponseRecorder {
		handler := NewHandler(Config{Playlists: NewPlaylistHandlers(data, tokens).WithSharing(data, fixedPresigner{}, policy)})
		request := httptest.NewRequest(http.MethodPost, "/api/v1/shared-playlists/"+token+"/save", nil)
		if user != "" {
			request.Header.Set("Authorization", "Bearer "+user)
		}
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		return response
	}
	open := SavePolicy{Objects: noCopies{}, MaxOwnerBytes: 1000, Enabled: true}

	if response := serve(open, ""); response.Code != http.StatusUnauthorized {
		t.Fatalf("signed out = %d", response.Code)
	}
	response := serve(open, bob)
	var saved playlistResponse
	json.NewDecoder(response.Body).Decode(&saved)
	if response.Code != http.StatusCreated || saved.ID != "copy" || len(saved.Tracks) != 1 {
		t.Fatalf("save = %d %+v", response.Code, saved)
	}
	if response := serve(open, alice); response.Code != http.StatusConflict {
		t.Fatalf("owner saving their own = %d", response.Code)
	}
	if response := serve(SavePolicy{Objects: noCopies{}, MaxOwnerBytes: 10, Enabled: true}, bob); response.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("over quota = %d", response.Code)
	}
	if response := serve(SavePolicy{Objects: noCopies{}, MaxOwnerBytes: 1000}, bob); response.Code != http.StatusServiceUnavailable {
		t.Fatalf("uploads disabled = %d", response.Code)
	}
}

func TestLikingAndListingPublicPlaylists(t *testing.T) {
	tokens, _ := auth.NewTokens([]byte(strings.Repeat("k", auth.MinSecretBytes)), time.Hour)
	alice, _, _ := tokens.Issue("alice")
	bob, _, _ := tokens.Issue("bob")
	data := &sharingStore{tracks: []store.Track{{ID: "t1", Title: "in"}}}
	handler := NewHandler(Config{Playlists: NewPlaylistHandlers(data, tokens).WithSharing(data, fixedPresigner{}, SavePolicy{})})
	call := func(method, path, token, body string) *httptest.ResponseRecorder {
		request := httptest.NewRequest(method, path, strings.NewReader(body))
		if token != "" {
			request.Header.Set("Authorization", "Bearer "+token)
		}
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		return response
	}

	response := call(http.MethodPost, "/api/v1/playlists/p1/share", alice, `{"public":false}`)
	var shared shareResponse
	json.NewDecoder(response.Body).Decode(&shared)
	if response.Code != http.StatusOK || shared.Public {
		t.Fatalf("share link-only = %d %+v", response.Code, shared)
	}
	if response := call(http.MethodPost, "/api/v1/playlists/p1/share", alice, `{"public":`); response.Code != http.StatusBadRequest {
		t.Fatalf("broken body = %d", response.Code)
	}
	like := "/api/v1/shared-playlists/" + shared.ShareToken + "/like"

	if response := call(http.MethodPut, like, "", ""); response.Code != http.StatusUnauthorized {
		t.Fatalf("liking signed out = %d", response.Code)
	}
	for range 2 {
		response := call(http.MethodPut, like, bob, "")
		if response.Code != http.StatusOK || strings.TrimSpace(response.Body.String()) != `{"liked":true,"likeCount":1}` {
			t.Fatalf("like = %d %s", response.Code, response.Body)
		}
	}
	var view sharedPlaylistResponse
	json.NewDecoder(call(http.MethodGet, "/api/v1/shared-playlists/"+shared.ShareToken, bob, "").Body).Decode(&view)
	if view.LikeCount != 1 || !view.Liked || view.Public {
		t.Fatalf("bob's view = %+v", view)
	}
	var list struct {
		Playlists []publicPlaylistResponse `json:"playlists"`
	}
	json.NewDecoder(call(http.MethodGet, "/api/v1/public-playlists", bob, "").Body).Decode(&list)
	if len(list.Playlists) != 0 {
		t.Fatalf("a link-only playlist was listed: %+v", list)
	}

	// Sharing again with no body keeps the choice; asking makes it public.
	if response := call(http.MethodPost, "/api/v1/playlists/p1/share", alice, ""); strings.Contains(response.Body.String(), `"public":true`) {
		t.Fatalf("resharing changed visibility: %s", response.Body)
	}
	call(http.MethodPost, "/api/v1/playlists/p1/share", alice, `{"public":true}`)
	response = call(http.MethodGet, "/api/v1/public-playlists?limit=500", bob, "")
	json.NewDecoder(response.Body).Decode(&list)
	if response.Code != http.StatusOK || len(list.Playlists) != 1 || data.limit != maxPublicPlaylists {
		t.Fatalf("public list = %d %+v (limit %d)", response.Code, list, data.limit)
	}
	if got := list.Playlists[0]; got.ShareToken != shared.ShareToken || got.Owner != "a***@example.com" ||
		got.IsOwner || got.LikeCount != 1 || !got.Liked || got.TrackCount != 1 {
		t.Fatalf("listed = %+v", got)
	}
	for _, bad := range []string{"0", "-1", "x"} {
		if response := call(http.MethodGet, "/api/v1/public-playlists?limit="+bad, bob, ""); response.Code != http.StatusBadRequest {
			t.Fatalf("limit %q = %d", bad, response.Code)
		}
	}
	if response := call(http.MethodGet, "/api/v1/public-playlists", "", ""); response.Code != http.StatusUnauthorized {
		t.Fatalf("listing signed out = %d", response.Code)
	}

	for range 2 {
		response := call(http.MethodDelete, like, bob, "")
		if response.Code != http.StatusOK || strings.TrimSpace(response.Body.String()) != `{"liked":false,"likeCount":0}` {
			t.Fatalf("unlike = %d %s", response.Code, response.Body)
		}
	}
	call(http.MethodDelete, "/api/v1/playlists/p1/share", alice, "")
	if response := call(http.MethodPut, like, bob, ""); response.Code != http.StatusNotFound {
		t.Fatalf("liking a revoked link = %d", response.Code)
	}
	if response := call(http.MethodPut, "/api/v1/shared-playlists/not-a-token/like", bob, ""); response.Code != http.StatusNotFound {
		t.Fatalf("malformed link = %d", response.Code)
	}
}

func TestVisitorsWithoutAnAccountSeeOnlyPublicPlaylists(t *testing.T) {
	tokens, _ := auth.NewTokens([]byte(strings.Repeat("k", auth.MinSecretBytes)), time.Hour)
	bob, _, _ := tokens.Issue("bob")
	token := strings.Repeat("A", 22)
	data := &sharingStore{token: &token, tracks: []store.Track{{ID: "t1", Title: "in", StorageKey: "users/alice/tracks/t1/a.mp3"}}}
	limits := AnonymousLimits{
		View:   NewRateLimiter(RateLimit{Requests: 5, Window: time.Hour}, 100),
		Stream: NewRateLimiter(RateLimit{Requests: 2, Window: time.Hour}, 100),
	}
	handler := NewHandler(Config{Playlists: NewPlaylistHandlers(data, tokens).
		WithSharing(data, fixedPresigner{}, SavePolicy{}).WithAnonymous(limits)})
	call := func(path, bearer, ip string) *httptest.ResponseRecorder {
		request := httptest.NewRequest(http.MethodGet, path, nil)
		if bearer != "" {
			request.Header.Set("Authorization", "Bearer "+bearer)
		}
		request.RemoteAddr = ip + ":1234"
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		return response
	}
	view := "/api/v1/shared-playlists/" + token
	stream := view + "/tracks/t1/stream"

	// Link-only: still needs an account.
	for _, path := range []string{view, stream} {
		if response := call(path, "", "198.51.100.1"); response.Code != http.StatusNotFound {
			t.Fatalf("anonymous %s of a link-only playlist = %d", path, response.Code)
		}
	}
	if response := call(view, bob, "198.51.100.1"); response.Code != http.StatusOK {
		t.Fatalf("signed-in view of a link-only playlist = %d", response.Code)
	}

	data.public = true
	response := call(view, "", "198.51.100.2")
	var shown sharedPlaylistResponse
	json.NewDecoder(response.Body).Decode(&shown)
	if response.Code != http.StatusOK || shown.IsOwner || shown.Liked || shown.TrackCount != 1 ||
		strings.Contains(response.Body.String(), "alice@") {
		t.Fatalf("anonymous view of a public playlist = %d %s", response.Code, response.Body)
	}
	if response := call(stream, "", "198.51.100.2"); response.Code != http.StatusOK {
		t.Fatalf("anonymous stream of a public playlist = %d", response.Code)
	}
	if response := call("/api/v1/public-playlists", "", "198.51.100.2"); response.Code != http.StatusOK ||
		!strings.Contains(response.Body.String(), `"liked":false`) {
		t.Fatalf("anonymous popular list = %d %s", response.Code, response.Body)
	}
	// A token that doesn't verify is not treated as anonymous.
	if response := call(view, "expired", "198.51.100.2"); response.Code != http.StatusUnauthorized {
		t.Fatalf("bad token = %d", response.Code)
	}
	// Liking and saving still need an account.
	request := httptest.NewRequest(http.MethodPut, view+"/like", nil)
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusUnauthorized {
		t.Fatalf("anonymous like = %d", recorder.Code)
	}

	// Each IP gets its own allowance; signed-in people are not limited.
	call(stream, "", "198.51.100.3")
	call(stream, "", "198.51.100.3")
	limited := call(stream, "", "198.51.100.3")
	if limited.Code != http.StatusTooManyRequests || limited.Header().Get("Retry-After") == "" {
		t.Fatalf("third anonymous stream = %d", limited.Code)
	}
	if response := call(stream, "", "198.51.100.4"); response.Code != http.StatusOK {
		t.Fatalf("another visitor = %d", response.Code)
	}
	for range 3 {
		if response := call(stream, bob, "198.51.100.3"); response.Code != http.StatusOK {
			t.Fatalf("signed-in stream from a limited IP = %d", response.Code)
		}
	}

	// Unshared: gone for everyone.
	data.token, data.public = nil, false
	if response := call(view, "", "198.51.100.5"); response.Code != http.StatusNotFound {
		t.Fatalf("anonymous view after unsharing = %d", response.Code)
	}
}

func TestWithoutAnonymousAccessEverythingNeedsAnAccount(t *testing.T) {
	tokens, _ := auth.NewTokens([]byte(strings.Repeat("k", auth.MinSecretBytes)), time.Hour)
	token := strings.Repeat("A", 22)
	data := &sharingStore{token: &token, public: true}
	handler := NewHandler(Config{Playlists: NewPlaylistHandlers(data, tokens).WithSharing(data, fixedPresigner{}, SavePolicy{})})
	for _, path := range []string{"/api/v1/public-playlists", "/api/v1/shared-playlists/" + token} {
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, httptest.NewRequest(http.MethodGet, path, nil))
		if response.Code != http.StatusUnauthorized {
			t.Fatalf("%s = %d", path, response.Code)
		}
	}
}
