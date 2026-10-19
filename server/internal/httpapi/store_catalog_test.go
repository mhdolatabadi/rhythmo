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
	"golang.org/x/crypto/bcrypt"
)

const storeEntryID = "11111111-1111-1111-1111-111111111111"

type fakeCatalog struct {
	artistAlbums    []store.StoreAlbum
	artistCountsErr error
	albumArtist     string
	albumOffset     int
	entry           store.StoreEntry
	hidden          bool
	owners          map[string]bool
	query           store.StoreQuery
	reports         []string
	hiddenBy        string
	plays           []string
	ranked          store.StoreRanking
}

func (c *fakeCatalog) RecordStorePlay(_ context.Context, entryID, listener string) error {
	c.plays = append(c.plays, entryID+"|"+listener)
	return nil
}

func (c *fakeCatalog) StoreRanked(_ context.Context, ranking store.StoreRanking, limit, offset int) ([]store.StoreEntry, bool, error) {
	c.ranked = ranking
	if c.hidden {
		return nil, false, nil
	}
	return []store.StoreEntry{c.entry}, false, nil
}

func (c *fakeCatalog) StoreEntries(_ context.Context, query store.StoreQuery) ([]store.StoreEntry, bool, error) {
	c.query = query
	if c.hidden {
		return nil, false, nil
	}
	return []store.StoreEntry{c.entry}, true, nil
}

func (c *fakeCatalog) StoreEntryByID(_ context.Context, id string, includeHidden bool) (store.StoreEntry, error) {
	if id != c.entry.ID || (c.hidden && !includeHidden) {
		return store.StoreEntry{}, store.ErrNotFound
	}
	return c.entry, nil
}

func (c *fakeCatalog) StoreArtists(_ context.Context, search string, limit, offset int) ([]store.StoreArtist, bool, error) {
	return []store.StoreArtist{{Name: "Kayhan", TrackCount: 2}}, false, nil
}

func (c *fakeCatalog) StoreArtistCounts(_ context.Context, artist string) (int, int, error) {
	if c.artistAlbums != nil {
		return 1, len(c.artistAlbums), c.artistCountsErr
	}
	return 1, 1, c.artistCountsErr
}

func (c *fakeCatalog) StoreAlbums(_ context.Context, search, artist string, limit, offset int) ([]store.StoreAlbum, bool, error) {
	c.albumArtist, c.albumOffset = artist, offset
	if c.artistAlbums != nil {
		if offset >= len(c.artistAlbums) {
			return nil, false, nil
		}
		end := offset + limit
		if end > len(c.artistAlbums) {
			end = len(c.artistAlbums)
		}
		return c.artistAlbums[offset:end], end < len(c.artistAlbums), nil
	}
	return []store.StoreAlbum{{Name: "Seasons", Artist: c.entry.Track.Artist, TrackCount: 1}}, false, nil
}

func (c *fakeCatalog) OwnsCopy(_ context.Context, entryID, userID string) (bool, error) {
	return c.owners[userID], nil
}

func (c *fakeCatalog) ReportEntry(_ context.Context, entryID, reporterID, reason string, details *string) error {
	if _, err := c.StoreEntryByID(context.Background(), entryID, false); err != nil {
		return err
	}
	c.reports = append(c.reports, reporterID+":"+reason)
	return nil
}

func (c *fakeCatalog) OpenReports(context.Context, int) ([]store.StoreReport, error) {
	return []store.StoreReport{{ID: 1, Entry: c.entry, Reason: "copyright", Reports: len(c.reports)}}, nil
}

func (c *fakeCatalog) SetHidden(_ context.Context, entryID, adminID string, hidden bool) error {
	if entryID != c.entry.ID {
		return store.ErrNotFound
	}
	c.hidden, c.hiddenBy = hidden, adminID
	return nil
}

type fakeCopier struct {
	copied []string
	quota  bool
}

func (c *fakeCopier) SaveTrackCopy(_ context.Context, userID string, original store.Track, _ int64, _ store.ObjectCopier) (store.Track, error) {
	if c.quota {
		return store.Track{}, store.ErrQuotaExceeded
	}
	c.copied = append(c.copied, userID+":"+original.ID)
	return store.Track{ID: "copy", OwnerID: userID, Title: original.Title, Status: store.TrackReady}, nil
}

type storeTestAPI struct {
	handler http.Handler
	catalog *fakeCatalog
	copier  *fakeCopier
	admin   string
	member  string
	// memberID is the member's user ID.
	memberID string
}

