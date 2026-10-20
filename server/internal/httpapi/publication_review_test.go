package httpapi

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/mhdolatabadi/rhythmo/server/internal/auth"
	"github.com/mhdolatabadi/rhythmo/server/internal/store"
	"golang.org/x/crypto/bcrypt"
)

// publishAPI serves sharing and track publishing for "alice" behind the
// publish gate (#322), with alice's account in api.users.
func publishAPI(t *testing.T) (testAPI, *AuthHandlers, *sharingStore, *fakePublisher, string) {
	t.Helper()
	api := newTestAPI(t)
	api.users.users["alice"] = store.User{ID: "alice", Email: "alice@example.com"}
	handlers, err := NewAuthHandlers(api.users, auth.Passwords{Cost: bcrypt.MinCost}, api.tokens, AuthRateLimiters{})
	if err != nil {
		t.Fatal(err)
	}
	data := &sharingStore{}
	publisher := &fakePublisher{published: map[string]bool{}}
	gate := handlers.PublishGate()
	rate := NewRateLimiter(RateLimit{Requests: 100, Window: time.Hour}, 100)
	api.handler = NewHandler(Config{
		Auth: handlers,
		Playlists: NewPlaylistHandlers(data, api.tokens).
			WithSharing(data, fixedPresigner{}, SavePolicy{}).WithPublishGate(gate),
		Likes: NewLikeHandlers(&fakeLikes{own: map[string]string{}, liked: map[string]bool{}, listed: map[string]bool{}},
			publisher, api.tokens, rate).WithPublishGate(gate),
	})
	alice, _, _ := api.tokens.Issue("alice")
	return api, handlers, data, publisher, alice
}

func TestUnverifiedOwnersOnlyAskToPublish(t *testing.T) {
	api, _, data, publisher, alice := publishAPI(t)

	shared := decode[shareResponse](t, api.do(t, "POST", "/api/v1/playlists/p1/share", `{"public":true}`, alice))
	if shared.Public || shared.PublicReview == nil || *shared.PublicReview != store.ReviewPending || data.public {
		t.Fatalf("unverified public share = %+v", shared)
	}
	// Link-only sharing needs no review and withdraws the request.
	shared = decode[shareResponse](t, api.do(t, "POST", "/api/v1/playlists/p1/share", `{"public":false}`, alice))
	if shared.Public || shared.PublicReview != nil {
		t.Fatalf("link-only share = %+v", shared)
	}

	published := decode[publishResponse](t, api.do(t, "PUT", "/api/v1/tracks/t1/published", "", alice))
	if published.Published || published.Review == nil || *published.Review != store.ReviewPending || publisher.direct {
		t.Fatalf("unverified publish = %+v", published)
	}
	// Unpublishing never needs the gate.
	if response := api.do(t, "DELETE", "/api/v1/tracks/t1/published", "", alice); response.Code != http.StatusOK || !publisher.direct {
		t.Fatalf("unpublish = %d direct=%v", response.Code, publisher.direct)
	}
}

func TestVerifiedOwnersAndAdminsPublishDirectly(t *testing.T) {
	api, handlers, data, publisher, alice := publishAPI(t)
	user := api.users.users["alice"]
	user.Verified = true
	api.users.users["alice"] = user

	shared := decode[shareResponse](t, api.do(t, "POST", "/api/v1/playlists/p1/share", `{"public":true}`, alice))
	if !shared.Public || shared.PublicReview != nil || !data.public {
		t.Fatalf("verified public share = %+v", shared)
	}
	published := decode[publishResponse](t, api.do(t, "PUT", "/api/v1/tracks/t1/published", "", alice))
	if !published.Published || published.Review != nil || !publisher.direct {
		t.Fatalf("verified publish = %+v", published)
	}

	// An admin (with a verified email) publishes directly too.
	user.Verified = false
	now := time.Now()
	user.EmailVerifiedAt = &now
	api.users.users["alice"] = user
	handlers.WithAdmins([]string{"alice@example.com"})
	publisher.published = map[string]bool{}
	published = decode[publishResponse](t, api.do(t, "PUT", "/api/v1/tracks/t1/published", "", alice))
	if !published.Published || !publisher.direct {
		t.Fatalf("admin publish = %+v", published)
	}

	// A deleted account can't publish.
	delete(api.users.users, "alice")
	expectError(t, api.do(t, "PUT", "/api/v1/tracks/t1/published", "", alice), http.StatusUnauthorized, "unauthorized")
}

type fakePublications struct {
	pending  []store.PendingPublication
	decided  map[string]bool
	actor    string
	calls    int
	presence map[string]bool
}

func (f *fakePublications) Pending(context.Context, int) ([]store.PendingPublication, error) {
	f.calls++
	return f.pending, nil
}

func (f *fakePublications) PendingTrack(_ context.Context, id string) (store.Track, error) {
	f.calls++
	if !f.presence["track|"+id] {
		return store.Track{}, store.ErrNotPending
	}
	return store.Track{ID: id, StorageKey: "users/bob/tracks/" + id + "/a.mp3"}, nil
}

