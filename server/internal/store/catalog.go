package store

import (
	"context"
	"errors"
	"strings"
	"time"
	"unicode"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Catalog is the public store (#243): one entry per song across every
// public playlist. Which copies are grouped into an entry is kept in
// store_entry_tracks; what is listed, and which copy plays, is decided live
// from the copies still in a public playlist. Owners are never exposed.
type Catalog struct {
	pool *pgxpool.Pool
}

func NewCatalog(pool *pgxpool.Pool) *Catalog {
	return &Catalog{pool: pool}
}

// storeEligible is true for a track that may be listed in the store: a
// ready track its owner published on its own (#284), or one in at least
// one public playlist it belongs in. Everything the store shows or plays
// passes it at query time.
func storeEligible(tracks string) string {
	return `(` + tracks + `.status = 'ready' AND (` + tracks + `.published_at IS NOT NULL OR EXISTS (
		SELECT 1 FROM playlist_tracks spt JOIN playlists sp ON sp.id = spt.playlist_id
		WHERE spt.track_id = ` + tracks + `.id AND sp.is_public AND sp.share_token IS NOT NULL
		  AND ` + trackBelongs(tracks, "sp") + `)))`
}

// losslessTypes are played in preference to lossy copies of the same song.
const losslessTypes = `('audio/flac', 'audio/x-flac', 'audio/wav', 'audio/x-wav', 'audio/wave', 'audio/aiff', 'audio/x-aiff')`

// bestCopyOrder ranks an entry's copies: lossless first, then the highest
// average bitrate, then the oldest, so the choice is stable.
func bestCopyOrder(tracks string) string {
	return `CASE WHEN ` + tracks + `.content_type IN ` + losslessTypes + ` THEN 0 ELSE 1 END,
		` + tracks + `.size_bytes::float8 / NULLIF(` + tracks + `.duration_ms, 0) DESC NULLS LAST,
		` + tracks + `.created_at, ` + tracks + `.id`
}

// liveEntries is a CTE of the listed entries, each with its best copy that
// is still eligible and how many eligible copies it has. $1 includes
// hidden entries (for admins).
var liveEntries = `live AS (
	SELECT DISTINCT ON (et.entry_id) et.entry_id::text AS entry_id, e.hidden_at,
		count(*) OVER (PARTITION BY et.entry_id) AS copies, ` + qualifiedTrackColumns("tracks") + `
	FROM store_entry_tracks et
	JOIN store_entries e ON e.id = et.entry_id
	JOIN tracks ON tracks.id = et.track_id
	WHERE ` + storeEligible("tracks") + ` AND (e.hidden_at IS NULL OR $1)
	ORDER BY et.entry_id, ` + bestCopyOrder("tracks") + `
)`

var liveTrackColumns = qualifyColumns("live", trackColumnNames)

// CatalogJob is an eligible copy not yet grouped into an entry, with its
// fingerprint when it has one.
type CatalogJob struct {
	Track           Track
	Points          []byte
	DurationSeconds *float64
}

// PendingCatalogTracks returns up to limit eligible copies that are in no
// entry yet, oldest first. A copy waits for its fingerprint, so it is
// grouped by sound rather than by name, but not longer than settle after
// it was added: fingerprinting may be off or may have failed.
func (c *Catalog) PendingCatalogTracks(ctx context.Context, limit int, settle time.Duration) ([]CatalogJob, error) {
	rows, err := c.pool.Query(ctx, `
		SELECT `+qualifiedTrackColumns("tracks")+`, fp.points, fp.duration_seconds
		FROM tracks
		LEFT JOIN track_fingerprints fp ON fp.track_id = tracks.id AND fp.points IS NOT NULL
		WHERE NOT EXISTS (SELECT 1 FROM store_entry_tracks et WHERE et.track_id = tracks.id)
		  AND `+storeEligible("tracks")+`
		  AND (fp.points IS NOT NULL OR tracks.created_at <= now() - $2::interval)
		ORDER BY tracks.created_at, tracks.id
		LIMIT $1
	`, limit, settle.String())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var jobs []CatalogJob
	for rows.Next() {
		var job CatalogJob
		dest := append(trackDestinations(&job.Track), &job.Points, &job.DurationSeconds)
		if err := rows.Scan(dest...); err != nil {
			return nil, err
		}
		jobs = append(jobs, job)
	}
	return jobs, rows.Err()
}

// CatalogCandidate is an entry a new copy might belong to.
type CatalogCandidate struct {
	EntryID         string
	TitleKey        string
	DurationSeconds *float64
	Points          []byte
}

// CatalogCandidates returns the entries a copy with this title key and
// duration might be a duplicate of: the same title key, or a fingerprinted
// entry within window seconds of its length. Hidden entries are included,
// so a hidden song stays hidden when a new copy arrives.
func (c *Catalog) CatalogCandidates(ctx context.Context, titleKey string, durationSeconds *float64, window float64) ([]CatalogCandidate, error) {
	rows, err := c.pool.Query(ctx, `
		SELECT id::text, title_key, duration_seconds, points FROM store_entries
		WHERE title_key = $1
		   OR (points IS NOT NULL AND $2::float8 IS NOT NULL AND abs(duration_seconds - $2::float8) <= $3)
		ORDER BY created_at, id
		LIMIT 500
	`, titleKey, durationSeconds, window)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var candidates []CatalogCandidate
	for rows.Next() {
		var candidate CatalogCandidate
		if err := rows.Scan(&candidate.EntryID, &candidate.TitleKey, &candidate.DurationSeconds, &candidate.Points); err != nil {
			return nil, err
		}
		candidates = append(candidates, candidate)
	}
	return candidates, rows.Err()
}

// AddToEntry groups a copy into an existing entry. The entry adopts the
// copy's fingerprint when it has none yet. A copy or entry deleted
// meanwhile, or a copy already grouped, is not an error.
func (c *Catalog) AddToEntry(ctx context.Context, trackID, entryID string, points []byte, durationSeconds *float64) error {
	err := pgx.BeginFunc(ctx, c.pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `
			INSERT INTO store_entry_tracks (track_id, entry_id) VALUES ($1::text::uuid, $2::text::uuid)
			ON CONFLICT (track_id) DO NOTHING
		`, trackID, entryID); err != nil {
			return err
		}
		if len(points) == 0 {
			return nil
		}
		_, err := tx.Exec(ctx, `
			UPDATE store_entries SET points = $2, duration_seconds = COALESCE($3, duration_seconds)
			WHERE id::text = $1 AND points IS NULL
		`, entryID, points, durationSeconds)
		return err
	})
	return ignoreDeletedTrack(err)
}

