package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/mhdolatabadi/rhythmo/server/internal/audio"
	"github.com/mhdolatabadi/rhythmo/server/internal/auth"
	"github.com/mhdolatabadi/rhythmo/server/internal/storage"
	"github.com/mhdolatabadi/rhythmo/server/internal/store"
	"github.com/mhdolatabadi/rhythmo/server/internal/tags"
)

const (
	maxTrackBodyBytes = 4 << 10
	maxTextLength     = 200
	// maxMetadataBodyBytes fits every editable field at its longest, in a
	// script that needs several bytes per character.
	maxMetadataBodyBytes = 24 << 10
	maxCommentLength     = 1000
	maxTrackNumber       = 999
)

// TrackStore reads and writes tracks for one owner; *store.Tracks implements it.
type TrackStore interface {
	ListForOwner(ctx context.Context, ownerID string) ([]store.Track, error)
	UsageForOwner(ctx context.Context, ownerID string) (int64, error)
	ForOwner(ctx context.Context, ownerID, trackID string) (store.Track, error)
	ReservePending(ctx context.Context, ownerID string, track store.NewTrack, maxOwnerBytes int64, maxPending int) (store.Track, error)
	MarkReady(ctx context.Context, ownerID, trackID string) (store.Track, error)
	UpdateMetadata(ctx context.Context, ownerID, trackID string, expectedVersion int64, metadata store.TrackMetadata) (store.Track, error)
	Delete(ctx context.Context, ownerID, trackID string) error
}

// ObjectStore is the object storage the track endpoints use; *storage.Storage implements it.
type ObjectStore interface {
	PresignGet(ctx context.Context, key string) (string, time.Time, error)
	PresignDownload(ctx context.Context, key, disposition, contentType string) (string, time.Time, error)
	PresignUpload(ctx context.Context, key, contentType string, sizeBytes int64) (storage.Upload, error)
	Size(ctx context.Context, key string) (int64, error)
	Head(ctx context.Context, key string, n int64) ([]byte, error)
	Remove(ctx context.Context, key string) error
}

type UploadLimits struct {
	MaxFileBytes        int64
	MaxOwnerBytes       int64
	MaxPending          int
	Enabled             bool
	ReservationUserRate *RateLimiter
	ReservationIPRate   *RateLimiter
	CompletionUserRate  *RateLimiter
	CompletionIPRate    *RateLimiter
}

type TrackHandlers struct {
	tracks  TrackStore
	storage ObjectStore
	tokens  *auth.Tokens
	limits  UploadLimits
	imports ImportCounter
	retags  TagRewriteNotifier
	// emailGate refuses uploads from accounts that haven't verified their
	// email; nil allows everyone.
	emailGate *EmailGate
	// fingerprints is woken when a track becomes ready.
	fingerprints TagRewriteNotifier
	// likes, when set, adds like counts to the owner's track list.
	likes LikeStore
}

// WithLikes adds each track's like count and published state to the
// owner's library (#284).
func (h *TrackHandlers) WithLikes(likes LikeStore) *TrackHandlers {
	h.likes = likes
	return h
}

// WithEmailGate keeps accounts with an unverified email out of what costs
// storage or reaches other people.
func (h *TrackHandlers) WithEmailGate(gate *EmailGate) *TrackHandlers {
	h.emailGate = gate
	return h
}

// TagRewriteNotifier starts rewriting embedded tags soon after an edit;
// *tagwriter.Writer implements it.
type TagRewriteNotifier interface {
	Notify()
}

// WithTagRewrites wakes the tag writer after each metadata edit. Without it,
// queued rewrites still run at the writer's next poll.
func (h *TrackHandlers) WithTagRewrites(retags TagRewriteNotifier) *TrackHandlers {
	h.retags = retags
	return h
}

// WithFingerprints wakes the fingerprint worker when an upload completes,
// so a new track can be identified right away.
func (h *TrackHandlers) WithFingerprints(fingerprints TagRewriteNotifier) *TrackHandlers {
	h.fingerprints = fingerprints
	return h
}

