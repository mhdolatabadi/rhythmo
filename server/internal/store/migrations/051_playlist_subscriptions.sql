-- Public playlists work like channels (#414): listeners subscribe, and new
-- tracks notify them. One subscription per user per playlist; the primary
-- key makes subscribing idempotent. While a playlist isn't public its
-- subscriptions are kept but nobody is notified.
CREATE TABLE IF NOT EXISTS playlist_subscriptions (
    playlist_id uuid NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (playlist_id, user_id)
);

CREATE INDEX IF NOT EXISTS playlist_subscriptions_user_idx ON playlist_subscriptions (user_id, created_at DESC);

-- A subscriber's notice that tracks were added to a playlist. Additions
-- while it is unread update the same row, so each playlist has at most one
-- unread notice per user, like a channel's unread counter. track_id is the
-- latest track added. pushed_at is when it was last sent out of the app,
-- through the user's linked messenger bots.
CREATE TABLE IF NOT EXISTS playlist_notifications (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    playlist_id uuid NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
    track_id uuid REFERENCES tracks(id) ON DELETE SET NULL,
    track_count int NOT NULL CHECK (track_count > 0),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    read_at timestamptz,
    pushed_at timestamptz
);

CREATE UNIQUE INDEX IF NOT EXISTS playlist_notifications_unread_idx
    ON playlist_notifications (user_id, playlist_id) WHERE read_at IS NULL;
CREATE INDEX IF NOT EXISTS playlist_notifications_user_idx
    ON playlist_notifications (user_id, updated_at DESC, id);
CREATE INDEX IF NOT EXISTS playlist_notifications_push_idx
    ON playlist_notifications (updated_at) WHERE read_at IS NULL;
