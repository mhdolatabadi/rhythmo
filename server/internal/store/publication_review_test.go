package store

import (
	"errors"
	"testing"
)

func TestUnverifiedPublishingWaitsForAnAdmin(t *testing.T) {
	f := newCatalogFixture(t)
	publications := NewPublications(f.catalog.pool)
	admin, alice := f.user("admin@example.com"), f.user("alice@example.com")
	artist := "alice"
	solo := f.track(alice.ID, NewTrack{Title: "solo", Artist: &artist})
	inPlaylist := f.track(alice.ID, NewTrack{Title: "in playlist"})
	playlist, err := f.playlists.Create(f.ctx, alice.ID, "mix")
	if err != nil {
		t.Fatal(err)
	}
	if err := f.playlists.ReplaceTracks(f.ctx, alice.ID, playlist.ID, []string{inPlaylist.ID}); err != nil {
		t.Fatal(err)
	}
	yes, no := true, false

	// Asking leaves both private, with a pending review, and lists nothing.
	shared, err := f.playlists.Share(f.ctx, alice.ID, playlist.ID, "review-token", &yes, false)
	if err != nil || shared.IsPublic || shared.PublicReview == nil || *shared.PublicReview != ReviewPending {
		t.Fatalf("ask to list = %+v, %v", shared, err)
	}
	asked, err := f.tracks.SetPublished(f.ctx, alice.ID, solo.ID, true, false)
	if err != nil || asked.PublishedAt != nil || asked.PublishReview == nil || *asked.PublishReview != ReviewPending {
		t.Fatalf("ask to publish = %+v, %v", asked, err)
	}
	f.indexAll()
	if got := titles(f.listed(StoreQuery{})); got != "" {
		t.Fatalf("pending content listed: %q", got)
	}
	if popular, _ := f.playlists.Popular(f.ctx, "", 10); len(popular) != 0 {
		t.Fatalf("pending playlist is popular: %+v", popular)
	}
	if _, err := f.playlists.SharedTrack(f.ctx, "review-token", inPlaylist.ID, true); !errors.Is(err, ErrNotFound) {
		t.Fatalf("visitors reach a pending playlist: %v", err)
	}

	pending, err := publications.Pending(f.ctx, 10)
	if err != nil || len(pending) != 2 {
		t.Fatalf("queue = %+v, %v", pending, err)
	}
	for _, item := range pending {
		if item.OwnerEmail != alice.Email {
			t.Fatalf("queue item %+v", item)
		}
		if item.Kind == PublicationPlaylist && (item.ID != playlist.ID || item.TrackCount != 1 || *item.ShareToken != "review-token") {
			t.Fatalf("playlist item %+v", item)
		}
		if item.Kind == PublicationTrack && (item.ID != solo.ID || item.Artist != "alice") {
			t.Fatalf("track item %+v", item)
		}
	}
	if _, err := publications.PendingTrack(f.ctx, solo.ID); err != nil {
		t.Fatalf("pending track = %v", err)
	}

	// Approving lists them and is audited; a second decision is refused.
	if err := publications.ReviewPlaylist(f.ctx, playlist.ID, admin.ID, true); err != nil {
		t.Fatal(err)
	}
	if err := publications.ReviewPlaylist(f.ctx, playlist.ID, admin.ID, false); !errors.Is(err, ErrNotPending) {
		t.Fatalf("second decision = %v", err)
	}
	if err := publications.ReviewTrack(f.ctx, solo.ID, admin.ID, true); err != nil {
		t.Fatal(err)
	}
	f.indexAll()
	if got := titles(f.listed(StoreQuery{})); got != "in playlist,solo" {
		t.Fatalf("approved content listed %q", got)
	}
	if popular, _ := f.playlists.Popular(f.ctx, "", 10); len(popular) != 1 {
		t.Fatalf("approved playlist not popular: %+v", popular)
	}
	var audits int
	if err := f.catalog.pool.QueryRow(f.ctx, `SELECT count(*) FROM publication_review_audit WHERE actor_id = $1::uuid AND approved`, admin.ID).Scan(&audits); err != nil || audits != 2 {
		t.Fatalf("audits = %d, %v", audits, err)
	}
	if pending, _ := publications.Pending(f.ctx, 10); len(pending) != 0 {
		t.Fatalf("queue after approving = %+v", pending)
	}

	// Already public content stays public when its owner asks again.
	again, _ := f.playlists.Share(f.ctx, alice.ID, playlist.ID, "other", &yes, false)
	if !again.IsPublic || again.PublicReview != nil {
		t.Fatalf("re-sharing approved playlist = %+v", again)
	}
	still, _ := f.tracks.SetPublished(f.ctx, alice.ID, solo.ID, true, false)
	if still.PublishedAt == nil || still.PublishReview != nil {
		t.Fatalf("re-publishing approved track = %+v", still)
	}

	// Rejecting keeps it private and tells the owner; asking again reopens.
	f.tracks.SetPublished(f.ctx, alice.ID, solo.ID, false, false)
	f.tracks.SetPublished(f.ctx, alice.ID, solo.ID, true, false)
	if err := publications.ReviewTrack(f.ctx, solo.ID, admin.ID, false); err != nil {
		t.Fatal(err)
	}
	rejected, _ := f.tracks.ListForOwner(f.ctx, alice.ID)
	for _, track := range rejected {
		if track.ID == solo.ID && (track.PublishedAt != nil || track.PublishReview == nil || *track.PublishReview != ReviewRejected) {
			t.Fatalf("rejected track = %+v", track)
		}
	}
	reopened, _ := f.tracks.SetPublished(f.ctx, alice.ID, solo.ID, true, false)
	if reopened.PublishReview == nil || *reopened.PublishReview != ReviewPending {
		t.Fatalf("asking again = %+v", reopened.PublishReview)
	}

	// Making it link-only, or unsharing, withdraws a request.
	f.playlists.Share(f.ctx, alice.ID, playlist.ID, "x", &no, false)
	withdrawn, _ := f.playlists.Share(f.ctx, alice.ID, playlist.ID, "x", &yes, false)
	if withdrawn.IsPublic || withdrawn.PublicReview == nil {
		t.Fatalf("asking after going link-only = %+v", withdrawn)
	}
	if err := f.playlists.Unshare(f.ctx, alice.ID, playlist.ID); err != nil {
		t.Fatal(err)
	}
	if err := publications.ReviewPlaylist(f.ctx, playlist.ID, admin.ID, true); !errors.Is(err, ErrNotPending) {
		t.Fatalf("approving a withdrawn request = %v", err)
	}
	listed, _ := f.playlists.ListForUser(f.ctx, alice.ID)
	if len(listed) != 1 || listed[0].IsPublic || listed[0].PublicReview != nil {
		t.Fatalf("after unsharing = %+v", listed)
	}
}
