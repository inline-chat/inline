import { createHash } from "node:crypto"
import { db } from "@in/server/db"
import { dataTaskItems, dataTaskRuns } from "@in/server/db/schema/dataTasks"
import type { Transaction } from "@in/server/db/types"
import { and, asc, desc, eq, inArray, isNull, sql } from "drizzle-orm"
import { DataTaskSkip, type DataTask, type DataTaskChange, type DataTaskItem, type DataTaskQuery, type Json } from "./dataTask"

export type DataTaskPlan = {
  taskId: string
  hash: string
  items: DataTaskItem[]
  tiers: Record<string, number>
}

export class DataTaskError extends Error {
  constructor(message: string) {
    super(message)
    this.name = "DataTaskError"
  }
}

/** `verify` rejected an applied item. It rolled back; the run must stop. */
export class DataTaskVerifyFailed extends DataTaskError {
  constructor(readonly key: string, readonly reason: string) {
    super(`Verification failed for ${key}: ${reason}`)
    this.name = "DataTaskVerifyFailed"
  }
}

/** JSON with sorted keys, so equal plans hash equal whatever order keys were built in. */
export function canonicalJson(value: Json): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value)
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`
  const keys = Object.keys(value).sort()
  return `{${keys.map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key]!)}`).join(",")}}`
}

/** Sorts, validates and hashes a task's items. Pure, so a plan can be built from rows read elsewhere. */
export function buildPlan(taskId: string, selected: readonly DataTaskItem[]): DataTaskPlan {
  const items = [...selected].sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0))
  const tiers: Record<string, number> = {}
  for (let index = 0; index < items.length; index++) {
    const item = items[index]!
    if (!item.key || item.key === items[index - 1]?.key) throw new DataTaskError(`Duplicate or empty item key "${item.key}"`)
    tiers[item.tier] = (tiers[item.tier] ?? 0) + 1
  }
  const body: Json = {
    taskId,
    items: items.map((item) => ({ key: item.key, tier: item.tier, noop: item.noop === true, plan: item.plan })),
  }
  const hash = createHash("sha256").update(canonicalJson(body)).digest("hex")
  return { taskId, hash, items, tiers }
}

/**
 * The task's current selection plus every item its ledger already holds, as
 * it was applied. Applied items usually leave the selection (that is the
 * point), so without them a run stopped halfway would see a different plan,
 * and its limits would count only what is left.
 */
export async function planDataTask(task: DataTask, query: DataTaskQuery = db): Promise<DataTaskPlan> {
  const selected = await task.select(query)
  const ledger = await db
    .select({ key: dataTaskItems.itemKey, tier: dataTaskItems.tier, plan: dataTaskItems.plan })
    .from(dataTaskItems)
    .where(eq(dataTaskItems.taskId, task.id))
  const items = new Map(selected.map((item) => [item.key, item]))
  for (const row of ledger) items.set(row.key, { key: row.key, tier: row.tier, plan: row.plan as Json })
  return buildPlan(task.id, [...items.values()])
}

/** Why the plan may not run, or undefined. Checked before anything is applied. */
export function planViolation(task: DataTask, plan: DataTaskPlan): string | undefined {
  const { maxItems, maxPerTier } = task.limits
  if (plan.items.length > maxItems) return `${plan.items.length} items exceed the limit of ${maxItems}`
  for (const [tier, count] of Object.entries(plan.tiers)) {
    const max = maxPerTier[tier]
    if (max === undefined) return `unexpected tier "${tier}"`
    if (count > max) return `${count} "${tier}" items exceed the limit of ${max}`
  }
  return task.check?.(plan)
}

/** One task item at a time, across processes. */
async function lockItem(tx: Transaction, taskId: string, key: string): Promise<void> {
  await tx.execute(sql`select pg_advisory_xact_lock(hashtext('data_task_items'), hashtext(${`${taskId}:${key}`}))`)
}

export type ItemOutcome = { kind: "applied" } | { kind: "already" } | { kind: "skipped"; reason: string }

/**
 * Applies one item in its own transaction, with its ledger row and `verify`.
 * An item with a ledger row is never applied again, even after a revert.
 */
