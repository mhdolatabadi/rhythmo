-- Password reset (#380): one outstanding emailed code per account.
CREATE TABLE IF NOT EXISTS password_reset_codes (
    user_id uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    email text NOT NULL,
    code_hash text NOT NULL,
    expires_at timestamptz NOT NULL,
    attempts integer NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now()
);

-- Sign-ups waiting for their emailed code (#219). The account is only
-- created once the code is confirmed, so registering answers the same way
-- whether or not the address already has an account.
CREATE TABLE IF NOT EXISTS pending_registrations (
    email text PRIMARY KEY,
    password_hash text NOT NULL,
    code_hash text NOT NULL,
    expires_at timestamptz NOT NULL,
    attempts integer NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS pending_registrations_expires ON pending_registrations (expires_at);