func newStoreTestAPI(t *testing.T, limits AnonymousLimits) storeTestAPI {
	t.Helper()
	api := newTestAPI(t)
	ctx := context.Background()
	admin, _ := api.users.Create(ctx, "admin@example.com", "hash")
	member, _ := api.users.Create(ctx, "member@example.com", "hash")
	adminToken, _, _ := api.tokens.Issue(admin.ID)
	memberToken, _, _ := api.tokens.Issue(member.ID)
	authHandlers, err := NewAuthHandlers(api.users, auth.Passwords{Cost: bcrypt.MinCost}, api.tokens, AuthRateLimiters{})
	if err != nil {
		t.Fatal(err)
	}
	authHandlers.WithAdmins([]string{"admin@example.com"})
	if limits.View == nil {
		limits = AnonymousLimits{
			View:   NewRateLimiter(RateLimit{Requests: 100, Window: time.Hour}, 100),
			Stream: NewRateLimiter(RateLimit{Requests: 100, Window: time.Hour}, 100),
		}
	}
	catalog := &fakeCatalog{owners: map[string]bool{}, entry: store.StoreEntry{
		ID: storeEntryID, Copies: 2,
		Track: store.Track{ID: "track-of-alice", OwnerID: "alice", Title: "Rain Song", Artist: str("Kayhan"),
			FileName: "alice-private-name.mp3", StorageKey: "users/alice/tracks/t/a.mp3", Comment: str("my note"),
			ContentType: "audio/mpeg", SizeBytes: 4000, Source: "upload"},
	}}
	copier := &fakeCopier{}
	handlers := NewCatalogHandlers(catalog, api.tokens, fixedPresigner{}, limits).
		WithSave(copier, SavePolicy{Objects: noCopies{}, MaxOwnerBytes: 1 << 30, Enabled: true}).
		WithReports(NewRateLimiter(RateLimit{Requests: 6, Window: time.Hour}, 100)).
		WithAdmin(NewAdminHandlers(authHandlers, &fakeAdminStore{}))
	return storeTestAPI{
		handler: NewHandler(Config{Auth: authHandlers, Store: handlers}),
		catalog: catalog, copier: copier, admin: adminToken, member: memberToken, memberID: member.ID,
	}
}

func str(s string) *string { return &s }

func (a storeTestAPI) call(method, path, body, bearer, ip string) *httptest.ResponseRecorder {
	request := httptest.NewRequest(method, path, strings.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	if bearer != "" {
		request.Header.Set("Authorization", "Bearer "+bearer)
	}
	request.RemoteAddr = ip + ":1234"
	response := httptest.NewRecorder()
	a.handler.ServeHTTP(response, request)
	return response
}

func TestStoreIsOpenWithoutAnAccountWithinLimits(t *testing.T) {
	api := newStoreTestAPI(t, AnonymousLimits{
		View:   NewRateLimiter(RateLimit{Requests: 3, Window: time.Hour}, 100),
		Stream: NewRateLimiter(RateLimit{Requests: 1, Window: time.Hour}, 100),
	})
	for _, path := range []string{"/api/v1/store/tracks?q=rain", "/api/v1/store/tracks/" + storeEntryID, "/api/v1/store/artists"} {
		if response := api.call("GET", path, "", "", "203.0.113.1"); response.Code != http.StatusOK {
			t.Fatalf("%s = %d %s", path, response.Code, response.Body)
		}
	}
	expectError(t, api.call("GET", "/api/v1/store/albums", "", "", "203.0.113.1"), http.StatusTooManyRequests, "rate_limited")
	if response := api.call("GET", "/api/v1/store/albums", "", "", "203.0.113.2"); response.Code != http.StatusOK {
		t.Fatalf("another visitor was limited: %d", response.Code)
	}
	// Signed-in listeners are not held to the per-IP visitor limit.
	if response := api.call("GET", "/api/v1/store/albums", "", api.member, "203.0.113.1"); response.Code != http.StatusOK {
		t.Fatalf("signed-in listener = %d", response.Code)
	}

	stream := "/api/v1/store/tracks/" + storeEntryID + "/stream"
	response := api.call("GET", stream, "", "", "203.0.113.1")
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), "users/alice/tracks/t/a.mp3") {
		t.Fatalf("stream = %d %s", response.Code, response.Body)
	}
	expectError(t, api.call("GET", stream, "", "", "203.0.113.1"), http.StatusTooManyRequests, "rate_limited")
	expectError(t, api.call("GET", "/api/v1/store/tracks/unknown/stream", "", api.member, "203.0.113.1"), http.StatusNotFound, "not_found")
	// A bad token is refused rather than treated as a visitor.
	expectError(t, api.call("GET", "/api/v1/store/tracks", "", "not-a-token", "203.0.113.9"), http.StatusUnauthorized, "unauthorized")
}

