package store

import (
	"errors"
	"testing"
)

type profileFixture struct {
	catalogFixture
	profiles     *Profiles
	publications *Publications
	likes        *TrackLikes
}

func newProfileFixture(t *testing.T) profileFixture {
	f := newCatalogFixture(t)
	pool := f.catalog.pool
	return profileFixture{catalogFixture: f, profiles: NewProfiles(pool),
		publications: NewPublications(pool), likes: NewTrackLikes(pool)}
}

// publicUser makes an account with a visible profile under handle.
func (f profileFixture) publicUser(handle string) User {
	f.t.Helper()
	user := f.user(handle + "@example.com")
	if _, err := f.profiles.Update(f.ctx, user.ID, ProfileUpdate{Handle: handle, DisplayName: "نام " + handle, Public: true}, true); err != nil {
		f.t.Fatal(err)
	}
	return user
}

func TestProfileHandlesAndVisibility(t *testing.T) {
	f := newProfileFixture(t)
	alice := f.publicUser("alice")
	bob := f.user("bob@example.com")

	if _, err := f.profiles.Update(f.ctx, bob.ID, ProfileUpdate{Handle: "alice"}, true); !errors.Is(err, ErrHandleTaken) {
		t.Fatalf("taking alice's handle = %v", err)
	}
	if _, err := f.profiles.Update(f.ctx, bob.ID, ProfileUpdate{Public: true}, true); !errors.Is(err, ErrNoHandle) {
		t.Fatalf("public without a handle = %v", err)
	}
	if _, err := f.profiles.Update(f.ctx, bob.ID, ProfileUpdate{Handle: "Bad Handle"}, true); err == nil {
		t.Fatal("the database took an invalid handle")
	}

	// A private profile is seen only by its owner.
	if _, err := f.profiles.Update(f.ctx, bob.ID, ProfileUpdate{Handle: "bob", Bio: "سلام"}, true); err != nil {
		t.Fatal(err)
	}
	if _, err := f.profiles.ByHandle(f.ctx, "bob", ""); !errors.Is(err, ErrNotFound) {
		t.Fatalf("visitor sees a private profile: %v", err)
	}
	if own, err := f.profiles.ByHandle(f.ctx, "bob", bob.ID); err != nil || !own.IsViewer || own.Bio != "سلام" {
		t.Fatalf("own private profile = %+v, %v", own, err)
	}

	visible, err := f.profiles.ByHandle(f.ctx, "alice", "")
	if err != nil || visible.UserID != alice.ID || visible.DisplayName != "نام alice" {
		t.Fatalf("alice = %+v, %v", visible, err)
	}

	// An unverified owner's new public profile waits for an admin.
	mine, err := f.profiles.Update(f.ctx, bob.ID, ProfileUpdate{Handle: "bob", Bio: "سلام", Public: true}, false)
	if err != nil || mine.Review == nil || *mine.Review != ReviewPending {
		t.Fatalf("pending profile = %+v, %v", mine, err)
	}
	if _, err := f.profiles.ByHandle(f.ctx, "bob", ""); !errors.Is(err, ErrNotFound) {
		t.Fatal("a pending profile is visible")
	}
	pending, err := f.publications.Pending(f.ctx, 10)
	if err != nil || len(pending) != 1 || pending[0].Kind != PublicationProfile || pending[0].Handle != "bob" || pending[0].Bio != "سلام" {
		t.Fatalf("queue = %+v, %v", pending, err)
	}
	// Saving the same profile again keeps the request; approving shows it.
	if again, _ := f.profiles.Update(f.ctx, bob.ID, ProfileUpdate{Handle: "bob", Bio: "سلام", Public: true}, false); again.Review == nil {
		t.Fatal("saving again dropped the request")
	}
	if err := f.publications.ReviewProfile(f.ctx, bob.ID, alice.ID, true); err != nil {
		t.Fatal(err)
	}
	if _, err := f.profiles.ByHandle(f.ctx, "bob", ""); err != nil {
		t.Fatalf("approved profile: %v", err)
	}
	// Changing the bio sends it back for review; an unchanged save doesn't.
	if same, _ := f.profiles.Update(f.ctx, bob.ID, ProfileUpdate{Handle: "bob", Bio: "سلام", Public: true}, false); same.Review != nil {
		t.Fatal("an unchanged save asked for review")
	}
	if changed, _ := f.profiles.Update(f.ctx, bob.ID, ProfileUpdate{Handle: "bob", Bio: "تازه", Public: true}, false); changed.Review == nil {
		t.Fatal("a new bio skipped review")
	}
	if err := f.publications.ReviewProfile(f.ctx, bob.ID, alice.ID, false); err != nil {
		t.Fatal(err)
	}
	rejected, _ := f.profiles.Mine(f.ctx, bob.ID)
	if rejected.Public || rejected.Review == nil || *rejected.Review != ReviewRejected {
		t.Fatalf("rejected = %+v", rejected)
	}
}

