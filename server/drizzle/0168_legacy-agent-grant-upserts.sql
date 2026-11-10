-- Keep the deployed predecessor's ON CONFLICT (bot_user_id, subject_user_id)
-- valid during overlap and rollback. NULL user subjects stay distinct, so space
-- and group grants continue using their separate unique indexes.
DROP INDEX "agent_grants_bot_subject_unique";--> statement-breakpoint
CREATE UNIQUE INDEX "agent_grants_bot_subject_unique" ON "agent_grants" USING btree ("bot_user_id","subject_user_id");