func TestStoreNeverShowsWhoseCopyItIs(t *testing.T) {
	api := newStoreTestAPI(t, AnonymousLimits{})
	for _, path := range []string{"/api/v1/store/tracks", "/api/v1/store/tracks/" + storeEntryID} {
		body := api.call("GET", path, "", "", "203.0.113.1").Body.String()
		for _, leak := range []string{"alice", "track-of-alice", "my note", "upload", "owner", "fileName"} {
			if strings.Contains(body, leak) {
				t.Errorf("%s shows %q: %s", path, leak, body)
			}
		}
		if !strings.Contains(body, storeEntryID) || !strings.Contains(body, "Rain Song") {
			t.Errorf("%s = %s", path, body)
		}
	}
	listed := decode[struct {
		Tracks  []storeTrackResponse `json:"tracks"`
		HasMore bool                 `json:"hasMore"`
	}](t, api.call("GET", "/api/v1/store/tracks?q=%20rain%20&artist=Kayhan&limit=500&offset=20", "", "", "203.0.113.1"))
	if len(listed.Tracks) != 1 || !listed.HasMore {
		t.Fatalf("listed = %+v", listed)
	}
	if q := api.catalog.query; q.Search != "rain" || q.Artist != "Kayhan" || q.Limit != maxStorePage || q.Offset != 20 {
		t.Fatalf("query = %+v", q)
	}
	for _, path := range []string{"/api/v1/store/tracks?limit=0", "/api/v1/store/tracks?offset=-1",
		"/api/v1/store/tracks?offset=99999", "/api/v1/store/tracks?q=" + strings.Repeat("a", 101)} {
		if response := api.call("GET", path, "", "", "203.0.113.1"); response.Code != http.StatusBadRequest {
			t.Errorf("%s = %d", path, response.Code)
		}
	}
}

func TestAddingAStoreSongToMyLibrary(t *testing.T) {
	api := newStoreTestAPI(t, AnonymousLimits{})
	save := "/api/v1/store/tracks/" + storeEntryID + "/save"
	expectError(t, api.call("POST", save, "", "", "203.0.113.1"), http.StatusUnauthorized, "unauthorized")
	response := api.call("POST", save, "", api.member, "203.0.113.1")
	if response.Code != http.StatusCreated || len(api.copier.copied) != 1 || !strings.HasSuffix(api.copier.copied[0], ":track-of-alice") {
		t.Fatalf("save = %d %s, copied %v", response.Code, response.Body, api.copier.copied)
	}
	expectError(t, api.call("POST", "/api/v1/store/tracks/unknown/save", "", api.member, "203.0.113.1"), http.StatusNotFound, "not_found")

	// Someone who already has a copy of the song is told so.
	api.catalog.owners[api.memberID] = true
	expectError(t, api.call("POST", save, "", api.member, "203.0.113.1"), http.StatusConflict, "already_yours")
	delete(api.catalog.owners, api.memberID)

	api.copier.quota = true
	expectError(t, api.call("POST", save, "", api.member, "203.0.113.1"), http.StatusRequestEntityTooLarge, "quota_exceeded")
}

