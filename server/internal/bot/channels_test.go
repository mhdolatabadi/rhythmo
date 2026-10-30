package bot

import (
	"context"
	"testing"
)

// channelHarness is a harness whose bot syncs channels, with u1 running
// playlist p1.
func channelHarness(t *testing.T) (*harness, *fakePlaylists) {
	t.Helper()
	h := newHarness(t)
	h.store.managers["p1"] = map[string]bool{"u1": true}
	playlists := &fakePlaylists{names: map[string]string{"p1": "طلایی‌ها"}}
	h.service.WithChannels(h.store, playlists)
	return h, playlists
}

func (h *harness) post(u Update) string {
	h.t.Helper()
	u.ChatID, u.Channel, u.ChatTitle = "-1001", true, "Golden oldies"
	before := len(h.provider.messages)
	h.send(u)
	if len(h.provider.messages) == before {
		return ""
	}
	return h.provider.last()
}

func (h *harness) channelCode() string {
	h.t.Helper()
	code, _, err := h.linker.NewChannelCode(context.Background(), "u1", "p1")
	if err != nil {
		h.t.Fatal(err)
	}
	return code
}

func TestChannelPostsSyncIntoARhythmoChannel(t *testing.T) {
	h, playlists := channelHarness(t)

	// Before linking, chatter and audio are ignored without a word.
	if reply := h.post(Update{Text: "hello"}); reply != "" {
		t.Fatalf("unlinked chatter = %q", reply)
	}
	if reply := h.post(Update{File: &File{ID: "song", Name: "a.mp3", SizeBytes: int64(len(song))}}); reply != "" || len(h.tracks.tracks) != 0 {
		t.Fatalf("unlinked audio = %q, %d tracks", reply, len(h.tracks.tracks))
	}
	if reply := h.post(Update{Text: "12345678"}); reply != msgChannelBadCode {
		t.Fatalf("wrong code = %q", reply)
	}
	// A private-chat code doesn't link a channel.
	if reply := h.post(Update{Text: h.code()}); reply != msgChannelBadCode {
		t.Fatalf("private code in a channel = %q", reply)
	}
	if reply := h.post(Update{Text: "/connect " + h.channelCode()}); reply != msgChannelLinked("طلایی‌ها") {
		t.Fatalf("link = %q", reply)
	}
	if link := h.store.channels["bale/-1001"]; link.PlaylistID != "p1" || link.UserID != "u1" || link.Title != "Golden oldies" {
		t.Fatalf("link = %+v", link)
	}

	// Audio is imported for the person who linked it and added to p1,
	// silently.
	if reply := h.post(Update{File: &File{ID: "song", Name: "a.mp3", SizeBytes: int64(len(song)), Title: "گل پامچال"}}); reply != "" {
		t.Fatalf("synced post answered %q", reply)
	}
	if len(h.tracks.tracks) != 1 || len(playlists.appended) != 1 {
		t.Fatalf("tracks = %+v, appended = %v", h.tracks.tracks, playlists.appended)
	}
	for id, track := range h.tracks.tracks {
		if track.OwnerID != "u1" || playlists.appended[0] != "u1 p1 "+id {
			t.Fatalf("track = %+v, appended = %v", track, playlists.appended)
		}
	}
	// Text posts and refused files say nothing either.
	if reply := h.post(Update{Text: "new week, new songs"}); reply != "" {
		t.Fatalf("synced chatter = %q", reply)
	}
	if reply := h.post(Update{File: &File{ID: "doc", Name: "notes.pdf", SizeBytes: 10}}); reply != "" || len(playlists.appended) != 1 {
		t.Fatalf("synced pdf = %q", reply)
	}

	if reply := h.post(Update{Text: "/disconnect"}); reply != msgChannelUnlinked {
		t.Fatalf("/disconnect = %q", reply)
	}
	h.post(Update{File: &File{ID: "song", Name: "b.mp3", SizeBytes: int64(len(song))}})
	if len(playlists.appended) != 1 {
		t.Fatalf("posted after disconnecting: %v", playlists.appended)
	}
}

func TestAChannelStopsSyncingWhenItsAdminLeaves(t *testing.T) {
	h, playlists := channelHarness(t)
	h.post(Update{Text: h.channelCode()})
	if _, ok := h.store.channels["bale/-1001"]; !ok {
		t.Fatal("not linked")
	}
	h.store.managers["p1"]["u1"] = false
	h.post(Update{File: &File{ID: "song", Name: "a.mp3", SizeBytes: int64(len(song))}})
	if len(playlists.appended) != 0 || len(h.tracks.tracks) != 0 {
		t.Fatalf("synced for someone who no longer runs it: %v", playlists.appended)
	}
	if _, ok := h.store.channels["bale/-1001"]; ok {
		t.Fatal("stale link kept")
	}
}

func TestOnlyPeopleWhoRunAPlaylistGetChannelCodes(t *testing.T) {
	h, _ := channelHarness(t)
	if _, _, err := h.linker.NewChannelCode(context.Background(), "u2", "p1"); err == nil {
		t.Fatal("a stranger got a channel code")
	}
	code := h.channelCode()
	h.store.managers["p1"]["u1"] = false
	if reply := h.post(Update{Text: code}); reply != msgChannelNotAdmin {
		t.Fatalf("code of someone who lost admin = %q", reply)
	}
}

func TestChannelsAreIgnoredWithoutSync(t *testing.T) {
	h := newHarness(t)
	if reply := h.post(Update{Text: "/connect 12345678"}); reply != "" {
		t.Fatalf("channel without sync = %q", reply)
	}
}
