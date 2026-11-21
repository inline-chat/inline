CREATE SEQUENCE "public"."message_search_work_version" INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 START WITH 1 CACHE 1;--> statement-breakpoint
CREATE TABLE "chat_search_keys" (
	"chat_id" integer PRIMARY KEY NOT NULL,
	"key_envelope" "bytea" NOT NULL
);
--> statement-breakpoint
CREATE TABLE "message_search_backfill" (
	"profile" text PRIMARY KEY NOT NULL,
	"after_global_id" bigint DEFAULT 0 NOT NULL,
	"complete" boolean DEFAULT false NOT NULL
);
--> statement-breakpoint
CREATE TABLE "message_search_documents" (
	"message_global_id" bigint PRIMARY KEY NOT NULL,
	"chat_id" integer NOT NULL,
	"message_rev" integer NOT NULL,
	"work_version" bigint DEFAULT nextval('message_search_work_version') NOT NULL,
	"tokenizer_version" text,
	"historical" boolean DEFAULT false NOT NULL,
	"failed_attempts" integer DEFAULT 0 NOT NULL,
	"claim_until" timestamp with time zone,
	"ready" boolean DEFAULT false NOT NULL,
	"overflow" boolean DEFAULT false NOT NULL,
	"tags" uuid[] DEFAULT '{}'::uuid[] NOT NULL,
	CONSTRAINT "message_search_ready_metadata" CHECK (not "message_search_documents"."ready" or
      ("message_search_documents"."tokenizer_version" is not null and "message_search_documents"."claim_until" is null)),
	CONSTRAINT "message_search_overflow_tags" CHECK (not "message_search_documents"."overflow" or cardinality("message_search_documents"."tags") = 0)
);
--> statement-breakpoint
ALTER TABLE "chat_search_keys" ADD CONSTRAINT "chat_search_keys_chat_id_chats_id_fk" FOREIGN KEY ("chat_id") REFERENCES "public"."chats"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "message_search_documents" ADD CONSTRAINT "message_search_documents_message_global_id_messages_global_id_fk" FOREIGN KEY ("message_global_id") REFERENCES "public"."messages"("global_id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "message_search_pending_idx" ON "message_search_documents" USING btree ("historical","message_global_id") WHERE not "message_search_documents"."ready" and "message_search_documents"."failed_attempts" < 5;--> statement-breakpoint
CREATE INDEX "message_search_pending_chat_idx" ON "message_search_documents" USING btree ("chat_id","message_global_id") WHERE not "message_search_documents"."ready";--> statement-breakpoint
CREATE INDEX "message_search_profile_idx" ON "message_search_documents" USING btree ("tokenizer_version","chat_id") WHERE "message_search_documents"."ready";--> statement-breakpoint
CREATE INDEX "message_search_overflow_idx" ON "message_search_documents" USING btree ("message_global_id") WHERE "message_search_documents"."ready" and "message_search_documents"."overflow";--> statement-breakpoint
CREATE INDEX "message_search_tags_idx" ON "message_search_documents" USING gin ("tags");--> statement-breakpoint
-- Existing history must be indexed outside the migration transaction.
DO $$
DECLARE
  item record;
BEGIN
  FOR item IN SELECT * FROM (VALUES
    ('messages_chat_search_date_idx', 'CREATE INDEX messages_chat_search_date_idx ON public.messages USING btree (chat_id, date DESC NULLS LAST, global_id DESC NULLS LAST)'),
    ('messages_document_id_idx', 'CREATE INDEX messages_document_id_idx ON public.messages USING btree (document_id) WHERE (document_id IS NOT NULL)')
  ) AS indexes(name, definition) LOOP
    IF to_regclass('public.' || item.name) IS NULL THEN
      IF EXISTS (SELECT 1 FROM messages LIMIT 1) THEN
        RAISE EXCEPTION 'Prebuild missing index % with server/scripts/prebuild-global-search.sql before migration 0176', item.name;
      END IF;
    ELSIF NOT EXISTS (SELECT 1 FROM pg_index WHERE indexrelid = to_regclass('public.' || item.name)
        AND indisvalid AND indisready AND pg_get_indexdef(indexrelid) = item.definition) THEN
      RAISE EXCEPTION 'Inspect invalid or incompatible index % before migration 0176', item.name;
    END IF;
  END LOOP;
END $$;
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "messages_chat_search_date_idx" ON "messages" USING btree ("chat_id","date" DESC NULLS LAST,"global_id" DESC NULLS LAST);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "messages_document_id_idx" ON "messages" USING btree ("document_id") WHERE "messages"."document_id" is not null;
--> statement-breakpoint
CREATE FUNCTION inline_search_message_changed() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' OR ROW(NEW.chat_id, NEW.text, NEW.text_encrypted, NEW.text_iv, NEW.text_tag, NEW.document_id, NEW.system_message_encrypted, NEW.system_message_iv, NEW.system_message_tag)
    IS DISTINCT FROM ROW(OLD.chat_id, OLD.text, OLD.text_encrypted, OLD.text_iv, OLD.text_tag, OLD.document_id, OLD.system_message_encrypted, OLD.system_message_iv, OLD.system_message_tag) THEN
    -- A new reference cannot commit while a dependency update is fencing only
    -- its already-visible references. FK KEY SHARE alone does not serialize it.
    IF NEW.document_id IS NOT NULL THEN
      PERFORM id FROM documents WHERE id = NEW.document_id FOR SHARE;
    END IF;
    INSERT INTO message_search_documents (message_global_id, message_rev, chat_id)
      VALUES (NEW.global_id, NEW.rev, NEW.chat_id)
    ON CONFLICT (message_global_id) DO UPDATE SET
      message_rev = NEW.rev, chat_id = NEW.chat_id, ready = false, claim_until = NULL, overflow = false, tags = '{}',
      tokenizer_version = NULL, historical = false, failed_attempts = 0,
      work_version = nextval('message_search_work_version');
  ELSIF NEW.rev IS DISTINCT FROM OLD.rev THEN
    -- Presentation-only enrichment preserves tags while fencing in-flight work.
    UPDATE message_search_documents SET message_rev = NEW.rev, claim_until = NULL,
      work_version = nextval('message_search_work_version') WHERE message_global_id = NEW.global_id;
  END IF;
  RETURN NEW;
END $$;
--> statement-breakpoint
CREATE TRIGGER inline_search_message_changed AFTER INSERT OR UPDATE OF chat_id, rev, text, text_encrypted, text_iv, text_tag, document_id, system_message_encrypted, system_message_iv, system_message_tag ON messages
  FOR EACH ROW EXECUTE FUNCTION inline_search_message_changed();
--> statement-breakpoint
CREATE FUNCTION inline_search_filename_changed() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF ROW(NEW.file_name, NEW.file_name_iv, NEW.file_name_tag)
    IS DISTINCT FROM ROW(OLD.file_name, OLD.file_name_iv, OLD.file_name_tag) THEN
    INSERT INTO message_search_documents (message_global_id, message_rev, chat_id)
      SELECT global_id, rev, chat_id FROM messages WHERE document_id = NEW.id
    ON CONFLICT (message_global_id) DO UPDATE SET
      ready = false, claim_until = NULL, overflow = false, tags = '{}', tokenizer_version = NULL,
      historical = false, failed_attempts = 0, work_version = nextval('message_search_work_version');
  END IF;
  RETURN NEW;
END $$;
--> statement-breakpoint
CREATE TRIGGER inline_search_filename_changed AFTER UPDATE OF file_name, file_name_iv, file_name_tag ON documents
  FOR EACH ROW EXECUTE FUNCTION inline_search_filename_changed();
--> statement-breakpoint
-- Keys are immutable for the lifetime of their chat. FK cascade already removed
-- the parent when it deletes the key. No send acquires a lock on the key.
CREATE FUNCTION inline_search_guard_key() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM chats WHERE id = OLD.chat_id) THEN RETURN OLD; END IF;
  RAISE EXCEPTION 'Chat search keys are immutable';
