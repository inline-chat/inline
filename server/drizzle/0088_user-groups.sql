CREATE TABLE "chat_participant_groups" (
	"id" serial PRIMARY KEY NOT NULL,
	"chat_id" integer NOT NULL,
	"group_id" integer NOT NULL,
	"date" timestamp (3) DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "user_group_members" (
	"id" serial PRIMARY KEY NOT NULL,
	"group_id" integer NOT NULL,
	"user_id" integer NOT NULL,
	"date" timestamp (3) DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "user_groups" (
	"id" serial PRIMARY KEY NOT NULL,
	"space_id" integer NOT NULL,
	"name" varchar(80) NOT NULL,
	"description" text,
	"created_by" integer NOT NULL,
	"date" timestamp (3) DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "chat_participant_groups" ADD CONSTRAINT "chat_participant_groups_chat_id_chats_id_fk" FOREIGN KEY ("chat_id") REFERENCES "public"."chats"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "chat_participant_groups" ADD CONSTRAINT "chat_participant_groups_group_id_user_groups_id_fk" FOREIGN KEY ("group_id") REFERENCES "public"."user_groups"("id") ON DELETE restrict ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "user_group_members" ADD CONSTRAINT "user_group_members_group_id_user_groups_id_fk" FOREIGN KEY ("group_id") REFERENCES "public"."user_groups"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "user_group_members" ADD CONSTRAINT "user_group_members_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "user_groups" ADD CONSTRAINT "user_groups_space_id_spaces_id_fk" FOREIGN KEY ("space_id") REFERENCES "public"."spaces"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "user_groups" ADD CONSTRAINT "user_groups_created_by_users_id_fk" FOREIGN KEY ("created_by") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "chat_participant_groups_chat_group_unique" ON "chat_participant_groups" USING btree ("chat_id","group_id");--> statement-breakpoint
CREATE INDEX "chat_participant_groups_chat_id_idx" ON "chat_participant_groups" USING btree ("chat_id");--> statement-breakpoint
CREATE INDEX "chat_participant_groups_group_id_idx" ON "chat_participant_groups" USING btree ("group_id");--> statement-breakpoint
CREATE UNIQUE INDEX "user_group_members_group_user_unique" ON "user_group_members" USING btree ("group_id","user_id");--> statement-breakpoint
CREATE INDEX "user_group_members_group_id_idx" ON "user_group_members" USING btree ("group_id");--> statement-breakpoint
CREATE INDEX "user_group_members_user_id_idx" ON "user_group_members" USING btree ("user_id");--> statement-breakpoint
CREATE UNIQUE INDEX "user_groups_space_name_unique" ON "user_groups" USING btree ("space_id",lower("name"));--> statement-breakpoint
CREATE INDEX "user_groups_space_id_idx" ON "user_groups" USING btree ("space_id");--> statement-breakpoint
CREATE INDEX "user_groups_created_by_idx" ON "user_groups" USING btree ("created_by");