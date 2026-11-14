-- Each file's format as stored (#383): codec, bitrate, sample rate and bit
-- depth, read once from its headers. NULL is unknown; audio_scanned_at stays
-- NULL until the scanner has read the file, so existing tracks are
-- backfilled by the same job.
ALTER TABLE tracks
    ADD COLUMN audio_codec text,
    ADD COLUMN audio_bitrate_kbps integer,
    ADD COLUMN audio_sample_rate integer,
    ADD COLUMN audio_bit_depth integer,
    ADD COLUMN audio_scanned_at timestamptz;

CREATE INDEX tracks_audio_unscanned ON tracks (created_at)
    WHERE status = 'ready' AND audio_scanned_at IS NULL;