END $$;
--> statement-breakpoint
CREATE TRIGGER inline_search_guard_key BEFORE UPDATE OR DELETE ON chat_search_keys
  FOR EACH ROW EXECUTE FUNCTION inline_search_guard_key();
--> statement-breakpoint
ALTER TABLE messages DISABLE TRIGGER inline_search_message_changed;
--> statement-breakpoint
ALTER TABLE documents DISABLE TRIGGER inline_search_filename_changed;
--> statement-breakpoint
CREATE FUNCTION inline_search_capture_enabled() RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT count(*) = 2 FROM pg_trigger WHERE tgenabled IN ('O', 'A')
    AND ((tgrelid = 'messages'::regclass AND tgname = 'inline_search_message_changed')
      OR (tgrelid = 'documents'::regclass AND tgname = 'inline_search_filename_changed'));
$$;
--> statement-breakpoint
-- Operator switch. Disabling drops derived postings and resets history coverage.
-- Sequence-backed fences prevent an old worker publishing into a rebuilt row.
CREATE FUNCTION inline_search_set_capture(enabled boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  LOCK TABLE messages, documents IN ACCESS EXCLUSIVE MODE;
  IF enabled = inline_search_capture_enabled() THEN RETURN; END IF;
  IF enabled THEN
    ALTER TABLE messages ENABLE TRIGGER inline_search_message_changed;
    ALTER TABLE documents ENABLE TRIGGER inline_search_filename_changed;
  ELSE
    ALTER TABLE messages DISABLE TRIGGER inline_search_message_changed;
    ALTER TABLE documents DISABLE TRIGGER inline_search_filename_changed;
    TRUNCATE message_search_documents, message_search_backfill;
  END IF;
END $$;