// NewEntry starts an entry with this copy as its first. A copy deleted
// meanwhile is not an error.
func (c *Catalog) NewEntry(ctx context.Context, trackID, titleKey string, points []byte, durationSeconds *float64) error {
	err := pgx.BeginFunc(ctx, c.pool, func(tx pgx.Tx) error {
		var entryID string
		if err := tx.QueryRow(ctx, `
			INSERT INTO store_entries (title_key, points, duration_seconds) VALUES ($1, $2, $3)
			RETURNING id::text
		`, titleKey, nilIfEmpty(points), durationSeconds).Scan(&entryID); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `
			INSERT INTO store_entry_tracks (track_id, entry_id) VALUES ($1::text::uuid, $2::text::uuid)
		`, trackID, entryID)
		return err
	})
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "23505" {
		// Another indexer grouped it first; its entry stands.
		return nil
	}
	return ignoreDeletedTrack(err)
}

func nilIfEmpty(b []byte) []byte {
	if len(b) == 0 {
		return nil
	}
	return b
}

// PruneCatalog forgets copies that are no longer eligible (unpublished,
// removed from every public playlist, or no longer ready) and entries left
// without copies, except hidden ones, which keep the song hidden. It is
// housekeeping only: listings already ignore ineligible copies.
func (c *Catalog) PruneCatalog(ctx context.Context) (int64, error) {
	removed, err := c.pool.Exec(ctx, `
		DELETE FROM store_entry_tracks et USING tracks
		WHERE tracks.id = et.track_id AND NOT `+storeEligible("tracks"))
	if err != nil {
		return 0, err
	}
	if _, err := c.pool.Exec(ctx, `
		DELETE FROM store_entries e
		WHERE e.hidden_at IS NULL
		  AND NOT EXISTS (SELECT 1 FROM store_entry_tracks et WHERE et.entry_id = e.id)
		  AND e.created_at <= now() - interval '1 minute'
	`); err != nil {
		return 0, err
	}
	return removed.RowsAffected(), nil
}

// StoreEntry is one listed song: the copy that plays, and how many
// eligible copies of it there are.
type StoreEntry struct {
	ID     string
	Track  Track
	Copies int
	Hidden bool
}

// StoreQuery filters and pages store entries. Search matches every word
// against the title, artist and album, tolerant of Persian and Arabic
// letter variants; Artist and Album match exactly, after the same folding.
type StoreQuery struct {
	Search string
	Artist string
	Album  string
	Limit  int
	Offset int
}

