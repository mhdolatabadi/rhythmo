-- Users ask for more storage and admins decide (#208). One open request
-- per account; every decision keeps who made it and when, and an approval
-- also lands in account_storage_quota_audit.
CREATE TABLE IF NOT EXISTS storage_requests (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    requested_bytes bigint NOT NULL CHECK (requested_bytes > 0 AND requested_bytes <= 1099511627776),
    reason text NOT NULL DEFAULT '' CHECK (char_length(reason) <= 300),
    status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected')),
    granted_bytes bigint,
    decision_reason text CHECK (decision_reason IS NULL OR char_length(decision_reason) <= 300),
    decided_by uuid,
    decided_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS storage_requests_one_open
    ON storage_requests (account_id) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS storage_requests_account
    ON storage_requests (account_id, created_at DESC);
