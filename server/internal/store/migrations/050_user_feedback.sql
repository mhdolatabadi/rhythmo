CREATE TABLE user_feedback (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 kind text NOT NULL CHECK (kind IN ('bug','feature','message')),
 subject text NOT NULL CHECK (char_length(subject) BETWEEN 1 AND 160),
 body text NOT NULL CHECK (char_length(body) BETWEEN 1 AND 5000),
 created_at timestamptz NOT NULL DEFAULT now(),
 resolved_at timestamptz,
 resolved_by uuid REFERENCES users(id) ON DELETE SET NULL
);
CREATE INDEX user_feedback_open ON user_feedback(created_at, id) WHERE resolved_at IS NULL;
