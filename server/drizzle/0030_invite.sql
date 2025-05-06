ALTER TABLE "users" ADD COLUMN "pending_setup" boolean DEFAULT false;--> statement-breakpoint
ALTER TABLE "members" ADD COLUMN "invited_by" integer;--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "members" ADD CONSTRAINT "members_invited_by_users_id_fk" FOREIGN KEY ("invited_by") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
