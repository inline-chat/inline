DROP INDEX "agent_grants_bot_subject_unique";--> statement-breakpoint
ALTER TABLE "agent_grants" ALTER COLUMN "subject_user_id" DROP NOT NULL;--> statement-breakpoint
ALTER TABLE "agent_grants" ADD COLUMN "subject_space_id" integer;--> statement-breakpoint
ALTER TABLE "agent_grants" ADD COLUMN "subject_group_id" integer;--> statement-breakpoint
ALTER TABLE "agent_grants" ADD CONSTRAINT "agent_grants_subject_space_id_spaces_id_fk" FOREIGN KEY ("subject_space_id") REFERENCES "public"."spaces"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "agent_grants" ADD CONSTRAINT "agent_grants_subject_group_id_user_groups_id_fk" FOREIGN KEY ("subject_group_id") REFERENCES "public"."user_groups"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "agent_grants_bot_space_unique" ON "agent_grants" USING btree ("bot_user_id","subject_space_id") WHERE "agent_grants"."subject_space_id" is not null;--> statement-breakpoint
CREATE UNIQUE INDEX "agent_grants_bot_group_unique" ON "agent_grants" USING btree ("bot_user_id","subject_group_id") WHERE "agent_grants"."subject_group_id" is not null;--> statement-breakpoint
CREATE INDEX "agent_grants_subject_space_idx" ON "agent_grants" USING btree ("subject_space_id");--> statement-breakpoint
CREATE INDEX "agent_grants_subject_group_idx" ON "agent_grants" USING btree ("subject_group_id");--> statement-breakpoint
CREATE UNIQUE INDEX "agent_grants_bot_subject_unique" ON "agent_grants" USING btree ("bot_user_id","subject_user_id") WHERE "agent_grants"."subject_user_id" is not null;--> statement-breakpoint
ALTER TABLE "agent_grants" ADD CONSTRAINT "agent_grants_one_subject" CHECK (num_nonnulls("agent_grants"."subject_user_id", "agent_grants"."subject_space_id", "agent_grants"."subject_group_id") = 1);