func TestReportingAndHidingAStoreSong(t *testing.T) {
	api := newStoreTestAPI(t, AnonymousLimits{})
	report := "/api/v1/store/tracks/" + storeEntryID + "/report"
	expectError(t, api.call("POST", report, `{"reason":"copyright"}`, "", "203.0.113.1"), http.StatusUnauthorized, "unauthorized")
	for _, body := range []string{`{}`, `{"reason":"spam"}`, `{"reason":"other","extra":1}`,
		`{"reason":"other","details":"` + strings.Repeat("x", 1001) + `"}`} {
		expectError(t, api.call("POST", report, body, api.member, "203.0.113.1"), http.StatusBadRequest, "invalid_report")
	}
	if response := api.call("POST", report, `{"reason":"copyright","details":"  not theirs "}`, api.member, "203.0.113.1"); response.Code != http.StatusNoContent {
		t.Fatalf("report = %d %s", response.Code, response.Body)
	}
	// Every attempt counts against the account's report limit.
	if response := api.call("POST", report, `{"reason":"other"}`, api.member, "203.0.113.1"); response.Code != http.StatusNoContent {
		t.Fatalf("second report = %d", response.Code)
	}
	expectError(t, api.call("POST", report, `{"reason":"other"}`, api.member, "203.0.113.1"), http.StatusTooManyRequests, "rate_limited")
	expectError(t, api.call("POST", "/api/v1/store/tracks/unknown/report", `{"reason":"other"}`, api.admin, "203.0.113.1"), http.StatusNotFound, "not_found")

	reports, hide := "/api/v1/admin/store/reports", "/api/v1/admin/store/tracks/"+storeEntryID+"/hidden"
	for _, c := range []struct{ method, path string }{{"GET", reports}, {"PUT", hide}, {"DELETE", hide}} {
		expectError(t, api.call(c.method, c.path, "", "", "203.0.113.1"), http.StatusUnauthorized, "unauthorized")
		expectError(t, api.call(c.method, c.path, "", api.member, "203.0.113.1"), http.StatusForbidden, "admin_required")
	}
	listed := api.call("GET", reports, "", api.admin, "203.0.113.1")
	if listed.Code != http.StatusOK || !strings.Contains(listed.Body.String(), `"reports":2`) {
		t.Fatalf("reports = %d %s", listed.Code, listed.Body)
	}
	if response := api.call("PUT", hide, "", api.admin, "203.0.113.1"); response.Code != http.StatusNoContent || !api.catalog.hidden {
		t.Fatalf("hide = %d", response.Code)
	}
	expectError(t, api.call("GET", "/api/v1/store/tracks/"+storeEntryID, "", "", "203.0.113.1"), http.StatusNotFound, "not_found")
	expectError(t, api.call("GET", "/api/v1/store/tracks/"+storeEntryID+"/stream", "", api.member, "203.0.113.1"), http.StatusNotFound, "not_found")
	if response := api.call("DELETE", hide, "", api.admin, "203.0.113.1"); response.Code != http.StatusNoContent || api.catalog.hidden {
		t.Fatalf("unhide = %d", response.Code)
	}
	expectError(t, api.call("PUT", "/api/v1/admin/store/tracks/unknown/hidden", "", api.admin, "203.0.113.1"), http.StatusNotFound, "not_found")
}

func TestStoreStreamsCountPlaysWithoutKeepingAddresses(t *testing.T) {
	api := newStoreTestAPI(t, AnonymousLimits{})
	stream := "/api/v1/store/tracks/" + storeEntryID + "/stream"
	api.call("GET", stream, "", "", "203.0.113.1")
	api.call("GET", stream, "", "", "203.0.113.1")
	api.call("GET", stream, "", "", "203.0.113.2")
	api.call("GET", stream, "", api.member, "203.0.113.1")
	if len(api.catalog.plays) != 4 {
		t.Fatalf("plays = %v", api.catalog.plays)
	}
	first, again, other, member := api.catalog.plays[0], api.catalog.plays[1], api.catalog.plays[2], api.catalog.plays[3]
	if first != again || first == other || !strings.HasPrefix(first, storeEntryID+"|a:") {
		t.Fatalf("visitor keys = %q %q %q", first, again, other)
	}
	if strings.Contains(first, "203.0.113") {
		t.Fatalf("a visitor's address was kept: %q", first)
	}
	if member != storeEntryID+"|u:"+api.memberID {
		t.Fatalf("member key = %q", member)
	}
	// A song that left the store is not counted.
	api.catalog.hidden = true
	api.call("GET", stream, "", "", "203.0.113.3")
	if len(api.catalog.plays) != 4 {
		t.Fatalf("a hidden song's play was counted: %v", api.catalog.plays)
	}
}

func TestPopularAndTrendingAreOpenToEveryone(t *testing.T) {
	api := newStoreTestAPI(t, AnonymousLimits{})
	for path, ranking := range map[string]store.StoreRanking{
		"/api/v1/store/popular": store.RankPopular, "/api/v1/store/trending": store.RankTrending,
	} {
		response := api.call("GET", path+"?limit=10", "", "", "203.0.113.1")
		if response.Code != http.StatusOK || api.catalog.ranked != ranking ||
			!strings.Contains(response.Body.String(), storeEntryID) || strings.Contains(response.Body.String(), "alice") {
			t.Fatalf("%s = %d %s", path, response.Code, response.Body)
		}
		expectError(t, api.call("GET", path+"?limit=0", "", "", "203.0.113.1"), http.StatusBadRequest, "invalid_limit")
	}
}
