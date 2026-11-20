package httpapi

import (
	"context"
	"encoding/base64"
	"errors"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/mhdolatabadi/rhythmo/server/internal/auth"
	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

// ProfileStore keeps public profiles, follows and blocks (#228);
// *store.Profiles implements it.
type ProfileStore interface {
	Mine(ctx context.Context, userID string) (store.MyProfile, error)
	Update(ctx context.Context, userID string, update store.ProfileUpdate, direct bool) (store.MyProfile, error)
	SetAvatar(ctx context.Context, userID, contentType string, data []byte, direct bool) error
	Avatar(ctx context.Context, handle, viewerID string) (string, []byte, time.Time, error)
	ByHandle(ctx context.Context, handle, viewerID string) (store.Profile, error)
	Playlists(ctx context.Context, userID string, limit int) ([]store.ProfilePlaylist, error)
	Follow(ctx context.Context, followerID, handle string) error
	Unfollow(ctx context.Context, followerID, handle string) error
	Block(ctx context.Context, blockerID, handle string) error
	Unblock(ctx context.Context, blockerID, handle string) error
	Blocked(ctx context.Context, blockerID string) ([]store.Profile, error)
	Report(ctx context.Context, reporterID, handle, reason string, details *string) error
	Feed(ctx context.Context, viewerID string, before *store.FeedCursor, limit int) ([]store.FeedItem, error)
}

const (
	maxBioRunes = 160
	// maxAvatarBytes matches the database check on user_avatars.
	maxAvatarBytes = 256 << 10
	// profilePlaylists caps the playlists one profile lists.
	profilePlaylists        = 100
	defaultFeedPage         = 30
	maxFeedPage             = 100
	maxProfileReportDetails = 500
)

var handlePattern = regexp.MustCompile(`^[a-z][a-z0-9_]{2,19}$`)

// reservedHandles would pass for the service or a page of the site.
var reservedHandles = map[string]bool{
	"admin": true, "administrator": true, "api": true, "app": true, "help": true, "me": true,
	"moderator": true, "nafir": true, "official": true, "privacy": true, "rhythmo": true,
	"root": true, "settings": true, "staff": true, "store": true, "support": true, "system": true,
	"team": true, "user": true, "users": true,
}

var profileReportReasons = map[string]bool{"spam": true, "offensive": true, "impersonation": true, "other": true}

// normalizeHandle lower-cases a handle typed with or without its @ and
// checks it; "" clears it.
func normalizeHandle(raw string) (string, bool) {
	handle := strings.ToLower(strings.TrimPrefix(strings.TrimSpace(raw), "@"))
	if handle == "" {
		return "", true
	}
	if !handlePattern.MatchString(handle) || reservedHandles[handle] ||
		strings.HasPrefix(handle, "rhythmo") || strings.HasPrefix(handle, "nafir") {
		return "", false
	}
	return handle, true
}

// normalizeBio collapses whitespace and rejects a bio that is too long,
// holds control or bidi-override characters, or an email address.
func normalizeBio(raw string) (string, bool) {
	bio := strings.Join(strings.Fields(raw), " ")
	if bio == "" {
		return "", true
	}
	if !utf8.ValidString(bio) || utf8.RuneCountInString(bio) > maxBioRunes || emailLike.MatchString(bio) {
		return "", false
	}
	for _, r := range bio {
		if r == '‌' || r == '‍' {
			continue
		}
		if unicode.IsControl(r) || unicode.Is(unicode.Cf, r) {
			return "", false
		}
	}
	return bio, true
}

var emailLike = regexp.MustCompile(`[^\s@]+@[^\s@]+\.[^\s@]+`)

// SocialHandlers serve public profiles, following, blocking, reports and
// the «فعالیت دوستان» feed (#228).
type SocialHandlers struct {
	profiles    ProfileStore
	tokens      *auth.Tokens
	publishGate *PublishGate
	followRate  *RateLimiter
	reportRate  *RateLimiter
	viewRate    *RateLimiter
}

func NewSocialHandlers(profiles ProfileStore, tokens *auth.Tokens, followRate, reportRate, viewRate *RateLimiter) *SocialHandlers {
	return &SocialHandlers{profiles: profiles, tokens: tokens, followRate: followRate, reportRate: reportRate, viewRate: viewRate}
}

// WithPublishGate sends unverified owners' public profiles to an admin
// first, as public playlists are (#322).
func (h *SocialHandlers) WithPublishGate(gate *PublishGate) *SocialHandlers {
	h.publishGate = gate
	return h
}

func (h *SocialHandlers) register(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/v1/me/profile", h.handleMine)
	mux.HandleFunc("PUT /api/v1/me/profile", h.handleUpdate)
	mux.HandleFunc("PUT /api/v1/me/profile/avatar", h.handleSetAvatar)
	mux.HandleFunc("DELETE /api/v1/me/profile/avatar", h.handleDeleteAvatar)
	mux.HandleFunc("GET /api/v1/me/blocked", h.handleBlocked)
	mux.HandleFunc("GET /api/v1/feed", h.handleFeed)
	mux.HandleFunc("GET /api/v1/users/{handle}", h.handleProfile)
	mux.HandleFunc("GET /api/v1/users/{handle}/avatar", h.handleAvatar)
	mux.HandleFunc("PUT /api/v1/users/{handle}/follow", h.handleFollow(true))
	mux.HandleFunc("DELETE /api/v1/users/{handle}/follow", h.handleFollow(false))
	mux.HandleFunc("PUT /api/v1/users/{handle}/block", h.handleBlock(true))
	mux.HandleFunc("DELETE /api/v1/users/{handle}/block", h.handleBlock(false))
	mux.HandleFunc("POST /api/v1/users/{handle}/report", h.handleReport)
}

type myProfileResponse struct {
	Handle       string  `json:"handle"`
	DisplayName  string  `json:"displayName"`
	Bio          string  `json:"bio"`
	Public       bool    `json:"public"`
	Review       *string `json:"review"`
	HideActivity bool    `json:"hideActivity"`
	HasAvatar    bool    `json:"hasAvatar"`
	Followers    int     `json:"followers"`
	Following    int     `json:"following"`
}

func myProfileJSON(me store.MyProfile) myProfileResponse {
	return myProfileResponse{
		Handle: me.Handle, DisplayName: me.DisplayName, Bio: me.Bio, Public: me.Public, Review: me.Review,
		HideActivity: me.HideActivity, HasAvatar: me.HasAvatar, Followers: me.Followers, Following: me.Following,
	}
}

func (h *SocialHandlers) handleMine(w http.ResponseWriter, r *http.Request) {
	userID, ok := authenticate(h.tokens, w, r)
	if !ok {
		return
	}
	me, err := h.profiles.Mine(r.Context(), userID)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	if err != nil {
		internalError(w, "read own profile", err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, myProfileJSON(me))
}

func (h *SocialHandlers) handleUpdate(w http.ResponseWriter, r *http.Request) {
	userID, ok := authenticate(h.tokens, w, r)
	if !ok {
		return
	}
	var input struct {
		Handle       *string `json:"handle"`
		DisplayName  *string `json:"displayName"`
		Bio          *string `json:"bio"`
		Public       *bool   `json:"public"`
		HideActivity *bool   `json:"hideActivity"`
	}
	if !decodeStrict(w, r, &input) {
		return
	}
	if input.Handle == nil || input.DisplayName == nil || input.Bio == nil || input.Public == nil || input.HideActivity == nil {
		writeError(w, http.StatusBadRequest, "invalid_request")
		return
	}
	handle, ok := normalizeHandle(*input.Handle)
	if !ok {
		writeError(w, http.StatusBadRequest, "invalid_handle")
		return
	}
	name, ok := normalizeDisplayName(*input.DisplayName)
	if !ok {
		writeError(w, http.StatusBadRequest, "invalid_display_name")
		return
	}
	bio, ok := normalizeBio(*input.Bio)
	if !ok {
		writeError(w, http.StatusBadRequest, "invalid_bio")
		return
	}
	direct, ok := h.publishGate.direct(w, r, userID)
	if !ok {
		return
	}
	me, err := h.profiles.Update(r.Context(), userID, store.ProfileUpdate{
		Handle: handle, DisplayName: name, Bio: bio, Public: *input.Public, HideActivity: *input.HideActivity,
	}, direct)
	switch {
	case errors.Is(err, store.ErrHandleTaken):
		writeError(w, http.StatusConflict, "handle_taken")
	case errors.Is(err, store.ErrNoHandle):
		writeError(w, http.StatusBadRequest, "handle_required")
	case errors.Is(err, store.ErrNotFound):
		writeError(w, http.StatusUnauthorized, "unauthorized")
	case err != nil:
		internalError(w, "update profile", err)
	default:
		writeJSON(w, http.StatusOK, myProfileJSON(me))
	}
}

// avatarType is the image type of data, if it is one an avatar may be.
func avatarType(data []byte) (string, bool) {
	switch kind := http.DetectContentType(data); kind {
	case "image/jpeg", "image/png", "image/webp":
		return kind, true
	}
	return "", false
}

func (h *SocialHandlers) handleSetAvatar(w http.ResponseWriter, r *http.Request) {
	userID, ok := authenticate(h.tokens, w, r)
	if !ok {
		return
	}
	data, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxAvatarBytes))
	var tooLarge *http.MaxBytesError
	if errors.As(err, &tooLarge) {
		writeError(w, http.StatusRequestEntityTooLarge, "avatar_too_large")
		return
	}
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request")
		return
	}
	kind, ok := avatarType(data)
	if !ok || len(data) == 0 {
		writeError(w, http.StatusUnsupportedMediaType, "unsupported_avatar")
		return
	}
	direct, ok := h.publishGate.direct(w, r, userID)
	if !ok {
		return
	}
	if err := h.profiles.SetAvatar(r.Context(), userID, kind, data, direct); err != nil {
		internalError(w, "set avatar", err)
		return
	}
	h.handleMine(w, r)
}

