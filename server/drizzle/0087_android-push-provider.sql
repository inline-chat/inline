ALTER TABLE "invite_codes" DROP CONSTRAINT "invite_codes_owner_user_id_users_id_fk";
--> statement-breakpoint
ALTER TABLE "sessions" ADD COLUMN "push_notification_provider" text;--> statement-breakpoint
ALTER TABLE "invite_codes" ADD CONSTRAINT "invite_codes_owner_user_id_users_id_fk" FOREIGN KEY ("owner_user_id") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;