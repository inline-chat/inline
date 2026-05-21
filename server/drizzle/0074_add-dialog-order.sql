ALTER TABLE "dialogs" ADD COLUMN "order" text;--> statement-breakpoint
ALTER TABLE "dialogs" ADD COLUMN "pinned_order" text;--> statement-breakpoint
CREATE INDEX "dialogs_user_id_order_idx" ON "dialogs" USING btree ("user_id","order");--> statement-breakpoint
CREATE INDEX "dialogs_user_id_pinned_order_idx" ON "dialogs" USING btree ("user_id","pinned_order");
