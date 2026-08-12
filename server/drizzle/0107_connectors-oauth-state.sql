CREATE TABLE "integration_oauth_states" (
	"state_hash" varchar(64) PRIMARY KEY NOT NULL,
	"provider" varchar(32) NOT NULL,
	"callback_scheme" varchar(32) NOT NULL,
	"user_id" integer NOT NULL,
	"space_id" integer,
	"expires_at" timestamp (3) NOT NULL,
	"date" timestamp (3) DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "integration_oauth_states" ADD CONSTRAINT "integration_oauth_states_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "integration_oauth_states" ADD CONSTRAINT "integration_oauth_states_space_id_spaces_id_fk" FOREIGN KEY ("space_id") REFERENCES "public"."spaces"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "integration_oauth_states_user" ON "integration_oauth_states" USING btree ("user_id");--> statement-breakpoint
CREATE INDEX "integration_oauth_states_expires" ON "integration_oauth_states" USING btree ("expires_at");
