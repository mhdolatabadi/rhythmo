package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/mhdolatabadi/rhythmo/server/internal/auth"
	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

func TestSubscribingToPublicPlaylistsAPI(t *testing.T) {
	pool := collabTestPool(t)
	ctx := context.Background()
	users := store.NewUsers(pool)
	tracks := store.NewTracks(pool)
	playlists := store.NewPlaylists(pool)
	tokens, _ := auth.NewTokens([]byte(strings.Repeat("k", auth.MinSecretBytes)), time.Hour)
	handler := NewHandler(Config{Playlists: NewPlaylistHandlers(playlists, tokens).
		WithSharing(playlists, fixedPresigner{}, SavePolicy{}).
		WithSubscriptions(playlists, store.NewNotifications(pool))})

	owner, _ := users.Create(ctx, "owner@example.com", "hash")
	fan, _ := users.Create(ctx, "fan@example.com", "hash")
	ownerToken, _, _ := tokens.Issue(owner.ID)
	fanToken, _, _ := tokens.Issue(fan.ID)
	song, _ := tracks.Create(ctx, owner.ID, store.NewTrack{Title: "New Song", FileName: "s.mp3", ContentType: "audio/mpeg", SizeBytes: 1})
	playlist, _ := playlists.Create(ctx, owner.ID, "channel")

	call := func(method, path, token string, body any) *httptest.ResponseRecorder {
		t.Helper()
		var reader *bytes.Reader
		if body != nil {
			encoded, _ := json.Marshal(body)
			reader = bytes.NewReader(encoded)
		} else {
			reader = bytes.NewReader(nil)
		}
		request := httptest.NewRequest(method, path, reader)
		if token != "" {
			request.Header.Set("Authorization", "Bearer "+token)
		}
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		return response
	}

	response := call(http.MethodPost, "/api/v1/playlists/"+playlist.ID+"/share", ownerToken, map[string]bool{"public": false})
	var shared shareResponse
	json.NewDecoder(response.Body).Decode(&shared)
	link := "/api/v1/shared-playlists/" + shared.ShareToken

	if response := call(http.MethodPut, link+"/subscription", "", nil); response.Code != http.StatusUnauthorized {
		t.Fatalf("subscribing signed out = %d", response.Code)
	}
	if response := call(http.MethodPut, link+"/subscription", fanToken, nil); response.Code != http.StatusNotFound {
		t.Fatalf("subscribing to a link-only playlist = %d", response.Code)
	}
	call(http.MethodPost, "/api/v1/playlists/"+playlist.ID+"/share", ownerToken, map[string]bool{"public": true})
	if response := call(http.MethodPut, link+"/subscription", ownerToken, nil); response.Code != http.StatusConflict {
		t.Fatalf("owner subscribing = %d", response.Code)
	}
	response = call(http.MethodPut, link+"/subscription", fanToken, nil)
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), `"subscribed":true,"subscriberCount":1`) {
		t.Fatalf("subscribe = %d %s", response.Code, response.Body)
	}

	call(http.MethodPut, "/api/v1/playlists/"+playlist.ID+"/tracks", ownerToken, map[string][]string{"trackIds": {song.ID}})

	response = call(http.MethodGet, "/api/v1/notifications/unread-count", fanToken, nil)
	if !strings.Contains(response.Body.String(), `"unreadCount":1`) {
		t.Fatalf("unread count = %s", response.Body)
	}
	response = call(http.MethodGet, "/api/v1/notifications", fanToken, nil)
	var inbox struct {
		Notifications []notificationResponse `json:"notifications"`
		UnreadCount   int                    `json:"unreadCount"`
	}
	json.NewDecoder(response.Body).Decode(&inbox)
	if len(inbox.Notifications) != 1 || inbox.UnreadCount != 1 || inbox.Notifications[0].ShareToken != shared.ShareToken ||
		*inbox.Notifications[0].TrackTitle != "New Song" || inbox.Notifications[0].PlaylistName != "channel" {
		t.Fatalf("inbox = %+v", inbox)
	}
	response = call(http.MethodGet, "/api/v1/subscriptions", fanToken, nil)
	if !strings.Contains(response.Body.String(), `"unreadCount":1`) || !strings.Contains(response.Body.String(), `"name":"channel"`) {
		t.Fatalf("subscriptions = %s", response.Body)
	}

	// Opening the playlist reads its notice.
	response = call(http.MethodGet, link, fanToken, nil)
	if !strings.Contains(response.Body.String(), `"subscribed":true,"subscriberCount":1`) {
		t.Fatalf("playlist view = %s", response.Body)
	}
	if response := call(http.MethodGet, "/api/v1/notifications/unread-count", fanToken, nil); !strings.Contains(response.Body.String(), `"unreadCount":0`) {
		t.Fatalf("unread after opening = %s", response.Body)
	}

	if response := call(http.MethodPost, "/api/v1/notifications/read", fanToken, map[string][]string{"ids": {"nope"}}); response.Code != http.StatusBadRequest {
		t.Fatalf("bad ids = %d", response.Code)
	}
	if response := call(http.MethodPost, "/api/v1/notifications/read", fanToken, nil); response.Code != http.StatusNoContent {
		t.Fatalf("mark all read = %d", response.Code)
	}

	// Muting keeps the notice in the inbox but out of the badge (#428).
	if response := call(http.MethodPut, link+"/subscription/mute", ownerToken, nil); response.Code != http.StatusNotFound {
		t.Fatalf("muting without a subscription = %d", response.Code)
	}
	response = call(http.MethodPut, link+"/subscription/mute", fanToken, nil)
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), `"subscriberCount":1,"muted":true`) {
		t.Fatalf("mute = %d %s", response.Code, response.Body)
	}
	other, _ := tracks.Create(ctx, owner.ID, store.NewTrack{Title: "Quiet Song", FileName: "q.mp3", ContentType: "audio/mpeg", SizeBytes: 1})
	call(http.MethodPut, "/api/v1/playlists/"+playlist.ID+"/tracks", ownerToken, map[string][]string{"trackIds": {song.ID, other.ID}})
	if response := call(http.MethodGet, "/api/v1/notifications/unread-count", fanToken, nil); !strings.Contains(response.Body.String(), `"unreadCount":0`) {
		t.Fatalf("unread while muted = %s", response.Body)
	}
	if response := call(http.MethodGet, "/api/v1/notifications", fanToken, nil); !strings.Contains(response.Body.String(), "Quiet Song") {
		t.Fatalf("inbox while muted = %s", response.Body)
	}
	if response := call(http.MethodGet, "/api/v1/subscriptions", fanToken, nil); !strings.Contains(response.Body.String(), `"muted":true`) {
		t.Fatalf("subscriptions while muted = %s", response.Body)
	}
	response = call(http.MethodDelete, link+"/subscription/mute", fanToken, nil)
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), `"muted":false`) {
		t.Fatalf("unmute = %d %s", response.Code, response.Body)
	}
	if response := call(http.MethodGet, "/api/v1/notifications/unread-count", fanToken, nil); !strings.Contains(response.Body.String(), `"unreadCount":1`) {
		t.Fatalf("unread after unmuting = %s", response.Body)
	}

	response = call(http.MethodDelete, link+"/subscription", fanToken, nil)
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), `"subscribed":false,"subscriberCount":0`) {
		t.Fatalf("unsubscribe = %d %s", response.Code, response.Body)
	}
}
