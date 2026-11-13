-- A public display name (#378). Public pages, link previews and other
-- people's views of a playlist show it instead of any part of the owner's
-- email; NULL means the owner has not picked one.
ALTER TABLE users ADD COLUMN IF NOT EXISTS display_name text
    CHECK (display_name IS NULL OR char_length(display_name) BETWEEN 1 AND 40);