func TestFollowBlockAndCounts(t *testing.T) {
	f := newProfileFixture(t)
	alice, bob := f.publicUser("alice"), f.publicUser("bob")
	carol := f.user("carol@example.com")

	if err := f.profiles.Follow(f.ctx, alice.ID, "alice"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("following oneself = %v", err)
	}
	for _, follower := range []User{alice, carol} {
		if err := f.profiles.Follow(f.ctx, follower.ID, "bob"); err != nil {
			t.Fatal(err)
		}
	}
	if err := f.profiles.Follow(f.ctx, carol.ID, "bob"); err != nil {
		t.Fatalf("following twice = %v", err)
	}
	seen, _ := f.profiles.ByHandle(f.ctx, "bob", alice.ID)
	if seen.Followers != 2 || !seen.FollowedByViewer {
		t.Fatalf("bob = %+v", seen)
	}
	if me, _ := f.profiles.Mine(f.ctx, alice.ID); me.Following != 1 {
		t.Fatalf("alice follows %d", me.Following)
	}

	// Blocking ends the follow both ways and hides the blocker.
	if err := f.profiles.Follow(f.ctx, bob.ID, "alice"); err != nil {
		t.Fatal(err)
	}
	if err := f.profiles.Block(f.ctx, bob.ID, "alice"); err != nil {
		t.Fatal(err)
	}
	if _, err := f.profiles.ByHandle(f.ctx, "bob", alice.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("blocked viewer sees the blocker: %v", err)
	}
	if err := f.profiles.Follow(f.ctx, alice.ID, "bob"); !errors.Is(err, ErrBlocked) {
		t.Fatalf("following a blocker = %v", err)
	}
	if blocked, _ := f.profiles.ByHandle(f.ctx, "alice", bob.ID); !blocked.BlockedByViewer || blocked.Followers != 0 {
		t.Fatalf("alice as bob sees her = %+v", blocked)
	}
	if list, _ := f.profiles.Blocked(f.ctx, bob.ID); len(list) != 1 || list[0].Handle != "alice" {
		t.Fatalf("blocked list = %+v", list)
	}
	if err := f.profiles.Unblock(f.ctx, bob.ID, "alice"); err != nil {
		t.Fatal(err)
	}
	if err := f.profiles.Follow(f.ctx, alice.ID, "bob"); err != nil {
		t.Fatalf("follow after unblock = %v", err)
	}
	if err := f.profiles.Unfollow(f.ctx, alice.ID, "bob"); err != nil {
		t.Fatal(err)
	}
	if after, _ := f.profiles.ByHandle(f.ctx, "bob", ""); after.Followers != 1 {
		t.Fatalf("followers after unfollow = %d", after.Followers)
	}
}

func TestFeedAndPrivacy(t *testing.T) {
	f := newProfileFixture(t)
	alice, bob := f.publicUser("alice"), f.publicUser("bob")
	viewer := f.user("viewer@example.com")
	for _, handle := range []string{"alice", "bob"} {
		if err := f.profiles.Follow(f.ctx, viewer.ID, handle); err != nil {
			t.Fatal(err)
		}
	}
	song := f.track(alice.ID, NewTrack{Title: "song"})
	f.playlist(alice.ID, true, song.ID)
	f.playlist(alice.ID, false) // link-only: not in the feed
	f.indexAll()
	if _, err := f.likes.SetOwnLike(f.ctx, bob.ID, song.ID, true); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 3; i++ {
		f.playlist(bob.ID, true)
	}

	page, err := f.profiles.Feed(f.ctx, viewer.ID, nil, 3)
	if err != nil || len(page) != 3 {
		t.Fatalf("first page = %+v, %v", page, err)
	}
	last := page[len(page)-1]
	rest, err := f.profiles.Feed(f.ctx, viewer.ID, &FeedCursor{At: last.At, Kind: last.Kind, ID: last.ID}, 10)
	if err != nil || len(rest) != 2 {
		t.Fatalf("second page = %+v, %v", rest, err)
	}
	kinds := map[string]int{}
	seen := map[string]bool{}
	for _, item := range append(page, rest...) {
		kinds[item.Kind]++
		if seen[item.Kind+item.ID] {
			t.Fatalf("%s %s on two pages", item.Kind, item.ID)
		}
		seen[item.Kind+item.ID] = true
	}
	if kinds["playlist"] != 4 || kinds["like"] != 1 {
		t.Fatalf("kinds = %v", kinds)
	}

	// Hiding activity takes bob out; blocking takes alice out.
	if _, err := f.profiles.Update(f.ctx, bob.ID, ProfileUpdate{Handle: "bob", DisplayName: "نام bob", Public: true, HideActivity: true}, true); err != nil {
		t.Fatal(err)
	}
	if feed, _ := f.profiles.Feed(f.ctx, viewer.ID, nil, 10); len(feed) != 1 || feed[0].ActorHandle != "alice" {
		t.Fatalf("feed without bob = %+v", feed)
	}
	if _, err := f.profiles.Update(f.ctx, viewer.ID, ProfileUpdate{Handle: "viewer"}, true); err != nil {
		t.Fatal(err)
	}
	if err := f.profiles.Block(f.ctx, alice.ID, "viewer"); err != nil {
		t.Fatal(err)
	}
	if feed, _ := f.profiles.Feed(f.ctx, viewer.ID, nil, 10); len(feed) != 0 {
		t.Fatalf("feed after block = %+v", feed)
	}

	if lists, _ := f.profiles.Playlists(f.ctx, alice.ID, 10); len(lists) != 1 || lists[0].TrackCount != 1 {
		t.Fatalf("alice's playlists = %+v", lists)
	}
}

