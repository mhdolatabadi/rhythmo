package store

import "context"

// AudioInfo is a file's format as stored (#383); nil is unknown.
type AudioInfo struct {
	Codec       *string
	BitrateKbps *int32
	SampleRate  *int32
	BitDepth    *int32
}

// AudioInfoJob is a ready track whose format has not been read yet.
type AudioInfoJob struct {
	ID         string
	StorageKey string
	FileName   string
	SizeBytes  int64
}

// PendingAudioInfo lists up to limit ready tracks not scanned yet, oldest
// first.
func (t *Tracks) PendingAudioInfo(ctx context.Context, limit int) ([]AudioInfoJob, error) {
	rows, err := t.pool.Query(ctx, `
		SELECT id::text, storage_key, file_name, size_bytes FROM tracks
		WHERE status = 'ready' AND audio_scanned_at IS NULL
		ORDER BY created_at, id
		LIMIT $1
	`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	jobs := []AudioInfoJob{}
	for rows.Next() {
		var job AudioInfoJob
		if err := rows.Scan(&job.ID, &job.StorageKey, &job.FileName, &job.SizeBytes); err != nil {
			return nil, err
		}
		jobs = append(jobs, job)
	}
	return jobs, rows.Err()
}

// SetAudioInfo records what scanning storageKey found and fills in the
// track's length when it had none; an empty AudioInfo marks the track as
// scanned with an unknown format. A track whose stored object changed
// meanwhile is ErrNotFound and is scanned again.
func (t *Tracks) SetAudioInfo(ctx context.Context, trackID, storageKey string, info AudioInfo, durationMS *int32) error {
	tag, err := t.pool.Exec(ctx, `
		UPDATE tracks SET audio_codec = $3, audio_bitrate_kbps = $4,
			audio_sample_rate = $5, audio_bit_depth = $6,
			duration_ms = COALESCE(duration_ms, $7), audio_scanned_at = now()
		WHERE id::text = $1 AND storage_key = $2
	`, trackID, storageKey, info.Codec, info.BitrateKbps, info.SampleRate, info.BitDepth, durationMS)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}
