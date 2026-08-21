CREATE TABLE "dialog_folders" (
	"id" serial PRIMARY KEY NOT NULL,
	"user_id" integer NOT NULL,
	"title" text,
	"order" text NOT NULL,
	"date" timestamp (3) DEFAULT now() NOT NULL,
	CONSTRAINT "dialog_folders_id_user_id_unique" UNIQUE("id","user_id")
);
--> statement-breakpoint
ALTER TABLE "dialogs" ADD COLUMN "folder_id" integer;--> statement-breakpoint
ALTER TABLE "dialog_folders" ADD CONSTRAINT "dialog_folders_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "dialog_folders_user_id_order_idx" ON "dialog_folders" USING btree ("user_id","order");--> statement-breakpoint
ALTER TABLE "dialogs" ADD CONSTRAINT "dialogs_folder_id_user_id_dialog_folders_id_user_id_fk" FOREIGN KEY ("folder_id","user_id") REFERENCES "public"."dialog_folders"("id","user_id") ON DELETE restrict ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "dialogs_user_id_folder_id_order_idx" ON "dialogs" USING btree ("user_id","folder_id","order");