ALTER TABLE "internal_agent_provider_states" DROP CONSTRAINT "internal_agent_provider_states_output_msg_fk";
--> statement-breakpoint
ALTER TABLE "internal_agent_runs" DROP CONSTRAINT "internal_agent_runs_trigger_msg_global_id_messages_global_id_fk";
--> statement-breakpoint
ALTER TABLE "internal_agent_runs" DROP CONSTRAINT "internal_agent_runs_output_msg_global_id_messages_global_id_fk";
--> statement-breakpoint
ALTER TABLE "internal_agent_runs" ALTER COLUMN "trigger_msg_global_id" DROP NOT NULL;--> statement-breakpoint
ALTER TABLE "internal_agent_provider_states" ADD CONSTRAINT "internal_agent_provider_states_output_msg_fk" FOREIGN KEY ("output_msg_global_id") REFERENCES "public"."messages"("global_id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "internal_agent_runs" ADD CONSTRAINT "internal_agent_runs_trigger_msg_global_id_messages_global_id_fk" FOREIGN KEY ("trigger_msg_global_id") REFERENCES "public"."messages"("global_id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "internal_agent_runs" ADD CONSTRAINT "internal_agent_runs_output_msg_global_id_messages_global_id_fk" FOREIGN KEY ("output_msg_global_id") REFERENCES "public"."messages"("global_id") ON DELETE set null ON UPDATE no action;
