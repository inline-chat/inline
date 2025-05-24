CREATE TABLE "user_settings" (
	"user_id" integer PRIMARY KEY NOT NULL,
	"general_encrypted" "bytea",
	"general_iv" "bytea",
	"general_tag" "bytea"
);
--> statement-breakpoint
ALTER TABLE "user_settings" ADD CONSTRAINT "user_settings_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;