// SearchWords splits a search into words, treating ZWNJ as a space.
func SearchWords(search string) []string {
	return strings.FieldsFunc(search, func(r rune) bool { return unicode.IsSpace(r) || r == '‌' })
}

// likePattern escapes LIKE's wildcards in a search word.
func likePattern(word string) string {
	return strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(word)
}

func likePatterns(search string) []string {
	words := SearchWords(search)
	patterns := make([]string, 0, len(words))
	for _, word := range words {
		patterns = append(patterns, likePattern(word))
	}
	return patterns
}

// matchesWords is true when every word in the text[] parameter is in the
// folded title, artist, album or album artist of live.
func matchesWords(param string) string {
	return `NOT EXISTS (SELECT 1 FROM unnest(` + param + `::text[]) w
		WHERE store_fold(concat_ws(' ', live.title, live.artist, live.album, live.album_artist))
			NOT LIKE '%' || store_fold(w) || '%')`
}

// StoreEntries lists entries by title, Limit at a time. more says whether
// another page follows.
func (c *Catalog) StoreEntries(ctx context.Context, query StoreQuery) (entries []StoreEntry, more bool, err error) {
	rows, err := c.pool.Query(ctx, `
		WITH `+liveEntries+`
		SELECT live.entry_id, live.copies, live.hidden_at IS NOT NULL, `+liveTrackColumns+`
		FROM live
		WHERE `+matchesWords("$2")+`
		  AND ($3 = '' OR store_fold(COALESCE(live.artist, '')) = store_fold($3)
		       OR store_fold(COALESCE(live.album_artist, '')) = store_fold($3))
		  AND ($4 = '' OR store_fold(COALESCE(live.album, '')) = store_fold($4))
		ORDER BY store_fold(live.title), live.entry_id
		LIMIT $5 OFFSET $6
	`, false, likePatterns(query.Search), query.Artist, query.Album, query.Limit+1, query.Offset)
	if err != nil {
		return nil, false, err
	}
	entries, err = scanStoreEntries(rows)
	if err != nil {
		return nil, false, err
	}
	if len(entries) > query.Limit {
		return entries[:query.Limit], true, nil
	}
	return entries, false, nil
}

func scanStoreEntries(rows pgx.Rows) ([]StoreEntry, error) {
	defer rows.Close()
	entries := []StoreEntry{}
	for rows.Next() {
		var entry StoreEntry
		dest := append([]any{&entry.ID, &entry.Copies, &entry.Hidden}, trackDestinations(&entry.Track)...)
		if err := rows.Scan(dest...); err != nil {
			return nil, err
		}
		entries = append(entries, entry)
	}
	return entries, rows.Err()
}

// StoreEntryByID returns a listed entry, or ErrNotFound when it is hidden
// (unless includeHidden), has no eligible copy left, or doesn't exist.
func (c *Catalog) StoreEntryByID(ctx context.Context, entryID string, includeHidden bool) (StoreEntry, error) {
	rows, err := c.pool.Query(ctx, `
		WITH `+liveEntries+`
		SELECT live.entry_id, live.copies, live.hidden_at IS NOT NULL, `+liveTrackColumns+`
		FROM live WHERE live.entry_id = $2
	`, includeHidden, entryID)
	if err != nil {
		return StoreEntry{}, err
	}
	entries, err := scanStoreEntries(rows)
	if err != nil {
		return StoreEntry{}, err
	}
	if len(entries) == 0 {
		return StoreEntry{}, ErrNotFound
	}
	return entries[0], nil
}

// StoreEntriesForTracks maps each of trackIDs that is grouped into a
// listed entry to that entry as the store shows it, so a public playlist
// can link its songs to their store pages. Hidden entries and copies that
// are no longer eligible are left out.
func (c *Catalog) StoreEntriesForTracks(ctx context.Context, trackIDs []string) (map[string]StoreEntry, error) {
	found := map[string]StoreEntry{}
	if len(trackIDs) == 0 {
		return found, nil
	}
	rows, err := c.pool.Query(ctx, `
		WITH `+liveEntries+`
		SELECT et.track_id::text, live.entry_id, live.copies, live.hidden_at IS NOT NULL, `+liveTrackColumns+`
		FROM store_entry_tracks et
		JOIN tracks ON tracks.id = et.track_id AND `+storeEligible("tracks")+`
		JOIN live ON live.entry_id = et.entry_id::text
		WHERE et.track_id::text = ANY($2::text[])
	`, false, trackIDs)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var trackID string
		var entry StoreEntry
		dest := append([]any{&trackID, &entry.ID, &entry.Copies, &entry.Hidden}, trackDestinations(&entry.Track)...)
		if err := rows.Scan(dest...); err != nil {
			return nil, err
		}
		found[trackID] = entry
	}
	return found, rows.Err()
}

