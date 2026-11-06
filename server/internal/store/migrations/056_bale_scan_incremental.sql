-- Incremental catalog scans: once the whole channel history has been read,
-- a refresh only walks back to the newest post the last complete pass saw.
--  synced_until: newest message date covered by a completed pass.
--  floor_date:   the current pass stops once its cursor reaches this date.
--  pass_newest:  newest message date seen by the current pass.
ALTER TABLE bale_catalog_scan
 ADD COLUMN synced_until bigint NOT NULL DEFAULT 0,
 ADD COLUMN floor_date bigint NOT NULL DEFAULT 0,
 ADD COLUMN pass_newest bigint NOT NULL DEFAULT 0;
-- A scan that already finished covered everything up to its newest post.
UPDATE bale_catalog_scan SET synced_until=(SELECT COALESCE(max(message_date),0) FROM bale_catalog_posts) WHERE state='done';
