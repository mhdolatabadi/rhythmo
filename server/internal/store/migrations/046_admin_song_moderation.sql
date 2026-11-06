ALTER TABLE tracks ADD COLUMN moderated_at timestamptz;
ALTER TABLE tracks ADD COLUMN moderated_by uuid;
CREATE TABLE admin_store_actions (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 entry_id uuid NOT NULL REFERENCES store_entries(id) ON DELETE CASCADE,
 actor_id uuid NOT NULL, action text NOT NULL CHECK(action IN ('remove','dismiss')),
 created_at timestamptz NOT NULL DEFAULT now()
);
