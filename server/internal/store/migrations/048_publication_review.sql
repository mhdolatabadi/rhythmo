-- Publishing needs an admin's approval unless the owner is verified (#322).
-- An unverified owner's request to list a playlist publicly or publish a
-- track is kept as 'pending' until an admin approves (which sets is_public
-- or published_at) or rejects it ('rejected', shown to the owner). NULL
-- means no open request. Content already public stays public.
ALTER TABLE playlists ADD COLUMN IF NOT EXISTS public_review text
    CHECK (public_review IN ('pending', 'rejected'));
ALTER TABLE playlists ADD COLUMN IF NOT EXISTS public_review_at timestamptz;
ALTER TABLE tracks ADD COLUMN IF NOT EXISTS publish_review text
    CHECK (publish_review IN ('pending', 'rejected'));
ALTER TABLE tracks ADD COLUMN IF NOT EXISTS publish_review_at timestamptz;

CREATE INDEX IF NOT EXISTS playlists_public_review_pending
    ON playlists (public_review_at) WHERE public_review = 'pending';
CREATE INDEX IF NOT EXISTS tracks_publish_review_pending
    ON tracks (publish_review_at) WHERE publish_review = 'pending';

-- Every admin decision on a request, for both kinds.
CREATE TABLE IF NOT EXISTS publication_review_audit (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    kind text NOT NULL CHECK (kind IN ('playlist', 'track')),
    subject_id uuid NOT NULL,
    actor_id uuid NOT NULL,
    approved boolean NOT NULL,
    changed_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS publication_review_audit_subject
    ON publication_review_audit (kind, subject_id, changed_at DESC);
