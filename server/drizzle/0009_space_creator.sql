ALTER TABLE "spaces" ALTER COLUMN "date" DROP DEFAULT;--> statement-breakpoint
ALTER TABLE "spaces" ALTER COLUMN "date" DROP NOT NULL;--> statement-breakpoint
ALTER TABLE "spaces" ADD COLUMN "creatorId" integer;--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "spaces" ADD CONSTRAINT "spaces_creatorId_users_id_fk" FOREIGN KEY ("creatorId") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
