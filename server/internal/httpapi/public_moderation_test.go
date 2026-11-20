package httpapi

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/bcrypt"

	"github.com/mhdolatabadi/rhythmo/server/internal/auth"
	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

// moderationAPI wires real users and playlists with the publish gate.
func moderationAPI(t *testing.T) (testAPI, *store.Users, *store.Playlists) {
	t.Helper()
	pool := collabTestPool(t)
	users, playlists := store.NewUsers(pool), store.NewPlaylists(pool)
	tokens, err := auth.NewTokens([]byte(strings.Repeat("k", auth.MinSecretBytes)), time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	handlers, err := NewAuthHandlers(users, auth.Passwords{Cost: bcrypt.MinCost}, tokens, AuthRateLimiters{})
	if err != nil {
		t.Fatal(err)
	}
	handler := NewHandler(Config{Auth: handlers, Playlists: NewPlaylistHandlers(playlists, tokens).
		WithSharing(playlists, fixedPresigner{}, SavePolicy{}).WithPublishGate(handlers.PublishGate())})
	return testAPI{handler: handler, tokens: tokens}, users, playlists
}

func TestOffensivePlaylistsAreNotListed(t *testing.T) {
	api, users, playlists := moderationAPI(t)
	ctx := context.Background()
	owner, _ := users.Create(ctx, "owner@example.com", "hash")
	token, _, _ := api.tokens.Issue(owner.ID)
	bad, _ := playlists.Create(ctx, owner.ID, "ک.ی.ر")
	expectError(t, api.do(t, http.MethodPost, "/api/v1/playlists/"+bad.ID+"/share", `{"public":true}`, token),
		http.StatusUnprocessableEntity, "inappropriate_content")
	// A link alone is still fine.
	if code := api.do(t, http.MethodPost, "/api/v1/playlists/"+bad.ID+"/share", `{"public":false}`, token).Code; code != http.StatusOK {
		t.Fatalf("link-only share = %d", code)
	}
	// A private playlist may be named anything; a listed one may not.
	good, _ := playlists.Create(ctx, owner.ID, "شب")
	if code := api.do(t, http.MethodPut, "/api/v1/playlists/"+good.ID, `{"name":"FUUUCK"}`, token).Code; code != http.StatusOK {
		t.Fatalf("private rename = %d", code)
	}
	api.do(t, http.MethodPut, "/api/v1/playlists/"+good.ID, `{"name":"شب"}`, token)
	shared := decode[shareResponse](t, api.do(t, http.MethodPost, "/api/v1/playlists/"+good.ID+"/share", `{"public":true}`, token))
	if shared.PublicReview == nil || *shared.PublicReview != store.ReviewPending {
		t.Fatalf("share = %+v", shared)
	}
	expectError(t, api.do(t, http.MethodPut, "/api/v1/playlists/"+good.ID, `{"name":"FUUUCK"}`, token),
		http.StatusUnprocessableEntity, "inappropriate_content")
}

func TestRenamingAPublicPlaylistSendsItBackToReview(t *testing.T) {
	api, users, playlists := moderationAPI(t)
	ctx := context.Background()
	owner, _ := users.Create(ctx, "owner@example.com", "hash")
	token, _, _ := api.tokens.Issue(owner.ID)
	playlist, _ := playlists.Create(ctx, owner.ID, "شب")
	yes := true
	// As if an admin approved it earlier.
	if _, err := playlists.Share(ctx, owner.ID, playlist.ID, "public-token", &yes, true); err != nil {
		t.Fatal(err)
	}
	response := api.do(t, http.MethodPut, "/api/v1/playlists/"+playlist.ID, `{"name":"شب‌های تهران"}`, token)
	renamed := decode[playlistResponse](t, response)
	if response.Code != http.StatusOK || renamed.Public || renamed.PublicReview == nil || *renamed.PublicReview != store.ReviewPending {
		t.Fatalf("rename = %d %s", response.Code, response.Body)
	}
	listed, _ := playlists.Popular(ctx, "", 10)
	if len(listed) != 0 {
		t.Fatalf("a renamed playlist stayed listed: %+v", listed)
	}
}