func (h *SocialHandlers) handleDeleteAvatar(w http.ResponseWriter, r *http.Request) {
	userID, ok := authenticate(h.tokens, w, r)
	if !ok {
		return
	}
	if err := h.profiles.SetAvatar(r.Context(), userID, "", nil, true); err != nil {
		internalError(w, "delete avatar", err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

type profilePlaylistResponse struct {
	ShareToken string `json:"shareToken"`
	Name       string `json:"name"`
	TrackCount int    `json:"trackCount"`
}

type profileResponse struct {
	Handle      string                    `json:"handle"`
	DisplayName string                    `json:"displayName"`
	Bio         string                    `json:"bio"`
	Verified    bool                      `json:"verified"`
	AvatarURL   *string                   `json:"avatarUrl"`
	Followers   int                       `json:"followers"`
	Following   int                       `json:"following"`
	IsFollowing bool                      `json:"isFollowing"`
	IsBlocked   bool                      `json:"isBlocked"`
	IsMe        bool                      `json:"isMe"`
	Playlists   []profilePlaylistResponse `json:"playlists"`
}

// avatarPath is a profile's avatar, versioned so a new one isn't cached
// under the old address.
func avatarPath(profile store.Profile) *string {
	if !profile.HasAvatar {
		return nil
	}
	path := "/api/v1/users/" + profile.Handle + "/avatar?v=" + strconv.FormatInt(profile.AvatarAt.Unix(), 36)
	return &path
}

func (h *SocialHandlers) handleProfile(w http.ResponseWriter, r *http.Request) {
	viewerID, ok := optionalUser(h.tokens, w, r)
	if !ok {
		return
	}
	if viewerID == "" && !enforceRateLimit(w, h.viewRate, clientIP(r)) {
		return
	}
	handle, ok := normalizeHandle(r.PathValue("handle"))
	if !ok || handle == "" {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	profile, err := h.profiles.ByHandle(r.Context(), handle, viewerID)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	if err != nil {
		internalError(w, "read profile", err)
		return
	}
	playlists, err := h.profiles.Playlists(r.Context(), profile.UserID, profilePlaylists)
	if err != nil {
		internalError(w, "list profile playlists", err)
		return
	}
	lists := make([]profilePlaylistResponse, 0, len(playlists))
	for _, pl := range playlists {
		lists = append(lists, profilePlaylistResponse{ShareToken: pl.ShareToken, Name: pl.Name, TrackCount: pl.TrackCount})
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, profileResponse{
		Handle: profile.Handle, DisplayName: publicOwnerName(profile.DisplayName), Bio: profile.Bio,
		Verified: profile.Verified, AvatarURL: avatarPath(profile), Followers: profile.Followers,
		Following: profile.Following, IsFollowing: profile.FollowedByViewer, IsBlocked: profile.BlockedByViewer,
		IsMe: profile.IsViewer, Playlists: lists,
	})
}

func (h *SocialHandlers) handleAvatar(w http.ResponseWriter, r *http.Request) {
	viewerID, ok := optionalUser(h.tokens, w, r)
	if !ok {
		return
	}
	if viewerID == "" && !enforceRateLimit(w, h.viewRate, clientIP(r)) {
		return
	}
	handle, ok := normalizeHandle(r.PathValue("handle"))
	if !ok || handle == "" {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	kind, data, _, err := h.profiles.Avatar(r.Context(), handle, viewerID)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	if err != nil {
		internalError(w, "read avatar", err)
		return
	}
	writeImage(w, kind, data)
}

// writeImage serves an avatar. Its address changes with it, so it may be
// kept for a day; nosniff keeps browsers to the checked type.
func writeImage(w http.ResponseWriter, kind string, data []byte) {
	w.Header().Set("Content-Type", kind)
	if w.Header().Get("Cache-Control") == "" {
		w.Header().Set("Cache-Control", "private, max-age=86400")
	}
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Length", strconv.Itoa(len(data)))
	_, _ = w.Write(data)
}

// pathHandle reads the {handle} of a request about another user.
func pathHandle(w http.ResponseWriter, r *http.Request) (string, bool) {
	handle, ok := normalizeHandle(r.PathValue("handle"))
	if !ok || handle == "" {
		writeError(w, http.StatusNotFound, "not_found")
		return "", false
	}
	return handle, true
}

func (h *SocialHandlers) handleFollow(follow bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		userID, ok := authenticate(h.tokens, w, r)
		if !ok {
			return
		}
		handle, ok := pathHandle(w, r)
		if !ok {
			return
		}
		if follow && !enforceRateLimit(w, h.followRate, userID) {
			return
		}
		var err error
		if follow {
			err = h.profiles.Follow(r.Context(), userID, handle)
		} else {
			err = h.profiles.Unfollow(r.Context(), userID, handle)
		}
		switch {
		case errors.Is(err, store.ErrNotFound), errors.Is(err, store.ErrBlocked):
			// A block looks like a missing profile, so it isn't revealed.
			writeError(w, http.StatusNotFound, "not_found")
		case err != nil:
			internalError(w, "follow", err)
		default:
			w.WriteHeader(http.StatusNoContent)
		}
	}
}

func (h *SocialHandlers) handleBlock(block bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		userID, ok := authenticate(h.tokens, w, r)
		if !ok {
			return
		}
		handle, ok := pathHandle(w, r)
		if !ok {
			return
		}
		var err error
		if block {
			err = h.profiles.Block(r.Context(), userID, handle)
		} else {
			err = h.profiles.Unblock(r.Context(), userID, handle)
		}
		switch {
		case errors.Is(err, store.ErrNotFound):
			writeError(w, http.StatusNotFound, "not_found")
		case err != nil:
			internalError(w, "block", err)
		default:
			w.WriteHeader(http.StatusNoContent)
		}
	}
}

func (h *SocialHandlers) handleBlocked(w http.ResponseWriter, r *http.Request) {
	userID, ok := authenticate(h.tokens, w, r)
	if !ok {
		return
	}
	blocked, err := h.profiles.Blocked(r.Context(), userID)
	if err != nil {
		internalError(w, "list blocked", err)
		return
	}
	items := make([]map[string]string, 0, len(blocked))
	for _, b := range blocked {
		items = append(items, map[string]string{"handle": b.Handle, "displayName": publicOwnerName(b.DisplayName)})
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]any{"blocked": items})
}

func (h *SocialHandlers) handleReport(w http.ResponseWriter, r *http.Request) {
	userID, ok := authenticate(h.tokens, w, r)
	if !ok {
		return
	}
	handle, ok := pathHandle(w, r)
	if !ok {
		return
	}
	var input struct {
		Reason  string  `json:"reason"`
		Details *string `json:"details"`
	}
	if !decodeStrict(w, r, &input) {
		return
	}
	if !profileReportReasons[input.Reason] {
		writeError(w, http.StatusBadRequest, "invalid_reason")
		return
	}
	var details *string
	if input.Details != nil {
		text := strings.TrimSpace(*input.Details)
		if utf8.RuneCountInString(text) > maxProfileReportDetails || !utf8.ValidString(text) {
			writeError(w, http.StatusBadRequest, "invalid_details")
			return
		}
		if text != "" {
			details = &text
		}
	}
	if !enforceRateLimit(w, h.reportRate, userID) {
		return
	}
	err := h.profiles.Report(r.Context(), userID, handle, input.Reason, details)
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeError(w, http.StatusNotFound, "not_found")
	case errors.Is(err, store.ErrAlreadyReported):
		// Reporting twice is fine; the first report is still open.
		w.WriteHeader(http.StatusNoContent)
	case err != nil:
		internalError(w, "report profile", err)
	default:
		w.WriteHeader(http.StatusNoContent)
	}
}

type feedItemResponse struct {
	Kind        string    `json:"kind"`
	At          time.Time `json:"at"`
	ActorHandle string    `json:"actorHandle"`
	ActorName   string    `json:"actorName"`
	ShareToken  string    `json:"shareToken,omitempty"`
	Name        string    `json:"name"`
	EntryID     string    `json:"entryId,omitempty"`
	Artist      string    `json:"artist,omitempty"`
}

func encodeFeedCursor(item store.FeedItem) string {
	raw := strconv.FormatInt(item.At.UnixMicro(), 10) + "|" + item.Kind + "|" + item.ID
	return base64.RawURLEncoding.EncodeToString([]byte(raw))
}

func decodeFeedCursor(cursor string) (*store.FeedCursor, bool) {
	raw, err := base64.RawURLEncoding.DecodeString(cursor)
	if err != nil {
		return nil, false
	}
	parts := strings.SplitN(string(raw), "|", 3)
	if len(parts) != 3 || (parts[1] != "playlist" && parts[1] != "like") || len(parts[2]) > 64 {
		return nil, false
	}
	micros, err := strconv.ParseInt(parts[0], 10, 64)
	if err != nil {
		return nil, false
	}
	return &store.FeedCursor{At: time.UnixMicro(micros).UTC(), Kind: parts[1], ID: parts[2]}, true
}

// handleFeed is «فعالیت دوستان»: a page of what the people the caller
// follows did, newest first, with the cursor of the next page.
func (h *SocialHandlers) handleFeed(w http.ResponseWriter, r *http.Request) {
	userID, ok := authenticate(h.tokens, w, r)
	if !ok {
		return
	}
	limit := defaultFeedPage
	if raw := r.URL.Query().Get("limit"); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil || parsed < 1 {
			writeError(w, http.StatusBadRequest, "invalid_limit")
			return
		}
		limit = min(parsed, maxFeedPage)
	}
	var before *store.FeedCursor
	if raw := r.URL.Query().Get("before"); raw != "" {
		cursor, ok := decodeFeedCursor(raw)
		if !ok {
			writeError(w, http.StatusBadRequest, "invalid_cursor")
			return
		}
		before = cursor
	}
	items, err := h.profiles.Feed(r.Context(), userID, before, limit+1)
	if err != nil {
		internalError(w, "read feed", err)
		return
	}
	var next *string
	if len(items) > limit {
		items = items[:limit]
		cursor := encodeFeedCursor(items[len(items)-1])
		next = &cursor
	}
	out := make([]feedItemResponse, 0, len(items))
	for _, item := range items {
		out = append(out, feedItemResponse{
			Kind: item.Kind, At: item.At.UTC(), ActorHandle: item.ActorHandle,
			ActorName: publicOwnerName(item.ActorName), ShareToken: item.ShareToken, Name: item.Name,
			EntryID: item.EntryID, Artist: item.Artist,
		})
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]any{"items": out, "next": next})
}
