-- A channel-wide index and durable, per-owner topic import requests. Media
-- download URLs are deliberately not persisted: the worker refreshes them.
CREATE TABLE bale_catalog_posts (
 message_id text PRIMARY KEY,
 message_date bigint NOT NULL,
 title text NOT NULL, topic text NOT NULL, topic_key text NOT NULL,
 session_number integer NOT NULL DEFAULT 0,
 file_name text NOT NULL, size_bytes bigint NOT NULL,
 duration_ms bigint NOT NULL, caption text NOT NULL, source_url text NOT NULL
);
CREATE INDEX bale_catalog_topic_idx ON bale_catalog_posts(topic_key,session_number,message_date);
CREATE TABLE bale_catalog_scan (
 id boolean PRIMARY KEY DEFAULT true CHECK(id),
 state text NOT NULL DEFAULT 'idle' CHECK(state IN('idle','scanning','done')),
 before_date bigint NOT NULL DEFAULT 0,
 scanned_posts bigint NOT NULL DEFAULT 0,
 lease_token uuid, lease_until timestamptz,
 error text, updated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO bale_catalog_scan(id) VALUES(true);
CREATE TABLE bale_topic_requests (
 owner_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 topic_key text NOT NULL,
 state text NOT NULL CHECK(state IN('running','done','blocked')),
 error text, requested_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(owner_id,topic_key)
);
-- Recognize previously imported subjects immediately, before the historical
-- scan reaches their source posts. The live scan later refreshes these rows.
INSERT INTO bale_catalog_posts(message_id,message_date,title,topic,topic_key,session_number,file_name,size_bytes,duration_ms,caption,source_url)
SELECT DISTINCT ON(p.message_id) p.message_id,p.message_date,COALESCE(i.title,i.file_name),p.topic,t.topic_key,p.session_number,i.file_name,i.size_bytes,p.duration_ms,p.caption,p.source_url
FROM bale_archive_posts p JOIN bot_imports i ON i.id=p.import_id
JOIN bale_archive_topics t ON t.owner_id=p.owner_id AND t.playlist_id=i.playlist_id
ORDER BY p.message_id,i.created_at DESC;
