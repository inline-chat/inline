CREATE TABLE "mcp_reaction_events" (
	"chat_id" integer NOT NULL,
	"seq" integer NOT NULL,
	"occurred_at" timestamp (3) NOT NULL,
	"payload_encrypted" "bytea" NOT NULL,
	CONSTRAINT "mcp_reaction_events_chat_id_seq_pk" PRIMARY KEY("chat_id","seq")
);
--> statement-breakpoint
ALTER TABLE "chats" ADD COLUMN "mcp_reaction_seq" integer DEFAULT 0 NOT NULL;--> statement-breakpoint
ALTER TABLE "mcp_reaction_events" ADD CONSTRAINT "mcp_reaction_events_chat_id_chats_id_fk" FOREIGN KEY ("chat_id") REFERENCES "public"."chats"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "mcp_reactions_retention_idx" ON "mcp_reaction_events" USING btree ("occurred_at","chat_id","seq");