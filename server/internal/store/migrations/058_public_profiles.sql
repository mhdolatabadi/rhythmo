-- Public profiles and following (#228). A profile is off until its owner
-- turns it on; an unverified owner's profile waits for an admin, like a
-- public playlist (#322). The email is never part of it.
ALTER TABLE users
    ADD COLUMN IF NOT EXISTS handle text
        CHECK (handle IS NULL OR handle ~ '^[a-z][a-z0-9_]{2,19}$'),
    ADD COLUMN IF NOT EXISTS bio text
        CHECK (bio IS NULL OR char_length(bio) BETWEEN 1 AND 160),
    ADD COLUMN IF NOT EXISTS profile_public boolean NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS profile_review text
        CHECK (profile_review IN ('pending', 'rejected')),
    ADD COLUMN IF NOT EXISTS profile_review_at timestamptz,
    -- Hides the owner's likes and newly public playlists from followers'
    -- feeds.
    ADD COLUMN IF NOT EXISTS hide_activity boolean NOT NULL DEFAULT false;

CREATE UNIQUE INDEX IF NOT EXISTS users_handle_idx ON users (handle);

-- A small avatar kept in the database: at most 256 KB of JPEG, PNG or WebP.
CREATE TABLE IF NOT EXISTS user_avatars (
    user_id uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    content_type text NOT NULL CHECK (content_type IN ('image/jpeg', 'image/png', 'image/webp')),
    data bytea NOT NULL CHECK (octet_length(data) BETWEEN 1 AND 262144),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS user_follows (
    follower_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    followee_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (follower_id, followee_id),
    CHECK (follower_id <> followee_id)
);

CREATE INDEX IF NOT EXISTS user_follows_followee_idx ON user_follows (followee_id);

CREATE TABLE IF NOT EXISTS user_blocks (
    blocker_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    blocked_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (blocker_id, blocked_id),
    CHECK (blocker_id <> blocked_id)
);

CREATE INDEX IF NOT EXISTS user_blocks_blocked_idx ON user_blocks (blocked_id);

-- «گزارش» about a profile, for the admins' moderation queue.
CREATE TABLE IF NOT EXISTS profile_reports (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    reported_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    reporter_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    reason text NOT NULL CHECK (reason IN ('spam', 'offensive', 'impersonation', 'other')),
    details text CHECK (details IS NULL OR char_length(details) <= 500),
    created_at timestamptz NOT NULL DEFAULT now(),
    resolved_at timestamptz,
    resolved_by uuid REFERENCES users(id) ON DELETE SET NULL
);

-- One open report per reporter and profile.
CREATE UNIQUE INDEX IF NOT EXISTS profile_reports_open_idx
    ON profile_reports (reported_id, reporter_id) WHERE resolved_at IS NULL;

-- When a playlist became public, for the following feed. Set on every
-- change to public, whichever code path makes it.
ALTER TABLE playlists ADD COLUMN IF NOT EXISTS public_since timestamptz;
UPDATE playlists SET public_since = updated_at WHERE is_public AND public_since IS NULL;

CREATE OR REPLACE FUNCTION playlists_public_since() RETURNS trigger AS $$
BEGIN
    IF NEW.is_public AND (TG_OP = 'INSERT' OR NOT OLD.is_public) THEN
        NEW.public_since := now();
    ELSIF NOT NEW.is_public THEN
        NEW.public_since := NULL;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS playlists_public_since ON playlists;
CREATE TRIGGER playlists_public_since BEFORE INSERT OR UPDATE OF is_public ON playlists
    FOR EACH ROW EXECUTE FUNCTION playlists_public_since();

CREATE INDEX IF NOT EXISTS playlists_owner_public_idx
    ON playlists (owner_id, public_since DESC) WHERE is_public;

-- Admins review profiles in the same queue as playlists and tracks.
ALTER TABLE publication_review_audit DROP CONSTRAINT IF EXISTS publication_review_audit_kind_check;
ALTER TABLE publication_review_audit ADD CONSTRAINT publication_review_audit_kind_check
    CHECK (kind IN ('playlist', 'track', 'profile'));

CREATE INDEX IF NOT EXISTS users_profile_review_pending_idx
    ON users (profile_review_at) WHERE profile_review = 'pending';
