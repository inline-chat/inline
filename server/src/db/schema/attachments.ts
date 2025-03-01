import { bytea, creationDate } from "@in/server/db/schema/common"
import { files } from "@in/server/db/schema/files"
import { messages } from "@in/server/db/schema/messages"
import { users } from "@in/server/db/schema/users"
import { pgTable, serial, integer, text, bigint } from "drizzle-orm/pg-core"

export const messageAttachments = pgTable("message_attachments", {
  id: bigint("id", { mode: "number" }).generatedAlwaysAsIdentity().primaryKey(),
  messageId: bigint("message_id", { mode: "bigint" }).references(() => messages.globalId),

  /** external task id */
  externalTaskId: bigint("external_task_id", { mode: "bigint" }).references(() => externalTasks.id),
})

export const externalTasks = pgTable("external_tasks", {
  id: bigint("id", { mode: "number" }).generatedAlwaysAsIdentity().primaryKey(),
  application: text("application").notNull(),
  taskId: text("task_id").notNull(),
  status: text("status", { enum: ["backlog", "todo", "in_progress", "done", "cancelled"] }).notNull(),
  assignedUserId: bigint("assigned_user_id", { mode: "bigint" }).references(() => users.id),
  number: text("number"),
  url: text("url"),

  /** title of the task (encrypted) */
  title: bytea("title"),
  titleIv: bytea("title_iv"),
  titleTag: bytea("title_tag"),

  date: creationDate,
})
