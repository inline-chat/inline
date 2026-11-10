CREATE TABLE "activity_items" (
	"user_id" integer NOT NULL,
	"chat_id" integer NOT NULL,
	"message_id" integer NOT NULL,
	"kind" smallint NOT NULL,
	"actor_user_id" integer,
	"date" timestamp (3) DEFAULT now() NOT NULL,
	"read_at" timestamp (3),
	CONSTRAINT "activity_items_user_id_chat_id_kind_message_id_pk" PRIMARY KEY("user_id","chat_id","kind","message_id")
);
--> statement-breakpoint
ALTER TABLE "activity_items" ADD CONSTRAINT "activity_items_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "activity_items" ADD CONSTRAINT "activity_items_message_fk" FOREIGN KEY ("chat_id","message_id") REFERENCES "public"."messages"("chat_id","message_id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "activity_items_unread_idx" ON "activity_items" USING btree ("user_id","chat_id","kind","message_id") WHERE "activity_items"."read_at" IS NULL;--> statement-breakpoint
CREATE INDEX "activity_items_message_idx" ON "activity_items" USING btree ("chat_id","message_id");--> statement-breakpoint
CREATE INDEX "activity_items_user_date_idx" ON "activity_items" USING btree ("user_id","date" DESC NULLS LAST);