// OwnsCopy reports whether userID owns any copy grouped into the entry,
// listed or not: saving it would only duplicate their own track.
func (c *Catalog) OwnsCopy(ctx context.Context, entryID, userID string) (bool, error) {
	var owns bool
	err := c.pool.QueryRow(ctx, `
		SELECT EXISTS (SELECT 1 FROM store_entry_tracks et JOIN tracks ON tracks.id = et.track_id
			WHERE et.entry_id::text = $1 AND tracks.owner_id::text = $2)
	`, entryID, userID).Scan(&owns)
	return owns, err
}

// StoreArtist is an artist with listed songs.
type StoreArtist struct {
	Name       string
	TrackCount int
}

// StoreArtists lists artists by name, Limit at a time; names that differ
// only in letter variants or case are one artist.
func (c *Catalog) StoreArtists(ctx context.Context, search string, limit, offset int) ([]StoreArtist, bool, error) {
	rows, err := c.pool.Query(ctx, `
		WITH `+liveEntries+`
		SELECT min(live.artist), count(*)::int FROM live
		WHERE live.artist IS NOT NULL AND btrim(live.artist) <> ''
		  AND NOT EXISTS (SELECT 1 FROM unnest($2::text[]) w
			WHERE store_fold(live.artist) NOT LIKE '%' || store_fold(w) || '%')
		GROUP BY store_fold(live.artist)
		ORDER BY store_fold(live.artist)
		LIMIT $3 OFFSET $4
	`, false, likePatterns(search), limit+1, offset)
	if err != nil {
		return nil, false, err
	}
	defer rows.Close()
	artists := []StoreArtist{}
	for rows.Next() {
		var artist StoreArtist
		if err := rows.Scan(&artist.Name, &artist.TrackCount); err != nil {
			return nil, false, err
		}
		artists = append(artists, artist)
	}
	if err := rows.Err(); err != nil {
		return nil, false, err
	}
	if len(artists) > limit {
		return artists[:limit], true, nil
	}
	return artists, false, nil
}

// StoreAlbum is an album with listed songs, by its album artist (or the
// songs' artist when it has none).
type StoreAlbum struct {
	Name       string
	Artist     *string
	TrackCount int
}

// StoreAlbums lists albums by name, Limit at a time, optionally only one
// artist's.
func (c *Catalog) StoreAlbums(ctx context.Context, search, artist string, limit, offset int) ([]StoreAlbum, bool, error) {
	rows, err := c.pool.Query(ctx, `
		WITH `+liveEntries+`, albums AS (
			SELECT live.album, NULLIF(btrim(COALESCE(live.album_artist, live.artist, '')), '') AS artist
			FROM live WHERE live.album IS NOT NULL AND btrim(live.album) <> ''
		)
		SELECT min(album), min(artist), count(*)::int FROM albums
		WHERE NOT EXISTS (SELECT 1 FROM unnest($2::text[]) w
			WHERE store_fold(concat_ws(' ', album, artist)) NOT LIKE '%' || store_fold(w) || '%')
		  AND ($3 = '' OR store_fold(COALESCE(artist, '')) = store_fold($3))
		GROUP BY store_fold(album), store_fold(COALESCE(artist, ''))
		ORDER BY store_fold(album), store_fold(COALESCE(artist, ''))
		LIMIT $4 OFFSET $5
	`, false, likePatterns(search), artist, limit+1, offset)
	if err != nil {
		return nil, false, err
	}
	defer rows.Close()
	albums := []StoreAlbum{}
	for rows.Next() {
		var album StoreAlbum
		if err := rows.Scan(&album.Name, &album.Artist, &album.TrackCount); err != nil {
			return nil, false, err
		}
		albums = append(albums, album)
	}
	if err := rows.Err(); err != nil {
		return nil, false, err
	}
	if len(albums) > limit {
		return albums[:limit], true, nil
	}
	return albums, false, nil
}

// ReportEntry records reporterID's «گزارش تخلف» about a listed entry. A
// second open report from the same person changes nothing.
func (c *Catalog) ReportEntry(ctx context.Context, entryID, reporterID, reason string, details *string) error {
	if _, err := c.StoreEntryByID(ctx, entryID, false); err != nil {
		return err
	}
	_, err := c.pool.Exec(ctx, `
		INSERT INTO store_reports (entry_id, reporter_id, reason, details)
		VALUES ($1::text::uuid, $2::text::uuid, $3, $4)
		ON CONFLICT (entry_id, reporter_id) WHERE resolved_at IS NULL DO NOTHING
	`, entryID, reporterID, reason, details)
	return ignoreDeletedTrack(err)
}

