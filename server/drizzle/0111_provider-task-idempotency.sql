ALTER TABLE "external_tasks" ADD COLUMN "source_message_id" bigint;--> statement-breakpoint
ALTER TABLE "external_tasks" ADD CONSTRAINT "external_tasks_source_message_id_messages_global_id_fk" FOREIGN KEY ("source_message_id") REFERENCES "public"."messages"("global_id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "external_tasks_provider_user_source_space_unique" ON "external_tasks" USING btree ("source_message_id","assigned_user_id","application","connector_space_id");
