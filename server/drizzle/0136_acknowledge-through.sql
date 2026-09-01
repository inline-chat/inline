CREATE TABLE "chat_acknowledgements" (
  "chat_id" integer NOT NULL,
  "user_id" integer NOT NULL,
  "max_id" integer NOT NULL,
  CONSTRAINT "chat_acknowledgements_chat_id_user_id_pk" PRIMARY KEY("chat_id", "user_id")
);
--> statement-breakpoint
ALTER TABLE "chat_acknowledgements" ADD CONSTRAINT "chat_acknowledgements_chat_id_chats_id_fk" FOREIGN KEY ("chat_id") REFERENCES "public"."chats"("id") ON DELETE cascade ON UPDATE no action;
--> statement-breakpoint
ALTER TABLE "chat_acknowledgements" ADD CONSTRAINT "chat_acknowledgements_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;