func (f *fakePublications) review(kind, id, actor string, approve bool) error {
	f.calls++
	if !f.presence[kind+"|"+id] {
		return store.ErrNotPending
	}
	delete(f.presence, kind+"|"+id)
	f.decided[kind+"|"+id], f.actor = approve, actor
	return nil
}

func (f *fakePublications) ReviewPlaylist(_ context.Context, id, actor string, approve bool) error {
	return f.review(store.PublicationPlaylist, id, actor, approve)
}

func (f *fakePublications) ReviewTrack(_ context.Context, id, actor string, approve bool) error {
	return f.review(store.PublicationTrack, id, actor, approve)
}

func TestAdminReviewsPublications(t *testing.T) {
	api := newTestAPI(t)
	admin, _ := api.users.Create(context.Background(), "admin@example.com", "hash")
	member, _ := api.users.Create(context.Background(), "member@example.com", "hash")
	adminToken, _, _ := api.tokens.Issue(admin.ID)
	memberToken, _, _ := api.tokens.Issue(member.ID)
	handlers, err := NewAuthHandlers(api.users, auth.Passwords{Cost: bcrypt.MinCost}, api.tokens, AuthRateLimiters{})
	if err != nil {
		t.Fatal(err)
	}
	handlers.WithAdmins([]string{admin.Email})
	token := "share-token"
	publications := &fakePublications{
		pending: []store.PendingPublication{
			{Kind: store.PublicationPlaylist, ID: "p1", Title: "mix", ShareToken: &token, TrackCount: 3, OwnerID: member.ID, OwnerEmail: member.Email},
			{Kind: store.PublicationTrack, ID: "t1", Title: "song", Artist: "someone", OwnerID: member.ID, OwnerEmail: member.Email},
		},
		decided:  map[string]bool{},
		presence: map[string]bool{"playlist|p1": true, "track|t1": true},
	}
	api.handler = NewHandler(Config{Auth: handlers,
		Admin: NewAdminHandlers(handlers, &fakeAdminStore{}).WithPublications(publications, fixedPresigner{})})

	for _, c := range []struct{ method, path, body string }{
		{"GET", "/api/v1/admin/publications", ""},
		{"PATCH", "/api/v1/admin/publications/playlists/p1", `{"approved":true}`},
		{"PATCH", "/api/v1/admin/publications/tracks/t1", `{"approved":true}`},
		{"GET", "/api/v1/admin/publications/tracks/t1/stream", ""},
	} {
		expectError(t, api.do(t, c.method, c.path, c.body, ""), http.StatusUnauthorized, "unauthorized")
		expectError(t, api.do(t, c.method, c.path, c.body, memberToken), http.StatusForbidden, "admin_required")
	}
	if publications.calls != 0 {
		t.Fatal("a non-admin reached the review queue")
	}

	list := decode[struct {
		Publications []pendingPublicationResponse `json:"publications"`
	}](t, api.do(t, "GET", "/api/v1/admin/publications", "", adminToken))
	if len(list.Publications) != 2 || list.Publications[0].ShareToken == nil || list.Publications[1].Artist != "someone" {
		t.Fatalf("queue = %+v", list)
	}
	stream := api.do(t, "GET", "/api/v1/admin/publications/tracks/t1/stream", "", adminToken)
	if stream.Code != http.StatusOK || !strings.Contains(stream.Body.String(), "users/bob/tracks/t1") {
		t.Fatalf("stream pending = %d %s", stream.Code, stream.Body)
	}
	expectError(t, api.do(t, "GET", "/api/v1/admin/publications/tracks/t9/stream", "", adminToken), http.StatusNotFound, "not_found")

	for _, body := range []string{`{}`, `{"approved":null}`, `{"approved":true,"extra":1}`, `{"approved":true} {}`} {
		expectError(t, api.do(t, "PATCH", "/api/v1/admin/publications/playlists/p1", body, adminToken), http.StatusBadRequest, "invalid_json")
	}
	if response := api.do(t, "PATCH", "/api/v1/admin/publications/playlists/p1", `{"approved":true}`, adminToken); response.Code != http.StatusOK {
		t.Fatalf("approve playlist = %d %s", response.Code, response.Body)
	}
	if !publications.decided["playlist|p1"] || publications.actor != admin.ID {
		t.Fatalf("approval not recorded: %+v", publications)
	}
	if response := api.do(t, "PATCH", "/api/v1/admin/publications/tracks/t1", `{"approved":false}`, adminToken); response.Code != http.StatusOK {
		t.Fatalf("reject track = %d %s", response.Code, response.Body)
	}
	if decision, ok := publications.decided["track|t1"]; !ok || decision {
		t.Fatalf("rejection not recorded: %+v", publications.decided)
	}
	// A request decided already, or by someone else first, is not pending.
	expectError(t, api.do(t, "PATCH", "/api/v1/admin/publications/playlists/p1", `{"approved":false}`, adminToken), http.StatusConflict, "not_pending")
	expectError(t, api.do(t, "PATCH", "/api/v1/admin/publications/tracks/t1", `{"approved":true}`, adminToken), http.StatusConflict, "not_pending")
}
