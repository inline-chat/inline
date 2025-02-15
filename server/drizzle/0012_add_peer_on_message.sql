ALTER TABLE "messages" ADD COLUMN "peer_user_id" integer;--> statement-breakpoint
DO $$ BEGIN
 ALTER TABLE "messages" ADD CONSTRAINT "messages_peer_user_id_users_id_fk" FOREIGN KEY ("peer_user_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;
EXCEPTION
 WHEN duplicate_object THEN null;
END $$;
