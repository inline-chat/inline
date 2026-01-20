ALTER TABLE "admin_sessions" RENAME TO "superadmin_sessions";--> statement-breakpoint
ALTER TABLE "superadmin_sessions" DROP CONSTRAINT "admin_sessions_token_hash_unique";--> statement-breakpoint
ALTER TABLE "superadmin_sessions" DROP CONSTRAINT "admin_sessions_user_id_users_id_fk";
--> statement-breakpoint
ALTER TABLE "superadmin_sessions" ADD CONSTRAINT "superadmin_sessions_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "superadmin_sessions" ADD CONSTRAINT "superadmin_sessions_token_hash_unique" UNIQUE("token_hash");