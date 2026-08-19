CREATE OR REPLACE FUNCTION "maintain_message_id_counter"()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW."message_id_counter" = GREATEST(
    OLD."message_id_counter",
    NEW."message_id_counter",
    COALESCE(NEW."last_msg_id", 0)
  );
  RETURN NEW;
END;
$$;

CREATE TRIGGER "chats_maintain_message_id_counter"
BEFORE UPDATE OF "last_msg_id", "message_id_counter" ON "chats"
FOR EACH ROW
EXECUTE FUNCTION "maintain_message_id_counter"();
