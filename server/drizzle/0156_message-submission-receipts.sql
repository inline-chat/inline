CREATE TABLE "message_submissions" (
	"from_id" integer NOT NULL,
	"random_id" bigint NOT NULL,
	"intent_hash" "bytea" NOT NULL,
	"chat_id" integer NOT NULL,
	"message_id" integer NOT NULL,
	"source_revision" integer,
	CONSTRAINT "message_submissions_identity" PRIMARY KEY("from_id","random_id")
);
--> statement-breakpoint
ALTER TABLE "message_submissions" ADD CONSTRAINT "message_submissions_from_id_users_id_fk" FOREIGN KEY ("from_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;