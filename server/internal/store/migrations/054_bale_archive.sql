-- Curated public-archive imports. Stable post IDs, not expiring download URLs,
-- are the identity. Topic playlists are private until the owner shares them.
CREATE TABLE bale_archive_topics (
 owner_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 channel text NOT NULL,
 topic_key text NOT NULL,
 playlist_id uuid NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
 PRIMARY KEY(owner_id, channel, topic_key)
);
CREATE TABLE bale_archive_posts (
 owner_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 channel text NOT NULL,
 message_id text NOT NULL,
 message_date bigint NOT NULL,
 source_url text NOT NULL,
 caption text NOT NULL,
 topic text NOT NULL,
 session_number integer NOT NULL CHECK(session_number >= 0),
 duration_ms bigint NOT NULL CHECK(duration_ms >= 0),
 import_id uuid NOT NULL UNIQUE REFERENCES bot_imports(id) ON DELETE CASCADE,
 PRIMARY KEY(owner_id, channel, message_id)
);
