ALTER TABLE users ADD COLUMN storage_quota_bytes bigint CHECK(storage_quota_bytes > 0 AND storage_quota_bytes <= 1099511627776);
CREATE TABLE account_storage_quota_audit (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 account_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 actor_id uuid NOT NULL, previous_bytes bigint NOT NULL, quota_bytes bigint NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now()
);