func NewTrackHandlers(tracks TrackStore, objects ObjectStore, tokens *auth.Tokens, limits UploadLimits) *TrackHandlers {
	return &TrackHandlers{tracks: tracks, storage: objects, tokens: tokens, limits: limits}
}

func (h *TrackHandlers) register(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/v1/tracks", h.handleList)
	mux.HandleFunc("POST /api/v1/tracks/uploads", h.handleCreateUpload)
	mux.HandleFunc("GET /api/v1/tracks/{id}", h.handleGet)
	mux.HandleFunc("PATCH /api/v1/tracks/{id}", h.handleUpdate)
	mux.HandleFunc("DELETE /api/v1/tracks/{id}", h.handleDelete)
	mux.HandleFunc("POST /api/v1/tracks/{id}/complete", h.handleComplete)
	mux.HandleFunc("GET /api/v1/tracks/{id}/stream", h.handleStream)
	mux.HandleFunc("GET /api/v1/tracks/{id}/download", h.handleDownload)
}

type trackResponse struct {
	ID          string    `json:"id"`
	Title       string    `json:"title"`
	Artist      *string   `json:"artist"`
	Album       *string   `json:"album"`
	AlbumArtist *string   `json:"albumArtist"`
	Composer    *string   `json:"composer"`
	Genre       *string   `json:"genre"`
	Year        *int32    `json:"year"`
	TrackNumber *int32    `json:"trackNumber"`
	DiscNumber  *int32    `json:"discNumber"`
	Comment     *string   `json:"comment"`
	DurationMS  *int32    `json:"durationMs"`
	FileName    string    `json:"fileName"`
	ContentType string    `json:"contentType"`
	SizeBytes   int64     `json:"sizeBytes"`
	Source      string    `json:"source"`
	CreatedAt   time.Time `json:"createdAt"`
	// Version is the metadata version an edit must be based on.
	Version int64 `json:"version"`
	// EmbeddedTags says whether the file itself carries the metadata.
	EmbeddedTags embeddedTagsResponse `json:"embeddedTags"`
	// ReplayGain is the loudness the file's tags carry, or null when they
	// carry none or have not been read yet (#253).
	ReplayGain *replayGainResponse `json:"replayGain"`
	// Published, LikeCount and Liked are only filled in the owner's own
	// library (#284): whether they published the track to the store, how
	// many listeners like the song, and whether they do.
	Published bool `json:"published,omitempty"`
	// PublishReview is "pending" or "rejected" while publishing waits for
	// or was turned down by an admin (#322); owner's library only.
	PublishReview *string `json:"publishReview,omitempty"`
	LikeCount     int     `json:"likeCount,omitempty"`
	Liked         bool    `json:"liked,omitempty"`
}

// replayGainResponse holds gains in dB re -18 LUFS and peaks as linear
// amplitude; a missing value is null.
type replayGainResponse struct {
	TrackGainDB *float64 `json:"trackGainDb"`
	TrackPeak   *float64 `json:"trackPeak"`
	AlbumGainDB *float64 `json:"albumGainDb"`
	AlbumPeak   *float64 `json:"albumPeak"`
}

func toReplayGain(l store.Loudness) *replayGainResponse {
	if l.TrackGainDB == nil && l.TrackPeak == nil && l.AlbumGainDB == nil && l.AlbumPeak == nil {
		return nil
	}
	return &replayGainResponse{
		TrackGainDB: l.TrackGainDB, TrackPeak: l.TrackPeak,
		AlbumGainDB: l.AlbumGainDB, AlbumPeak: l.AlbumPeak,
	}
}

// embeddedTagsResponse reports the stored file's tags. Status is original,
// pending, written, failed or unsupported; UnsupportedFields lists the fields
// this file's format cannot embed, so the app can say so honestly.
type embeddedTagsResponse struct {
	Status            store.TagStatus `json:"status"`
	Version           *int64          `json:"version"`
	Error             *string         `json:"error"`
	UnsupportedFields []string        `json:"unsupportedFields"`
}

