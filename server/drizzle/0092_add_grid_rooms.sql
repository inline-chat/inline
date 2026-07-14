CREATE TABLE "grid_presence" (
	"user_id" integer PRIMARY KEY NOT NULL,
	"room_id" integer NOT NULL,
	"owner_session_id" integer NOT NULL,
	"joined_at" timestamp (3) DEFAULT now() NOT NULL,
	"lease_expires_at" timestamp (3) NOT NULL
);
--> statement-breakpoint
CREATE TABLE "grid_rooms" (
	"id" serial PRIMARY KEY NOT NULL,
	"space_id" integer NOT NULL,
	"created_by_user_id" integer NOT NULL,
	"title" varchar(80),
	"locked" boolean DEFAULT false NOT NULL,
	"connection_generation" integer DEFAULT 0 NOT NULL,
	"connection_started_at" timestamp (3),
	"created_at" timestamp (3) DEFAULT now() NOT NULL,
	"updated_at" timestamp (3) DEFAULT now() NOT NULL,
	CONSTRAINT "grid_rooms_connection_generation_check" CHECK ("grid_rooms"."connection_generation" >= 0),
	CONSTRAINT "grid_rooms_title_not_empty_check" CHECK ("grid_rooms"."title" is null or length("grid_rooms"."title") > 0)
);
--> statement-breakpoint
ALTER TABLE "grid_presence" ADD CONSTRAINT "grid_presence_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "grid_presence" ADD CONSTRAINT "grid_presence_room_id_grid_rooms_id_fk" FOREIGN KEY ("room_id") REFERENCES "public"."grid_rooms"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "grid_presence" ADD CONSTRAINT "grid_presence_owner_session_id_sessions_id_fk" FOREIGN KEY ("owner_session_id") REFERENCES "public"."sessions"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "grid_rooms" ADD CONSTRAINT "grid_rooms_space_id_spaces_id_fk" FOREIGN KEY ("space_id") REFERENCES "public"."spaces"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "grid_rooms" ADD CONSTRAINT "grid_rooms_created_by_user_id_users_id_fk" FOREIGN KEY ("created_by_user_id") REFERENCES "public"."users"("id") ON DELETE restrict ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "grid_presence_room_id_idx" ON "grid_presence" USING btree ("room_id");--> statement-breakpoint
CREATE INDEX "grid_presence_owner_session_id_idx" ON "grid_presence" USING btree ("owner_session_id");--> statement-breakpoint
CREATE INDEX "grid_presence_lease_expires_at_idx" ON "grid_presence" USING btree ("lease_expires_at");--> statement-breakpoint
CREATE INDEX "grid_rooms_space_id_idx" ON "grid_rooms" USING btree ("space_id");--> statement-breakpoint
CREATE INDEX "grid_rooms_created_by_user_id_idx" ON "grid_rooms" USING btree ("created_by_user_id");--> statement-breakpoint
CREATE UNIQUE INDEX "grid_rooms_space_title_unique" ON "grid_rooms" USING btree ("space_id",lower("title")) WHERE "grid_rooms"."title" is not null;