func TestProfileReportsAndDeletion(t *testing.T) {
	f := newProfileFixture(t)
	alice, bob := f.publicUser("alice"), f.publicUser("bob")
	admin := f.user("admin@example.com")
	if err := f.profiles.Report(f.ctx, bob.ID, "alice", "spam", nil); err != nil {
		t.Fatal(err)
	}
	if err := f.profiles.Report(f.ctx, bob.ID, "alice", "other", nil); !errors.Is(err, ErrAlreadyReported) {
		t.Fatalf("second open report = %v", err)
	}
	if err := f.profiles.Report(f.ctx, alice.ID, "alice", "spam", nil); !errors.Is(err, ErrNotFound) {
		t.Fatalf("reporting oneself = %v", err)
	}
	reports, err := f.profiles.OpenReports(f.ctx, 10)
	if err != nil || len(reports) != 1 || reports[0].ID != alice.ID || reports[0].Reports != 1 {
		t.Fatalf("reports = %+v, %v", reports, err)
	}
	if err := f.profiles.ResolveReports(f.ctx, alice.ID, admin.ID, true); err != nil {
		t.Fatal(err)
	}
	if _, err := f.profiles.ByHandle(f.ctx, "alice", ""); !errors.Is(err, ErrNotFound) {
		t.Fatal("a taken-down profile is still visible")
	}

	// Deleting an account removes its profile, follows and avatar.
	if err := f.profiles.Follow(f.ctx, alice.ID, "bob"); err != nil {
		t.Fatal(err)
	}
	if err := f.profiles.SetAvatar(f.ctx, alice.ID, "image/png", []byte{1, 2, 3}, true); err != nil {
		t.Fatal(err)
	}
	if _, err := f.users.Delete(f.ctx, alice.ID, 0); err != nil {
		t.Fatal(err)
	}
	if after, _ := f.profiles.ByHandle(f.ctx, "bob", ""); after.Followers != 0 {
		t.Fatalf("deleted follower still counted: %d", after.Followers)
	}
	var avatars int
	if err := f.catalog.pool.QueryRow(f.ctx, `SELECT count(*) FROM user_avatars`).Scan(&avatars); err != nil || avatars != 0 {
		t.Fatalf("avatars left = %d, %v", avatars, err)
	}
}

func TestPendingAvatarAndReview(t *testing.T) {
	f := newProfileFixture(t)
	bob := f.publicUser("bob")
	if err := f.profiles.SetAvatar(f.ctx, bob.ID, "image/png", []byte{9}, false); err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := f.profiles.Avatar(f.ctx, "bob", ""); !errors.Is(err, ErrNotFound) {
		t.Fatal("a pending avatar is public")
	}
	if kind, data, err := f.profiles.PendingAvatar(f.ctx, bob.ID); err != nil || kind != "image/png" || len(data) != 1 {
		t.Fatalf("pending avatar = %q %v %v", kind, data, err)
	}
	if _, _, _, err := f.profiles.Avatar(f.ctx, "bob", bob.ID); err != nil {
		t.Fatalf("owner can't see own avatar: %v", err)
	}
}