func toTrackResponse(t store.Track) trackResponse {
	return trackResponse{
		ID: t.ID, Title: t.Title, Artist: t.Artist, Album: t.Album, AlbumArtist: t.AlbumArtist,
		Composer: t.Composer, Genre: t.Genre, Year: t.Year, TrackNumber: t.TrackNumber,
		DiscNumber: t.DiscNumber, Comment: t.Comment, DurationMS: t.DurationMS,
		FileName: t.FileName, ContentType: t.ContentType, SizeBytes: t.SizeBytes,
		Source: t.Source, CreatedAt: t.CreatedAt.UTC(), Version: t.MetadataVersion,
		EmbeddedTags: embeddedTagsResponse{
			Status: t.TagStatus, Version: t.TagVersion, Error: t.TagError,
			UnsupportedFields: tags.UnsupportedFields(t.FileName),
		},
		ReplayGain: toReplayGain(t.Loudness),
	}
}

type trackListResponse struct {
	Tracks  []trackResponse      `json:"tracks"`
	Storage storageUsageResponse `json:"storage"`
	// ImportsInProgress counts bot imports not yet in the list, so the app
	// knows to check again soon.
	ImportsInProgress int `json:"importsInProgress"`
}

// ImportCounter counts a user's bot imports still in progress.
type ImportCounter interface {
	ActiveImports(ctx context.Context, userID string) (int, error)
}

// WithImports makes the track list report bot imports in progress.
func (h *TrackHandlers) WithImports(imports ImportCounter) *TrackHandlers {
	h.imports = imports
	return h
}

type storageUsageResponse struct {
	UsedBytes  int64 `json:"usedBytes"`
	LimitBytes int64 `json:"limitBytes"`
}

type streamResponse struct {
	URL       string    `json:"url"`
	ExpiresAt time.Time `json:"expiresAt"`
}

// updateTrackRequest replaces the editable metadata: an omitted or empty
// optional field clears it. FileName may be omitted to keep the current one.
type updateTrackRequest struct {
	// Version is the metadata version the edit is based on. It may instead
	// be sent as an If-Match header.
	Version     *int64  `json:"version"`
	FileName    *string `json:"fileName"`
	Title       *string `json:"title"`
	Artist      *string `json:"artist"`
	Album       *string `json:"album"`
	AlbumArtist *string `json:"albumArtist"`
	Composer    *string `json:"composer"`
	Genre       *string `json:"genre"`
	Year        *int32  `json:"year"`
	TrackNumber *int32  `json:"trackNumber"`
	DiscNumber  *int32  `json:"discNumber"`
	Comment     *string `json:"comment"`
}

func (h *TrackHandlers) handleList(w http.ResponseWriter, r *http.Request) {
	userID, ok := authenticate(h.tokens, w, r)
	if !ok {
		return
	}
	tracks, err := h.tracks.ListForOwner(r.Context(), userID)
	if err != nil {
		internalError(w, "list tracks", err)
		return
	}
	usedBytes, err := h.tracks.UsageForOwner(r.Context(), userID)
	if err != nil {
		internalError(w, "read storage usage", err)
		return
	}
	response := trackListResponse{
		Tracks: make([]trackResponse, 0, len(tracks)),
		Storage: storageUsageResponse{
			UsedBytes: usedBytes, LimitBytes: h.limits.MaxOwnerBytes,
		},
	}
	likes := map[string]store.LikeState{}
	if h.likes != nil {
		if likes, err = h.likes.OwnerStates(r.Context(), userID); err != nil {
			internalError(w, "count track likes", err)
			return
		}
	}
	for _, track := range tracks {
		response.Tracks = append(response.Tracks, toOwnTrackResponse(track, likes[track.ID]))
	}
	if h.imports != nil {
		if response.ImportsInProgress, err = h.imports.ActiveImports(r.Context(), userID); err != nil {
			internalError(w, "count bot imports", err)
			return
		}
	}
	writeJSON(w, http.StatusOK, response)
}

