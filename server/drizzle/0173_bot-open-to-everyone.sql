ALTER TABLE "agent_settings" ADD COLUMN "open_to_everyone" boolean DEFAULT false NOT NULL;--> statement-breakpoint
-- Bots that exist today stay reachable by everyone, as they were before the
-- server enforced access lists, until their owner turns it off. Bots run by
-- an Inline bridge (a runtime seen in the last 30 days) already answer only
-- their owner and access list, so they become private. A bot whose bridge
-- has been gone longer than that may be serving people some other way now, so
-- it stays open; it closes if its bridge comes back. Bots created from now on
-- are private.
INSERT INTO "agent_settings" ("bot_user_id", "open_to_everyone")
SELECT u."id", true
FROM "users" u
WHERE u."bot" IS TRUE
  AND u."deleted" IS NOT TRUE
  AND u."bot_creator_id" IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM "agent_runtimes" r
    WHERE r."bot_user_id" = u."id" AND r."last_seen_at" > now() - interval '30 days'
  )
ON CONFLICT ("bot_user_id") DO UPDATE SET "open_to_everyone" = true;
