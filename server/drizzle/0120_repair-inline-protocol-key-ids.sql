ALTER TABLE "inline_protocol_auth_keys"
  ADD COLUMN IF NOT EXISTS "key_encryption_key_id" varchar(32);--> statement-breakpoint

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM "inline_protocol_auth_keys" WHERE "key_encryption_key_id" IS NULL
  ) THEN
    RAISE EXCEPTION 'cannot repair key_encryption_key_id while authorization keys lack a wrapping-key ID';
  END IF;
END
$$;--> statement-breakpoint

ALTER TABLE "inline_protocol_auth_keys"
  ALTER COLUMN "key_encryption_key_id" SET NOT NULL;--> statement-breakpoint

ALTER TABLE "inline_protocol_auth_challenges"
  ADD COLUMN IF NOT EXISTS "pepper_key_id" varchar(32);--> statement-breakpoint

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM "inline_protocol_auth_challenges" WHERE "pepper_key_id" IS NULL
  ) THEN
    RAISE EXCEPTION 'cannot repair pepper_key_id while authentication challenges lack a pepper-key ID';
  END IF;
END
$$;--> statement-breakpoint

ALTER TABLE "inline_protocol_auth_challenges"
  ALTER COLUMN "pepper_key_id" SET NOT NULL;--> statement-breakpoint

ALTER TABLE "inline_protocol_requests"
  DROP CONSTRAINT IF EXISTS "inline_protocol_requests_auth_key_id_inline_protocol_auth_keys_auth_key_id_fk";