func (h *TrackHandlers) handleGet(w http.ResponseWriter, r *http.Request) {
	track, ok := h.readyTrack(w, r)
	if !ok {
		return
	}
	writeJSON(w, http.StatusOK, toTrackResponse(track))
}

func (h *TrackHandlers) handleStream(w http.ResponseWriter, r *http.Request) {
	track, ok := h.readyTrack(w, r)
	if !ok {
		return
	}
	url, expiresAt, err := h.storage.PresignGet(r.Context(), track.StorageKey)
	if err != nil {
		internalError(w, "presign track", err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, streamResponse{URL: url, ExpiresAt: expiresAt.UTC()})
}

type downloadResponse struct {
	// URL downloads the file; storage answers with Content-Disposition set
	// to FileName, so a browser saves it under the edited name.
	URL         string    `json:"url"`
	ExpiresAt   time.Time `json:"expiresAt"`
	FileName    string    `json:"fileName"`
	ContentType string    `json:"contentType"`
	SizeBytes   int64     `json:"sizeBytes"`
	// Version is the metadata version the file was served for; a client
	// caching downloads should treat a different track version as stale.
	Version int64 `json:"version"`
	// TagsUpToDate is false when the file's embedded tags cannot match the
	// saved metadata: its format has no writer, or rewriting it failed.
	TagsUpToDate bool                 `json:"tagsUpToDate"`
	EmbeddedTags embeddedTagsResponse `json:"embeddedTags"`
}

// handleDownload hands out a short-lived link that saves the track's current
// object under its edited file name. While an edit's tag rewrite is still
// running the object holds the old tags, so the answer is 409 tags_pending
// with Retry-After instead of stale bytes. Every rewrite has its own object
// key, so a cached response for an older version can never be served for
// the new one.
func (h *TrackHandlers) handleDownload(w http.ResponseWriter, r *http.Request) {
	track, ok := h.readyTrack(w, r)
	if !ok {
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	if track.TagStatus == store.TagPending {
		w.Header().Set("Retry-After", "5")
		writeJSON(w, http.StatusConflict, conflictResponse{Error: "tags_pending", Track: toTrackResponse(track)})
		return
	}
	url, expiresAt, err := h.storage.PresignDownload(r.Context(), track.StorageKey,
		audio.ContentDisposition(track.FileName), track.ContentType)
	if err != nil {
		internalError(w, "presign download", err)
		return
	}
	upToDate := track.TagStatus == store.TagOriginal ||
		(track.TagStatus == store.TagWritten && track.TagVersion != nil && *track.TagVersion == track.MetadataVersion)
	writeJSON(w, http.StatusOK, downloadResponse{
		URL: url, ExpiresAt: expiresAt.UTC(), FileName: track.FileName, ContentType: track.ContentType,
		SizeBytes: track.SizeBytes, Version: track.MetadataVersion, TagsUpToDate: upToDate,
		EmbeddedTags: toTrackResponse(track).EmbeddedTags,
	})
}

// metadataErrorResponse names the first field that failed validation so the
// app can point at it.
type metadataErrorResponse struct {
	Error string `json:"error"`
	Field string `json:"field"`
}

// conflictResponse carries the current track so the app can show what
// changed instead of overwriting it.
type conflictResponse struct {
	Error string        `json:"error"`
	Track trackResponse `json:"track"`
}

func (h *TrackHandlers) handleUpdate(w http.ResponseWriter, r *http.Request) {
	track, ok := h.readyTrack(w, r)
	if !ok {
		return
	}
	var input updateTrackRequest
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxMetadataBodyBytes))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil || decoder.More() {
		writeError(w, http.StatusBadRequest, "invalid_json")
		return
	}
	version, ok := requestVersion(r, input.Version)
	if !ok {
		writeError(w, http.StatusPreconditionRequired, "version_required")
		return
	}
	metadata, field := validateMetadata(track, input)
	if field != "" {
		writeJSON(w, http.StatusBadRequest, metadataErrorResponse{Error: "invalid_metadata", Field: field})
		return
	}
	metadata.TagStatus = store.TagUnsupported
	if tags.Supported(metadata.FileName) {
		metadata.TagStatus = store.TagPending
	}
	updated, err := h.tracks.UpdateMetadata(r.Context(), track.OwnerID, track.ID, version, metadata)
	if errors.Is(err, store.ErrVersionConflict) {
		h.writeConflict(w, r, track)
		return
	}
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	if err != nil {
		internalError(w, "update track metadata", err)
		return
	}
	if h.retags != nil && updated.TagStatus == store.TagPending {
		h.retags.Notify()
	}
	writeJSON(w, http.StatusOK, toTrackResponse(updated))
}

