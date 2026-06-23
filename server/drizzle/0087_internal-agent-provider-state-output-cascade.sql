ALTER TABLE "internal_agent_provider_states" DROP CONSTRAINT "internal_agent_provider_states_output_msg_fk";
--> statement-breakpoint
ALTER TABLE "internal_agent_provider_states" ADD CONSTRAINT "internal_agent_provider_states_output_msg_fk" FOREIGN KEY ("output_msg_global_id") REFERENCES "public"."messages"("global_id") ON DELETE cascade ON UPDATE no action;