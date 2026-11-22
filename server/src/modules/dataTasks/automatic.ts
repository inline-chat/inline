import { db } from "@in/server/db"
import { dataTaskRuns, type DataTaskRunStatus } from "@in/server/db/schema/dataTasks"
import { Log } from "@in/server/utils/log"
import { and, eq, sql } from "drizzle-orm"
import type { DataTask } from "./dataTask"
import { dataTasks } from "./registry"
import { applyDataTaskItem, DataTaskError, DataTaskLeaseLost, holdLease, planDataTask, planViolation } from "./runner"

const log = new Log("dataTasks")

/** A run whose heartbeat is older than this lost its process; the next one takes over. */
export const LEASE_STALE_SECONDS = 120
/** One run's share of a tick. Whatever is left continues on the next tick. */
const DEFAULT_BUDGET_MS = 10 * 60 * 1000
const HEARTBEAT_EVERY_ITEMS = 10
const DEFAULT_PAUSE_MS = 25

export type DataTaskRunReport = {
  taskId: string
  status: DataTaskRunStatus | "already-completed" | "busy"
  applied: number
  skipped: number
  reason?: string
}

export type RunPendingOptions = {
  tasks?: readonly DataTask[]
  /** Checked between items: a shutdown pauses the run, which resumes on the next start. */
  shouldStop?: () => boolean
  sourceCommit?: string
  budgetMs?: number
  sleep?: (ms: number) => Promise<void>
}

/**
 * Applies every registered task that hasn't completed, in order, like pending
 * migrations: a task that doesn't complete holds back the ones after it. Safe
 * to call from every process at once; a lease row keeps one run per task.
 * Set DATA_TASKS_PAUSED=1 to stop all runs without a deploy.
 */
export async function runPendingDataTasks(options: RunPendingOptions = {}): Promise<DataTaskRunReport[]> {
  if (process.env["DATA_TASKS_PAUSED"] === "1") return []
  const reports: DataTaskRunReport[] = []
  for (const task of options.tasks ?? dataTasks) {
    if (await isCompleted(task.id)) {
      reports.push({ taskId: task.id, status: "already-completed", applied: 0, skipped: 0 })
      continue
    }
    const runId = await claimRun(task.id, options.sourceCommit)
    if (runId === undefined) {
      reports.push({ taskId: task.id, status: "busy", applied: 0, skipped: 0 })
      return reports
    }
    const report = await runTask(task, runId, options)
    reports.push(report)
    if (report.status !== "completed") return reports
  }
  return reports
}

async function isCompleted(taskId: string): Promise<boolean> {
  const [row] = await db
    .select({ id: dataTaskRuns.id })
    .from(dataTaskRuns)
    .where(and(eq(dataTaskRuns.taskId, taskId), eq(dataTaskRuns.status, "completed")))
    .limit(1)
  return row !== undefined
}

/** A new running row, unless a live one exists. A stale one is closed as failed and replaced. */
async function claimRun(taskId: string, sourceCommit: string | undefined): Promise<bigint | undefined> {
  return db.transaction(async (tx) => {
    await tx.execute(sql`select pg_advisory_xact_lock(hashtext('data_task_runs'), hashtext(${taskId}))`)
    const [completed] = await tx
      .select({ id: dataTaskRuns.id })
      .from(dataTaskRuns)
      .where(and(eq(dataTaskRuns.taskId, taskId), eq(dataTaskRuns.status, "completed")))
      .limit(1)
    if (completed) return undefined
    // Locked, so an item committing under the old lease finishes first and its renewal counts.
    const [running] = await tx
      .select({ id: dataTaskRuns.id, live: sql<boolean>`${dataTaskRuns.heartbeatAt} > now() - make_interval(secs => ${LEASE_STALE_SECONDS})` })
      .from(dataTaskRuns)
      .where(and(eq(dataTaskRuns.taskId, taskId), eq(dataTaskRuns.status, "running")))
      .limit(1)
      .for("update")
    if (running?.live) return undefined
    if (running) {
      await tx
        .update(dataTaskRuns)
        .set({ status: "failed", reason: "lease expired", finishedAt: sql`now()` })
        .where(eq(dataTaskRuns.id, running.id))
    }
    const [row] = await tx
      .insert(dataTaskRuns)
      .values({ taskId, status: "running", sourceCommit: sourceCommit ?? null })
      .returning({ id: dataTaskRuns.id })
    return row!.id
  })
}

