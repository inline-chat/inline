ALTER TABLE "spaces" ADD COLUMN "grid_revision" integer DEFAULT 0 NOT NULL;--> statement-breakpoint

CREATE FUNCTION "bump_grid_revision_from_room"() RETURNS trigger AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE "spaces" SET "grid_revision" = "grid_revision" + 1 WHERE "id" = NEW."space_id";
  ELSIF TG_OP = 'DELETE' THEN
    UPDATE "spaces" SET "grid_revision" = "grid_revision" + 1 WHERE "id" = OLD."space_id";
  ELSE
    UPDATE "spaces"
      SET "grid_revision" = "grid_revision" + 1
      WHERE "id" = NEW."space_id" OR "id" = OLD."space_id";
  END IF;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;--> statement-breakpoint

CREATE TRIGGER "grid_rooms_bump_snapshot_revision"
AFTER INSERT OR UPDATE OR DELETE ON "grid_rooms"
FOR EACH ROW EXECUTE FUNCTION "bump_grid_revision_from_room"();--> statement-breakpoint

CREATE FUNCTION "bump_grid_revision_from_presence"() RETURNS trigger AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE "spaces"
      SET "grid_revision" = "grid_revision" + 1
      WHERE "id" IN (SELECT "space_id" FROM "grid_rooms" WHERE "id" = NEW."room_id");
  ELSIF TG_OP = 'DELETE' THEN
    UPDATE "spaces"
      SET "grid_revision" = "grid_revision" + 1
      WHERE "id" IN (SELECT "space_id" FROM "grid_rooms" WHERE "id" = OLD."room_id");
  ELSE
    UPDATE "spaces"
      SET "grid_revision" = "grid_revision" + 1
      WHERE "id" IN (
        SELECT "space_id" FROM "grid_rooms"
        WHERE "id" = NEW."room_id" OR "id" = OLD."room_id"
      );
  END IF;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;--> statement-breakpoint

CREATE TRIGGER "grid_presence_bump_snapshot_revision"
AFTER INSERT OR DELETE OR UPDATE OF
  "room_id", "owner_session_id", "joined_at", "microphone_enabled", "media_membership_id", "microphone_revision"
ON "grid_presence"
FOR EACH ROW EXECUTE FUNCTION "bump_grid_revision_from_presence"();--> statement-breakpoint

CREATE FUNCTION "bump_grid_revision_from_settings"() RETURNS trigger AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    UPDATE "spaces" SET "grid_revision" = "grid_revision" + 1 WHERE "id" = OLD."space_id";
  ELSE
    UPDATE "spaces" SET "grid_revision" = "grid_revision" + 1 WHERE "id" = NEW."space_id";
  END IF;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;--> statement-breakpoint

CREATE TRIGGER "space_settings_bump_grid_snapshot_revision"
AFTER INSERT OR UPDATE OR DELETE ON "space_settings"
FOR EACH ROW EXECUTE FUNCTION "bump_grid_revision_from_settings"();
