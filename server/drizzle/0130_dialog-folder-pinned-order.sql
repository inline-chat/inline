ALTER TABLE "dialog_folders" ADD COLUMN "pinned_order" text;--> statement-breakpoint
CREATE INDEX "dialog_folders_user_id_pinned_order_idx" ON "dialog_folders" USING btree ("user_id","pinned_order");