export async function applyDataTaskItem(task: DataTask, item: DataTaskItem, planHash: string): Promise<ItemOutcome> {
  let change: DataTaskChange | undefined
  try {
    change = await db.transaction(async (tx) => {
      await lockItem(tx, task.id, item.key)
      const [existing] = await tx
        .select({ id: dataTaskItems.id })
        .from(dataTaskItems)
        .where(and(eq(dataTaskItems.taskId, task.id), eq(dataTaskItems.itemKey, item.key)))
        .limit(1)
      if (existing) return undefined
      const applied = await task.apply(tx, item)
      const wrong = await task.verify?.(tx, item, applied)
      if (wrong) throw new DataTaskVerifyFailed(item.key, wrong)
      await tx.insert(dataTaskItems).values({
        taskId: task.id,
        itemKey: item.key,
        tier: item.tier,
        planHash,
        plan: item.plan,
        before: applied.before,
        after: applied.after,
      })
      return applied
    })
  } catch (error) {
    if (error instanceof DataTaskSkip) return { kind: "skipped", reason: error.reason }
    throw error
  }
  if (!change) return { kind: "already" }
  change.publish?.()
  return { kind: "applied" }
}

export type DataTaskRevertSummary = {
  reverted: number
  skipped: Array<{ key: string; reason: string }>
}

/** Reverts applied, not yet reverted ledger rows: all of them, or the given keys. */
export async function revertDataTask(task: DataTask, options: { keys?: readonly string[] } = {}): Promise<DataTaskRevertSummary> {
  const revert = task.revert
  if (!revert) throw new DataTaskError(`Task ${task.id} has no revert`)
  const rows = await db
    .select({ itemKey: dataTaskItems.itemKey })
    .from(dataTaskItems)
    .where(and(
      eq(dataTaskItems.taskId, task.id),
      isNull(dataTaskItems.revertedAt),
      options.keys ? inArray(dataTaskItems.itemKey, [...options.keys]) : undefined,
    ))
    .orderBy(asc(dataTaskItems.id))

  const summary: DataTaskRevertSummary = { reverted: 0, skipped: [] }
  for (const { itemKey } of rows) {
    try {
      const outcome = await db.transaction(async (tx) => {
        await lockItem(tx, task.id, itemKey)
        const [row] = await tx
          .select()
          .from(dataTaskItems)
          .where(and(eq(dataTaskItems.taskId, task.id), eq(dataTaskItems.itemKey, itemKey), isNull(dataTaskItems.revertedAt)))
          .limit(1)
        if (!row) return undefined
        const result = await revert(tx, {
          key: row.itemKey,
          tier: row.tier,
          plan: row.plan as Json,
          before: row.before as Json,
          after: row.after as Json,
        })
        await tx.update(dataTaskItems).set({ revertedAt: new Date() }).where(eq(dataTaskItems.id, row.id))
        return result
      })
      if (!outcome) continue
      outcome.publish?.()
      summary.reverted++
    } catch (error) {
      if (!(error instanceof DataTaskSkip)) throw error
      summary.skipped.push({ key: itemKey, reason: error.reason })
    }
  }
  return summary
}

export type DataTaskStatus = {
  applied: number
  reverted: number
  tiers: Record<string, { applied: number; reverted: number }>
  lastRun: { status: string; reason: string | null; applied: number; skipped: number; startedAt: string } | null
  completed: boolean
}

export async function dataTaskStatus(taskId: string): Promise<DataTaskStatus> {
  const rows = await db
    .select({ tier: dataTaskItems.tier, revertedAt: dataTaskItems.revertedAt })
    .from(dataTaskItems)
    .where(eq(dataTaskItems.taskId, taskId))
  const runs = await db.select().from(dataTaskRuns).where(eq(dataTaskRuns.taskId, taskId)).orderBy(desc(dataTaskRuns.id)).limit(20)
  const status: DataTaskStatus = { applied: 0, reverted: 0, tiers: {}, lastRun: null, completed: runs.some((run) => run.status === "completed") }
  for (const row of rows) {
    const tier = (status.tiers[row.tier] ??= { applied: 0, reverted: 0 })
    if (row.revertedAt) { status.reverted++; tier.reverted++ } else { status.applied++; tier.applied++ }
  }
  const last = runs[0]
  if (last) {
    status.lastRun = { status: last.status, reason: last.reason, applied: last.applied, skipped: last.skipped, startedAt: last.startedAt.toISOString() }
  }
  return status
}