/** Renews the lease and records progress; false if another process took the run over. */
async function heartbeat(runId: bigint, applied: number, skipped: number): Promise<boolean> {
  const rows = await db
    .update(dataTaskRuns)
    .set({ heartbeatAt: sql`now()`, applied, skipped })
    .where(and(eq(dataTaskRuns.id, runId), eq(dataTaskRuns.status, "running")))
    .returning({ id: dataTaskRuns.id })
  return rows.length > 0
}

/** A run another process took over stops without touching the run row, which is no longer its own. */
function leaseLost(report: DataTaskRunReport): DataTaskRunReport {
  log.warn("data task lost its lease", { taskId: report.taskId, applied: report.applied, skipped: report.skipped })
  return { ...report, status: "failed", reason: "lease lost" }
}

async function finish(runId: bigint, report: DataTaskRunReport): Promise<DataTaskRunReport> {
  const rows = await db
    .update(dataTaskRuns)
    .set({
      status: report.status as DataTaskRunStatus,
      applied: report.applied,
      skipped: report.skipped,
      reason: report.reason?.slice(0, 500) ?? null,
      heartbeatAt: sql`now()`,
      finishedAt: sql`now()`,
    })
    .where(and(eq(dataTaskRuns.id, runId), eq(dataTaskRuns.status, "running")))
    .returning({ id: dataTaskRuns.id })
  if (rows.length === 0) return leaseLost(report)
  const fields = { taskId: report.taskId, applied: report.applied, skipped: report.skipped, reason: report.reason }
  if (report.status === "completed") log.info("data task completed", fields)
  else if (report.status === "paused") log.info("data task paused", fields)
  // Blocked and failed runs need a person: they log as errors, which alert.
  else log.error(`data task ${report.status}`, fields)
  return report
}

async function runTask(task: DataTask, runId: bigint, options: RunPendingOptions): Promise<DataTaskRunReport> {
  const started = Date.now()
  const budgetMs = options.budgetMs ?? DEFAULT_BUDGET_MS
  const sleep = options.sleep ?? ((ms: number) => Bun.sleep(ms))
  const report: DataTaskRunReport = { taskId: task.id, status: "running", applied: 0, skipped: 0 }
  try {
    const plan = await planDataTask(task)
    // A slow plan may have outlived the lease; only a run still holding it records and applies its plan.
    await db.transaction(async (tx) => {
      await holdLease(tx, runId)
      await tx.update(dataTaskRuns).set({ planHash: plan.hash, items: plan.items.length }).where(eq(dataTaskRuns.id, runId))
    })

    // Nothing is applied from a plan past its reviewed limits.
    const violation = planViolation(task, plan)
    if (violation) return finish(runId, { ...report, status: "blocked", reason: violation })

    const maxSkips = task.limits.maxSkips ?? 0
    let touched = 0
    for (const item of plan.items) {
      if (item.noop) continue
      if (options.shouldStop?.()) return finish(runId, { ...report, status: "paused", reason: "process stopping" })
      if (Date.now() - started > budgetMs) return finish(runId, { ...report, status: "paused", reason: "time budget" })

      const outcome = await applyDataTaskItem(task, item, plan.hash, runId)
      if (outcome.kind === "already") continue
      if (outcome.kind === "applied") report.applied++
      else {
        report.skipped++
        if (report.skipped > maxSkips) {
          return finish(runId, { ...report, status: "blocked", reason: `${report.skipped} items skipped, limit ${maxSkips} (last ${item.key}: ${outcome.reason})` })
        }
      }
      if (++touched % HEARTBEAT_EVERY_ITEMS === 0 && !(await heartbeat(runId, report.applied, report.skipped))) {
        return leaseLost(report)
      }
      await sleep(task.pauseMs ?? DEFAULT_PAUSE_MS)
    }
    return finish(runId, { ...report, status: "completed" })
  } catch (error) {
    if (error instanceof DataTaskLeaseLost) return leaseLost(report)
    // Only our own bounded messages are kept; database errors may carry SQL.
    const reason = error instanceof DataTaskError ? error.message : `unexpected ${error instanceof Error ? error.name : "error"}`
    log.error("data task run threw", error, { taskId: task.id })
    return finish(runId, { ...report, status: "failed", reason })
  }
}