// writeConflict answers 409 with the latest saved version of track.
func (h *TrackHandlers) writeConflict(w http.ResponseWriter, r *http.Request, track store.Track) {
	latest, err := h.tracks.ForOwner(r.Context(), track.OwnerID, track.ID)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	if err != nil {
		internalError(w, "reload track", err)
		return
	}
	writeJSON(w, http.StatusConflict, conflictResponse{Error: "version_conflict", Track: toTrackResponse(latest)})
}

// requestVersion reads the version an edit is based on, from the body or
// from an If-Match header such as "3" (an ETag-style quoted number).
func requestVersion(r *http.Request, body *int64) (int64, bool) {
	if body != nil {
		return *body, *body > 0
	}
	raw := strings.TrimSpace(r.Header.Get("If-Match"))
	raw = strings.TrimPrefix(raw, "W/")
	raw = strings.Trim(raw, `"`)
	if raw == "" {
		return 0, false
	}
	version, err := strconv.ParseInt(raw, 10, 64)
	return version, err == nil && version > 0
}

// validateMetadata checks and normalizes an edit of track, returning the name
// of the first invalid field, if any.
func validateMetadata(track store.Track, input updateTrackRequest) (store.TrackMetadata, string) {
	metadata := store.TrackMetadata{
		FileName: track.FileName, Year: input.Year,
		TrackNumber: input.TrackNumber, DiscNumber: input.DiscNumber,
	}
	if input.FileName != nil {
		fileName, err := audio.ValidFileName(*input.FileName, track.FileName)
		if err != nil {
			return metadata, "fileName"
		}
		metadata.FileName = fileName
	}
	title := optionalText(input.Title)
	if title == nil || !validText(title, maxTextLength) {
		return metadata, "title"
	}
	metadata.Title = *title
	for _, field := range []struct {
		name  string
		value *string
		into  **string
	}{
		{"artist", input.Artist, &metadata.Artist},
		{"album", input.Album, &metadata.Album},
		{"albumArtist", input.AlbumArtist, &metadata.AlbumArtist},
		{"composer", input.Composer, &metadata.Composer},
		{"genre", input.Genre, &metadata.Genre},
	} {
		value := optionalText(field.value)
		if !validText(value, maxTextLength) {
			return metadata, field.name
		}
		*field.into = value
	}
	metadata.Comment = optionalText(input.Comment)
	if !validComment(metadata.Comment) {
		return metadata, "comment"
	}
	switch {
	case !validYear(input.Year):
		return metadata, "year"
	case !inRange(input.TrackNumber, 1, maxTrackNumber):
		return metadata, "trackNumber"
	case !inRange(input.DiscNumber, 1, maxTrackNumber):
		return metadata, "discNumber"
	}
	return metadata, ""
}

// ownedTrack loads the {id} track for the authenticated user. Another user's
// track is reported as not found, exactly like a missing one.
func (h *TrackHandlers) ownedTrack(w http.ResponseWriter, r *http.Request) (store.Track, bool) {
	userID, ok := authenticate(h.tokens, w, r)
	if !ok {
		return store.Track{}, false
	}
	track, err := h.tracks.ForOwner(r.Context(), userID, r.PathValue("id"))
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "not_found")
		return store.Track{}, false
	}
	if err != nil {
		internalError(w, "find track", err)
		return store.Track{}, false
	}
	if track.OwnerID != userID {
		// Defence in depth: the store already filters by owner.
		writeError(w, http.StatusNotFound, "not_found")
		return store.Track{}, false
	}
	return track, true
}

