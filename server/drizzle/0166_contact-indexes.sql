CREATE INDEX "users_bot_creator_id_idx" ON "users" USING btree ("bot_creator_id") WHERE "users"."bot_creator_id" is not null;--> statement-breakpoint
CREATE INDEX "chat_participants_user_id_idx" ON "chat_participants" USING btree ("user_id");--> statement-breakpoint
CREATE INDEX "chats_max_user_id_idx" ON "chats" USING btree ("max_user_id");