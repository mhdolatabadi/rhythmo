-- Channels (#428): a public playlist is a music channel with a short
-- description, admins besides its owner, and subscribers who can mute it.
-- An admin is a member who may also edit the channel's name and
-- description, take out anyone's tracks and remove other members; only the
-- owner makes or unmakes admins.
ALTER TABLE playlists ADD COLUMN IF NOT EXISTS description text NOT NULL DEFAULT '';

ALTER TABLE playlist_members ADD COLUMN IF NOT EXISTS role text NOT NULL DEFAULT 'member'
    CHECK (role IN ('member', 'admin'));

-- A muted subscription still collects notices in the inbox, but they are
-- left out of the unread badge and are not pushed through the bots.
ALTER TABLE playlist_subscriptions ADD COLUMN IF NOT EXISTS muted_at timestamptz;
