-- Why an admin turned down a request to list a playlist publicly (#207),
-- shown to its owner; NULL when no reason was given or the request is not
-- rejected.
ALTER TABLE playlists ADD COLUMN IF NOT EXISTS public_review_reason text
    CHECK (public_review_reason IS NULL OR char_length(public_review_reason) <= 300);