// readyTrack is ownedTrack for tracks whose upload has been verified.
func (h *TrackHandlers) readyTrack(w http.ResponseWriter, r *http.Request) (store.Track, bool) {
	track, ok := h.ownedTrack(w, r)
	if ok && track.Status != store.TrackReady {
		writeError(w, http.StatusNotFound, "not_found")
		return store.Track{}, false
	}
	return track, ok
}

type createUploadRequest struct {
	FileName  string  `json:"fileName"`
	SizeBytes int64   `json:"sizeBytes"`
	Title     *string `json:"title"`
	Artist    *string `json:"artist"`
	Album     *string `json:"album"`
}

type uploadForm struct {
	URL       string            `json:"url"`
	Fields    map[string]string `json:"fields"`
	ExpiresAt time.Time         `json:"expiresAt"`
}

type createUploadResponse struct {
	Track  trackResponse `json:"track"`
	Upload uploadForm    `json:"upload"`
}

// handleCreateUpload records a pending track and returns a form that lets the
// client upload exactly the declared file straight to storage.
func (h *TrackHandlers) handleCreateUpload(w http.ResponseWriter, r *http.Request) {
	userID, ok := authenticate(h.tokens, w, r)
	if !ok {
		return
	}
	if !enforceRateLimit(w, h.limits.ReservationUserRate, userID) ||
		!enforceRateLimit(w, h.limits.ReservationIPRate, clientIP(r)) {
		return
	}
	if !h.emailGate.allow(w, r, userID) {
		return
	}
	var input createUploadRequest
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxTrackBodyBytes))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_json")
		return
	}
	contentType, ok := audio.ContentType(input.FileName)
	if !ok {
		writeError(w, http.StatusUnsupportedMediaType, "unsupported_format")
		return
	}
	if !h.limits.Enabled {
		writeError(w, http.StatusServiceUnavailable, "uploads_disabled")
		return
	}
	if input.SizeBytes <= 0 || input.SizeBytes > h.limits.MaxFileBytes {
		writeError(w, http.StatusRequestEntityTooLarge, "invalid_size")
		return
	}
	title := optionalText(input.Title)
	if title == nil {
		derived := audio.Title(input.FileName)
		title = &derived
	}
	if tooLong(title) || tooLong(input.Artist) || tooLong(input.Album) {
		writeError(w, http.StatusBadRequest, "invalid_metadata")
		return
	}

	track, err := h.tracks.ReservePending(r.Context(), userID, store.NewTrack{
		Title:       *title,
		Artist:      optionalText(input.Artist),
		Album:       optionalText(input.Album),
		FileName:    audio.DisplayFileName(input.FileName),
		ContentType: contentType,
		SizeBytes:   input.SizeBytes,
	}, h.limits.MaxOwnerBytes, h.limits.MaxPending)
	if errors.Is(err, store.ErrQuotaExceeded) {
		writeError(w, http.StatusRequestEntityTooLarge, "quota_exceeded")
		return
	}
	if errors.Is(err, store.ErrTooManyPending) {
		w.Header().Set("Retry-After", "60")
		writeError(w, http.StatusTooManyRequests, "too_many_pending_uploads")
		return
	}
	if err != nil {
		internalError(w, "create track", err)
		return
	}
	upload, err := h.storage.PresignUpload(r.Context(), track.StorageKey, contentType, input.SizeBytes)
	if err != nil {
		_ = h.tracks.Delete(r.Context(), userID, track.ID)
		internalError(w, "presign upload", err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusCreated, createUploadResponse{
		Track:  toTrackResponse(track),
		Upload: uploadForm{URL: upload.URL, Fields: upload.Fields, ExpiresAt: upload.ExpiresAt.UTC()},
	})
}

