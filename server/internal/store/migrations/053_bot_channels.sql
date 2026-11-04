-- Messenger channels synced into rhythmo channels (#430). An admin of a
-- rhythmo channel asks for a one-time code, makes the bot an admin of their
-- Telegram or Bale channel and posts the code there; from then on every
-- audio posted in that channel is imported into the linking person's
-- library and added to the rhythmo channel, which notifies its subscribers.
--
-- A link code with a playlist links a channel instead of a private chat.
ALTER TABLE bot_link_codes ADD COLUMN IF NOT EXISTS playlist_id uuid REFERENCES playlists(id) ON DELETE CASCADE;

CREATE TABLE IF NOT EXISTS bot_channels (
    provider text NOT NULL,
    chat_id text NOT NULL,
    playlist_id uuid NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
    -- Whose library and quota the posts go to; the link stops working once
    -- they no longer own or administer the playlist.
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    title text NOT NULL DEFAULT '',
    linked_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (provider, chat_id)
);

CREATE INDEX IF NOT EXISTS bot_channels_playlist_idx ON bot_channels (playlist_id, linked_at);

-- The rhythmo channel a channel post's import goes to, if any.
ALTER TABLE bot_imports ADD COLUMN IF NOT EXISTS playlist_id uuid REFERENCES playlists(id) ON DELETE SET NULL;
