CREATE TABLE "invite_codes" (
	"id" serial PRIMARY KEY NOT NULL,
	"code" varchar(8) NOT NULL,
	"owner_user_id" integer,
	"created_by_user_id" integer,
	"redeemed_by_user_id" integer,
	"note" varchar(256),
	"date" timestamp (3) DEFAULT now() NOT NULL,
	"redeemed_at" timestamp (3)
);
--> statement-breakpoint
ALTER TABLE "invite_codes" ADD CONSTRAINT "invite_codes_owner_user_id_users_id_fk" FOREIGN KEY ("owner_user_id") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "invite_codes" ADD CONSTRAINT "invite_codes_created_by_user_id_users_id_fk" FOREIGN KEY ("created_by_user_id") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "invite_codes" ADD CONSTRAINT "invite_codes_redeemed_by_user_id_users_id_fk" FOREIGN KEY ("redeemed_by_user_id") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "invite_codes_code_unique" ON "invite_codes" USING btree ("code");--> statement-breakpoint
CREATE INDEX "invite_codes_owner_user_id_idx" ON "invite_codes" USING btree ("owner_user_id");--> statement-breakpoint
CREATE INDEX "invite_codes_redeemed_by_user_id_idx" ON "invite_codes" USING btree ("redeemed_by_user_id");