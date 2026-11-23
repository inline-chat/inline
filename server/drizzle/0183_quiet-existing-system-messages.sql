-- Unread counts start counting system messages; each kind now chooses whether it counts
-- (counts_as_unread). Rows written before that never counted, so they stay quiet: no old
-- system message becomes unread. A few hundred rows; the scan is a one-off.
UPDATE "messages"
SET "counts_as_unread" = false
WHERE "system_message_encrypted" IS NOT NULL
  AND "counts_as_unread" IS TRUE;
