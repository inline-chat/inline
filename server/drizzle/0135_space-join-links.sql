CREATE TABLE "space_invite_links" (
	"id" serial PRIMARY KEY NOT NULL,
	"space_id" integer NOT NULL,
	"token_hash" "bytea" NOT NULL,
	"token_encrypted" "bytea" NOT NULL,
	"created_by_user_id" integer,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"expires_at" timestamp with time zone NOT NULL,
	"revoked_at" timestamp with time zone,
	CONSTRAINT "space_invite_links_token_hash_length" CHECK (octet_length("space_invite_links"."token_hash") = 32),
	CONSTRAINT "space_invite_links_expiry_check" CHECK ("space_invite_links"."expires_at" > "space_invite_links"."created_at")
);
--> statement-breakpoint
CREATE TABLE "space_join_blocks" (
	"space_id" integer NOT NULL,
	"user_id" integer NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "space_join_blocks_pkey" PRIMARY KEY("space_id","user_id")
);
--> statement-breakpoint
ALTER TABLE "spaces" ADD COLUMN "can_public_join" boolean DEFAULT false NOT NULL;--> statement-breakpoint
ALTER TABLE "space_invite_links" ADD CONSTRAINT "space_invite_links_space_id_spaces_id_fk" FOREIGN KEY ("space_id") REFERENCES "public"."spaces"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "space_invite_links" ADD CONSTRAINT "space_invite_links_created_by_user_id_users_id_fk" FOREIGN KEY ("created_by_user_id") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "space_join_blocks" ADD CONSTRAINT "space_join_blocks_space_id_spaces_id_fk" FOREIGN KEY ("space_id") REFERENCES "public"."spaces"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "space_join_blocks" ADD CONSTRAINT "space_join_blocks_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "space_invite_links_token_hash_unique" ON "space_invite_links" USING btree ("token_hash");--> statement-breakpoint
CREATE UNIQUE INDEX "space_invite_links_active_space_unique" ON "space_invite_links" USING btree ("space_id") WHERE "space_invite_links"."revoked_at" is null;--> statement-breakpoint
CREATE INDEX "space_invite_links_space_id_idx" ON "space_invite_links" USING btree ("space_id");--> statement-breakpoint
CREATE INDEX "space_invite_links_created_by_user_id_idx" ON "space_invite_links" USING btree ("created_by_user_id");--> statement-breakpoint
CREATE INDEX "space_join_blocks_user_id_idx" ON "space_join_blocks" USING btree ("user_id");--> statement-breakpoint
ALTER TABLE "spaces" ADD CONSTRAINT "spaces_public_join_handle_check" CHECK (not "spaces"."can_public_join" or ("spaces"."is_public" and "spaces"."handle" is not null and "spaces"."handle" ~ '^[A-Za-z0-9][A-Za-z0-9_-]{1,63}$'));--> statement-breakpoint
UPDATE "spaces"
SET "can_public_join" = true
WHERE lower("handle") = 'townhall'
	AND "is_public" = true
	AND "deleted" IS NULL;