// handleComplete verifies the uploaded object and makes the track playable.
// An object that is not the declared audio file is deleted with its track.
func (h *TrackHandlers) handleComplete(w http.ResponseWriter, r *http.Request) {
	track, ok := h.ownedTrack(w, r)
	if !ok {
		return
	}
	if !enforceRateLimit(w, h.limits.CompletionUserRate, track.OwnerID) ||
		!enforceRateLimit(w, h.limits.CompletionIPRate, clientIP(r)) {
		return
	}
	if track.Status == store.TrackReady {
		writeJSON(w, http.StatusOK, toTrackResponse(track))
		return
	}
	size, err := h.storage.Size(r.Context(), track.StorageKey)
	if errors.Is(err, storage.ErrObjectMissing) {
		writeError(w, http.StatusConflict, "upload_missing")
		return
	}
	if err != nil {
		internalError(w, "stat upload", err)
		return
	}
	header, err := h.storage.Head(r.Context(), track.StorageKey, audio.HeaderBytes)
	if err != nil {
		internalError(w, "read upload", err)
		return
	}
	if size != track.SizeBytes || !audio.Matches(track.StorageKey, header) {
		h.discard(r.Context(), track)
		writeError(w, http.StatusUnprocessableEntity, "invalid_audio")
		return
	}
	ready, err := h.tracks.MarkReady(r.Context(), track.OwnerID, track.ID)
	if err != nil {
		internalError(w, "mark track ready", err)
		return
	}
	if h.fingerprints != nil {
		h.fingerprints.Notify()
	}
	writeJSON(w, http.StatusOK, toTrackResponse(ready))
}

// handleDelete removes one of the caller's tracks, pending or ready, and its object.
func (h *TrackHandlers) handleDelete(w http.ResponseWriter, r *http.Request) {
	track, ok := h.ownedTrack(w, r)
	if !ok {
		return
	}
	if err := h.storage.Remove(r.Context(), track.StorageKey); err != nil {
		internalError(w, "remove object", err)
		return
	}
	// A tag rewrite in flight may have uploaded its replacement already.
	if track.PendingStorageKey != nil {
		if err := h.storage.Remove(r.Context(), *track.PendingStorageKey); err != nil {
			internalError(w, "remove pending object", err)
			return
		}
	}
	if err := h.tracks.Delete(r.Context(), track.OwnerID, track.ID); err != nil && !errors.Is(err, store.ErrNotFound) {
		internalError(w, "delete track", err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *TrackHandlers) discard(ctx context.Context, track store.Track) {
	if err := h.storage.Remove(ctx, track.StorageKey); err != nil {
		slog.Error("remove rejected upload", "track", track.ID, "error", err)
	}
	if err := h.tracks.Delete(ctx, track.OwnerID, track.ID); err != nil {
		slog.Error("delete rejected track", "track", track.ID, "error", err)
	}
}

func optionalText(value *string) *string {
	if value == nil {
		return nil
	}
	trimmed := strings.TrimSpace(*value)
	if trimmed == "" {
		return nil
	}
	return &trimmed
}

func tooLong(value *string) bool {
	return value != nil && utf8.RuneCountInString(strings.TrimSpace(*value)) > maxTextLength
}

func validYear(value *int32) bool {
	return inRange(value, 0, 9999)
}

func inRange(value *int32, low, high int32) bool {
	return value == nil || (*value >= low && *value <= high)
}

// validText accepts a single line of at most max characters.
func validText(value *string, max int) bool {
	if value == nil {
		return true
	}
	if utf8.RuneCountInString(*value) > max {
		return false
	}
	for _, r := range *value {
		if unicode.IsControl(r) || r == utf8.RuneError {
			return false
		}
	}
	return true
}

// validComment is validText that also allows line breaks and tabs.
func validComment(value *string) bool {
	if value == nil {
		return true
	}
	singleLine := strings.NewReplacer("\r\n", " ", "\n", " ", "\t", " ").Replace(*value)
	return validText(&singleLine, maxCommentLength)
}