// StoreReport is an open report as an admin reviews it.
type StoreReport struct {
	ID        int64
	Entry     StoreEntry
	Reason    string
	Details   *string
	CreatedAt time.Time
	// Reports is how many open reports the entry has.
	Reports int
}

// OpenReports lists up to limit entries with open reports, the oldest
// report first, with each entry's best copy as the admin would hear it,
// hidden or not. Reporters are not included.
func (c *Catalog) OpenReports(ctx context.Context, limit int) ([]StoreReport, error) {
	rows, err := c.pool.Query(ctx, `
		WITH `+liveEntries+`, open AS (
			SELECT DISTINCT ON (entry_id) id, entry_id::text AS entry_id, reason, details, created_at,
				count(*) OVER (PARTITION BY entry_id) AS reports
			FROM store_reports WHERE resolved_at IS NULL
			ORDER BY entry_id, created_at, id
		)
		SELECT open.id, open.reason, open.details, open.created_at, open.reports::int,
			live.entry_id, live.copies, live.hidden_at IS NOT NULL, `+liveTrackColumns+`
		FROM open JOIN live ON live.entry_id = open.entry_id
		ORDER BY open.created_at, open.id
		LIMIT $2
	`, true, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	reports := []StoreReport{}
	for rows.Next() {
		var report StoreReport
		dest := append([]any{&report.ID, &report.Reason, &report.Details, &report.CreatedAt, &report.Reports,
			&report.Entry.ID, &report.Entry.Copies, &report.Entry.Hidden}, trackDestinations(&report.Entry.Track)...)
		if err := rows.Scan(dest...); err != nil {
			return nil, err
		}
		reports = append(reports, report)
	}
	return reports, rows.Err()
}

// SetHidden hides an entry from the store, or lists it again. Either way
// its open reports are resolved by adminID. ErrNotFound for an unknown
// entry.
func (c *Catalog) SetHidden(ctx context.Context, entryID, adminID string, hidden bool) error {
	return pgx.BeginFunc(ctx, c.pool, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `
			UPDATE store_entries SET
				hidden_at = CASE WHEN $3 THEN COALESCE(hidden_at, now()) END,
				hidden_by = CASE WHEN $3 THEN $2::text::uuid END
			WHERE id::text = $1
		`, entryID, adminID, hidden)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return ErrNotFound
		}
		_, err = tx.Exec(ctx, `
			UPDATE store_reports SET resolved_at = now(), resolved_by = $2::text::uuid
			WHERE entry_id::text = $1 AND resolved_at IS NULL
		`, entryID, adminID)
		return err
	})
}

// EachMatchable calls fn for every listed store entry that has a
// fingerprint, with its best copy, for song identification without an
// account. Only listed entries are walked, so nothing private or hidden is
// ever compared; userID is not used. A non-nil error from fn stops the walk
// and is returned.
func (c *Catalog) EachMatchable(ctx context.Context, _ string, fn func(Matchable) error) error {
	rows, err := c.pool.Query(ctx, `
		WITH `+liveEntries+`
		SELECT live.entry_id, `+liveTrackColumns+`, e.points
		FROM live JOIN store_entries e ON e.id::text = live.entry_id
		WHERE e.points IS NOT NULL
	`, false)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var m Matchable
		var entryID string
		dest := append([]any{&entryID}, trackDestinations(&m.Track)...)
		if err := rows.Scan(append(dest, &m.Points)...); err != nil {
			return err
		}
		m.Source.StoreEntryID = &entryID
		if err := fn(m); err != nil {
			return err
		}
	}
	return rows.Err()
}

// StoreArtistCounts uses the same live, deduplicated public entries and
// folded names as the song and album lists. Private/hidden copies never count.
func (c *Catalog) StoreArtistCounts(ctx context.Context, artist string) (tracks, albums int, err error) {
	err = c.pool.QueryRow(ctx, `
		WITH `+liveEntries+`
		SELECT
		  count(*) FILTER (WHERE store_fold(COALESCE(live.artist, '')) = store_fold($2)
		    OR store_fold(COALESCE(live.album_artist, '')) = store_fold($2))::int,
		  count(DISTINCT store_fold(live.album)) FILTER (
		    WHERE live.album IS NOT NULL AND btrim(live.album) <> ''
		    AND store_fold(COALESCE(live.album_artist, live.artist, '')) = store_fold($2))::int
		FROM live
	`, false, artist).Scan(&tracks, &albums)
	return
}
