CREATE TABLE "space_settings" (
	"space_id" integer PRIMARY KEY NOT NULL,
	"payload" "bytea" NOT NULL,
	"updated_at" timestamp (3) DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "space_settings" ADD CONSTRAINT "space_settings_space_id_spaces_id_fk" FOREIGN KEY ("space_id") REFERENCES "public"."spaces"("id") ON DELETE cascade ON UPDATE no action;