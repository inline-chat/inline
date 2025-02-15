ALTER TABLE "users" ADD COLUMN "username" varchar(256);--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "users_username_unique" ON "users" USING btree (lower("username"));