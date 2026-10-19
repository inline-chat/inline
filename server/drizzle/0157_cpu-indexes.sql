DROP INDEX IF EXISTS "space_url_preview_exclusions_space_host_idx";--> statement-breakpoint
DROP INDEX IF EXISTS "chat_participant_groups_chat_id_idx";--> statement-breakpoint
DROP INDEX IF EXISTS "user_group_members_group_id_idx";--> statement-breakpoint
DROP INDEX IF EXISTS "user_groups_space_id_idx";--> statement-breakpoint
DROP INDEX IF EXISTS "agent_session_messages_session_idx";--> statement-breakpoint
CREATE INDEX "chats_last_update_date_idx" ON "chats" USING btree ("last_update_date");--> statement-breakpoint
CREATE INDEX "messages_pinned_idx" ON "messages" USING btree ("chat_id","pinned_at" DESC NULLS LAST,"message_id" DESC NULLS LAST) WHERE "messages"."pinned_at" is not null;