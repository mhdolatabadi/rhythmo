-- A cover the owner chose for a track (#225), kept as the normalized JPEG the
-- API produced (at most 512 px). It is shown instead of the embedded artwork
-- and written into the file by the tag writer, so downloads carry it. It goes
-- with its track.
CREATE TABLE track_covers (
    track_id uuid PRIMARY KEY REFERENCES tracks (id) ON DELETE CASCADE,
    image bytea NOT NULL CHECK (octet_length(image) BETWEEN 1 AND 2097152),
    updated_at timestamptz NOT NULL DEFAULT now()
);
