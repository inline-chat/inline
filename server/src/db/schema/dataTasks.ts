import { sql } from "drizzle-orm"
import { bigserial, index, integer, jsonb, pgTable, text, timestamp, uniqueIndex } from "drizzle-orm/pg-core"

/**
 * Ledger of data tasks (`server/src/modules/dataTasks`): one row per item a
 * task changed, written in the same transaction as the change. It makes a
 * task idempotent (an item with a row is never applied again, even after a
 * revert) and gives `revert` the state to restore. Append-only apart from
 * `reverted_at`. Never read by the API.
 */
export const dataTaskItems = pgTable(
  "data_task_items",
  {
    id: bigserial("id", { mode: "bigint" }).primaryKey(),
    taskId: text("task_id").notNull(),
    // Stable within a task, e.g. "bot:42".
    itemKey: text("item_key").notNull(),
    tier: text("tier").notNull(),
    // The reviewed plan the item was applied from.
    planHash: text("plan_hash").notNull(),
    // IDs and flags only, never content.
    plan: jsonb("plan").notNull(),
    before: jsonb("before").notNull(),
    after: jsonb("after").notNull(),
    appliedAt: timestamp("applied_at", { mode: "date", precision: 3 }).defaultNow().notNull(),
    revertedAt: timestamp("reverted_at", { mode: "date", precision: 3 }),
  },
  (table) => [
    uniqueIndex("data_task_items_task_item_unique").on(table.taskId, table.itemKey),
    index("data_task_items_task_applied_idx").on(table.taskId, table.appliedAt),
  ],
)

export type DbDataTaskItem = typeof dataTaskItems.$inferSelect

export const dataTaskRunStatuses = ["running", "completed", "blocked", "failed", "paused"] as const
export type DataTaskRunStatus = (typeof dataTaskRunStatuses)[number]

/**
 * One row per attempt to run a data task. The worker process runs pending
 * tasks on its own; a `running` row is its lease (renewed by `heartbeat_at`,
 * taken over once stale), and a `completed` row ends the task for good, like
 * a migration in the ledger. `blocked` (a limit tripped, nothing applied),
 * `failed` and `paused` (time budget or shutdown) are retried on a later tick.
 */
export const dataTaskRuns = pgTable(
  "data_task_runs",
  {
    id: bigserial("id", { mode: "bigint" }).primaryKey(),
    taskId: text("task_id").notNull(),
    status: text("status", { enum: dataTaskRunStatuses }).notNull(),
    planHash: text("plan_hash"),
    items: integer("items").default(0).notNull(),
    applied: integer("applied").default(0).notNull(),
    skipped: integer("skipped").default(0).notNull(),
    // Our own bounded message: a limit, a skip reason or an error name. Never a database error.
    reason: text("reason"),
    sourceCommit: text("source_commit"),
    startedAt: timestamp("started_at", { mode: "date", precision: 3 }).defaultNow().notNull(),
    heartbeatAt: timestamp("heartbeat_at", { mode: "date", precision: 3 }).defaultNow().notNull(),
    finishedAt: timestamp("finished_at", { mode: "date", precision: 3 }),
  },
  (table) => [
    uniqueIndex("data_task_runs_one_running").on(table.taskId).where(sql`${table.status} = 'running'`),
    uniqueIndex("data_task_runs_one_completed").on(table.taskId).where(sql`${table.status} = 'completed'`),
    index("data_task_runs_task_started_idx").on(table.taskId, table.startedAt),
  ],
)

export type DbDataTaskRun = typeof dataTaskRuns.$inferSelect
