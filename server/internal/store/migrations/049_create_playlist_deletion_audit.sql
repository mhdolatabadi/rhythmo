-- Admins delete a public playlist (#320); what was deleted, and by whom,
-- stays on record after the playlist is gone.
CREATE TABLE IF NOT EXISTS playlist_deletion_audit (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    playlist_id uuid NOT NULL,
    owner_id uuid NOT NULL,
    name text NOT NULL,
    actor_id uuid NOT NULL,
    deleted_at timestamptz NOT NULL DEFAULT now()
);
