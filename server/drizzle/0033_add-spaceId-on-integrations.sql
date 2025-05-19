ALTER TABLE "integrations" ALTER COLUMN "user_id" DROP NOT NULL;--> statement-breakpoint
ALTER TABLE "integrations" ADD COLUMN "space_id" integer;--> statement-breakpoint
ALTER TABLE "integrations" ADD CONSTRAINT "integrations_space_id_spaces_id_fk" FOREIGN KEY ("space_id") REFERENCES "public"."spaces"("id") ON DELETE no action ON UPDATE no action;