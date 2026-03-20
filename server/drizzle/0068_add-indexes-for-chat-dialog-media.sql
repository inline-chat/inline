CREATE INDEX "messages_chat_id_message_id_desc_idx" ON "messages" USING btree ("chat_id","message_id" DESC NULLS LAST);--> statement-breakpoint
CREATE INDEX "dialogs_user_id_chat_id_idx" ON "dialogs" USING btree ("user_id","chat_id");--> statement-breakpoint
CREATE INDEX "dialogs_user_id_peer_user_id_idx" ON "dialogs" USING btree ("user_id","peer_user_id");--> statement-breakpoint
CREATE INDEX "photo_sizes_photo_id_idx" ON "photo_sizes" USING btree ("photo_id");--> statement-breakpoint
CREATE INDEX "message_attachments_message_id_idx" ON "message_attachments" USING btree ("message_id");