-- #276: a collaborative playlist may have a shared goal, a number of songs
-- its members fill it up to together; progress is its real track count.
ALTER TABLE playlists ADD COLUMN IF NOT EXISTS goal_tracks integer
    CHECK (goal_tracks IS NULL OR goal_tracks BETWEEN 1 AND 1000);

-- Occasion collections are each listener's own: they file the playlists
-- they own or joined under names they choose, such as «سفر» or «ورزش».
-- Nothing is suggested or inferred, and other members never see them.
CREATE TABLE IF NOT EXISTS playlist_occasions (
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    playlist_id uuid NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
    occasion text NOT NULL CHECK (char_length(occasion) BETWEEN 1 AND 40),
    PRIMARY KEY (user_id, playlist_id)
);
CREATE INDEX IF NOT EXISTS playlist_occasions_playlist_idx ON playlist_occasions (playlist_id);
