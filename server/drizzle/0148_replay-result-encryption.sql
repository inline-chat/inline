ALTER TABLE "inline_protocol_requests" ADD COLUMN "result_format" smallint DEFAULT 0 NOT NULL;
--> statement-breakpoint
ALTER TABLE "inline_protocol_requests" DROP CONSTRAINT "inline_protocol_requests_result_length";
--> statement-breakpoint
ALTER TABLE "inline_protocol_requests" ADD CONSTRAINT "inline_protocol_requests_result_length" CHECK ("result_body" IS NULL OR octet_length("result_body") <= 16777278);
--> statement-breakpoint
ALTER TABLE "inline_protocol_requests" ADD CONSTRAINT "inline_protocol_requests_result_format" CHECK (
  ("result_format" = 0 AND ("result_body" IS NULL OR octet_length("result_body") <= 16777216)) OR
  ("result_format" = 1 AND "result_body" IS NOT NULL AND octet_length("result_body") >= 31)
);
