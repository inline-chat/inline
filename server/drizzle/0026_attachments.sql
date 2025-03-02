CREATE TABLE IF NOT EXISTS "external_tasks" (
	"id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY (sequence name "external_tasks_id_seq" INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 START WITH 1 CACHE 1),
	"application" text NOT NULL,
	"task_id" text NOT NULL,
	"status" text NOT NULL,
	"assigned_user_id" bigint,
	"number" text,
	"url" text,
	"title" "bytea",
	"title_iv" "bytea",
	"title_tag" "bytea",
	"date" timestamp (3) DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "message_attachments" (
	"id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY (sequence name "message_attachments_id_seq" INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 START WITH 1 CACHE 1),
	"message_id" bigint,
	"external_task_id" bigint
);
--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "external_tasks" ADD CONSTRAINT "external_tasks_assigned_user_id_users_id_fk" FOREIGN KEY ("assigned_user_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "message_attachments" ADD CONSTRAINT "message_attachments_message_id_messages_global_id_fk" FOREIGN KEY ("message_id") REFERENCES "public"."messages"("global_id") ON DELETE no action ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "message_attachments" ADD CONSTRAINT "message_attachments_external_task_id_external_tasks_id_fk" FOREIGN KEY ("external_task_id") REFERENCES "public"."external_tasks"("id") ON DELETE no action ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
