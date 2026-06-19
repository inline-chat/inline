CREATE TABLE "space_url_preview_exclusions" (
	"id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY (sequence name "space_url_preview_exclusions_id_seq" INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 START WITH 1 CACHE 1),
	"space_id" integer NOT NULL,
	"host" text NOT NULL,
	"path_prefix" text DEFAULT '' NOT NULL,
	"created_by" integer NOT NULL,
	"date" timestamp (3) DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "space_url_preview_exclusions" ADD CONSTRAINT "space_url_preview_exclusions_space_id_spaces_id_fk" FOREIGN KEY ("space_id") REFERENCES "public"."spaces"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "space_url_preview_exclusions" ADD CONSTRAINT "space_url_preview_exclusions_created_by_users_id_fk" FOREIGN KEY ("created_by") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "space_url_preview_exclusions_space_host_path_unique" ON "space_url_preview_exclusions" USING btree ("space_id","host","path_prefix");--> statement-breakpoint
CREATE INDEX "space_url_preview_exclusions_space_host_idx" ON "space_url_preview_exclusions" USING btree ("space_id","host");--> statement-breakpoint
CREATE INDEX "space_url_preview_exclusions_created_by_idx" ON "space_url_preview_exclusions" USING btree ("created_by");