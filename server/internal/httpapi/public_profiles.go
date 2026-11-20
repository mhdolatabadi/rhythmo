package httpapi

import (
	"context"
	"errors"
	"net/http"

	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

// PublicProfileStore is what the public profile pages read (#228);
// *store.Profiles implements it.
type PublicProfileStore interface {
	ByHandle(ctx context.Context, handle, viewerID string) (store.Profile, error)
	Playlists(ctx context.Context, userID string, limit int) ([]store.ProfilePlaylist, error)
	Listed(ctx context.Context, limit int) ([]store.Profile, error)
}

// sitemapProfiles caps the profiles in people.xml.
const sitemapProfiles = 10000

// WithProfiles serves public profiles at /u/{handle} and lists them in the
// sitemap.
func (p *PublicPages) WithProfiles(profiles PublicProfileStore) *PublicPages {
	p.profiles = profiles
	return p
}

type publicProfile struct {
	Handle    string
	Name      string
	Bio       string
	Avatar    string
	Followers int
	Following int
	Playlists []store.ProfilePlaylist
}

func (p *PublicPages) handleProfile(w http.ResponseWriter, r *http.Request) {
	if !enforceRateLimit(w, p.limits.View, clientIP(r)) {
		return
	}
	missing := func() {
		p.renderMissing(w, r, "این صفحه پیدا نشد", "این نمایه وجود ندارد یا عمومی نیست.", "نمایه‌ی ریتمو پیدا نشد.")
	}
	handle, ok := normalizeHandle(r.PathValue("handle"))
	if !ok || handle == "" {
		missing()
		return
	}
	profile, err := p.profiles.ByHandle(r.Context(), handle, "")
	if errors.Is(err, store.ErrNotFound) {
		missing()
		return
	}
	if err != nil {
		internalError(w, "read public profile", err)
		return
	}
	playlists, err := p.profiles.Playlists(r.Context(), profile.UserID, profilePlaylists)
	if err != nil {
		internalError(w, "list public profile playlists", err)
		return
	}
	page := publicProfile{
		Handle: profile.Handle, Name: publicOwnerName(profile.DisplayName), Bio: profile.Bio,
		Followers: profile.Followers, Following: profile.Following, Playlists: playlists,
	}
	if avatar := avatarPath(profile); avatar != nil {
		page.Avatar = *avatar
	}
	site := p.origin(r)
	canonical := site + "/u/" + profile.Handle
	description := page.Name + " در ریتمو: " + "فهرست‌های پخش عمومی و آهنگ‌هایی که می‌شنود."
	if page.Bio != "" {
		description = page.Bio + " — " + description
	}
	person := map[string]any{"@type": "Person", "name": page.Name, "alternateName": "@" + profile.Handle, "url": canonical}
	if page.Avatar != "" {
		person["image"] = site + page.Avatar
	}
	meta := pageMeta{
		Title: page.Name + " (@" + profile.Handle + ") | ریتمو", Description: description,
		Canonical: canonical, Image: site + "/social.png", OGType: "profile",
		JSONLD: map[string]any{"@context": "https://schema.org", "@type": "ProfilePage", "mainEntity": person},
	}
	meta.setCrumbs(site, crumb{Name: page.Name})
	w.Header().Set("Cache-Control", publicPageMaxAge)
	p.render(w, r, http.StatusOK, "profile", struct {
		pageMeta
		Profile publicProfile
	}{pageMeta: meta, Profile: page})
}

// profileSitemap lists the visible profiles.
func (p *PublicPages) profileSitemap(ctx context.Context, site string) ([]sitemapURL, error) {
	if p.profiles == nil {
		return nil, nil
	}
	listed, err := p.profiles.Listed(ctx, sitemapProfiles)
	if err != nil {
		return nil, err
	}
	urls := make([]sitemapURL, 0, len(listed))
	for _, profile := range listed {
		urls = append(urls, sitemapURL{Loc: site + "/u/" + profile.Handle})
	}
	return urls, nil
}
