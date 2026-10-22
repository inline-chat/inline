CREATE TABLE "file_part_hashes" (
	"file_id" integer PRIMARY KEY NOT NULL,
	"hashes" "bytea" NOT NULL
);
--> statement-breakpoint
ALTER TABLE "file_part_hashes" ADD CONSTRAINT "file_part_hashes_file_id_files_id_fk" FOREIGN KEY ("file_id") REFERENCES "public"."files"("id") ON DELETE cascade ON UPDATE no action;