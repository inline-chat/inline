import type { db } from "@in/server/db"
import type { Transaction } from "@in/server/db/types"

/**
 * A data task changes production data that a schema migration shouldn't: a
 * cohort picked by a policy decision, work that must go through domain code
 * (grants, settings, updates), or anything that needs review before it runs and
 * a way back after. See `server/docs/data-tasks.md`.
 *
 * Tasks run on their own, like migrations: the worker process applies every
 * registered task that hasn't completed (`automatic.ts`). What makes that safe
 * is reviewed in the task's PR, the way a migration's SQL is:
 *
 * - `select` names the items and what each will do, as a hashed plan.
 * - `limits` and `check` bound that plan. A plan past them is blocked whole
 *   before anything is applied: they catch a cohort query gone wrong.
 * - `apply` locks and re-checks one item inside its own transaction, which
 *   commits with its ledger row; `verify` then checks the result in that same
 *   transaction and aborts the item and the run if it is wrong.
 * - `revert` undoes one ledger row, for an emergency.
 */
export type Json = null | boolean | number | string | Json[] | { [key: string]: Json }

export type DataTaskItem = {
  /** Stable and unique within the task, e.g. "bot:42". */
  key: string
  /** The group the item falls in, for the plan's summary. */
  tier: string
  /** Shown in the plan and counted in its hash, never applied. */
  noop?: boolean
  /** What `apply` will do: IDs and flags only, never content. */
  plan: Json
}

export type DataTaskChange = {
  before: Json
  after: Json
  /** Live pushes to send once the transaction committed. */
  publish?: () => void
}

export type DataTaskLedgerEntry = {
  key: string
  tier: string
  plan: Json
  before: Json
  after: Json
}

export type DataTaskQuery = Pick<typeof db, "execute">

export type DataTaskPlanSummary = {
  hash: string
  items: readonly DataTaskItem[]
  tiers: Readonly<Record<string, number>>
}

export type DataTaskLimits = {
  /** Most items the plan may hold, noops included. */
  maxItems: number
  /** Most items per tier. A tier not listed here blocks the plan. */
  maxPerTier: Readonly<Record<string, number>>
  /** Items that may skip (changed since the plan) before the run stops. Defaults to 0. */
  maxSkips?: number
}

export type DataTask = {
  /** Dated and kebab-case, e.g. "2026-11-21-close-grandfathered-bots". Never reused. */
  id: string
  description: string
  /**
   * Read-only. Runs at plan time and again at apply time, and the two must
   * hash the same, so keep it deterministic: fixed cutoffs, not `now()`.
   */
  select(query: DataTaskQuery): Promise<DataTaskItem[]>
  /** Required: a run whose plan exceeds them is blocked before anything changes. */
  limits: DataTaskLimits
  /** Further invariants on the whole plan; return a reason to block it. */
  check?(plan: DataTaskPlanSummary): string | undefined
  /** Locks and re-checks the item, then changes it. Throw `DataTaskSkip` if it no longer qualifies. */
  apply(tx: Transaction, item: DataTaskItem): Promise<DataTaskChange>
  /**
   * Checks the applied item inside its transaction; return a reason if it is
   * wrong. The item rolls back and the run stops as failed.
   */
  verify?(tx: Transaction, item: DataTaskItem, change: DataTaskChange): Promise<string | undefined>
  /** Pause between items, to keep a long task gentle on the database. Defaults to 25ms. */
  pauseMs?: number
  /** Restores `before`. Throw `DataTaskSkip` if the item changed since, so a later choice wins. */
  revert?(tx: Transaction, entry: DataTaskLedgerEntry): Promise<{ publish?: () => void }>
}

/** The item no longer qualifies; nothing about it changes and the run goes on. */
export class DataTaskSkip extends Error {
  constructor(readonly reason: string) {
    super(reason)
    this.name = "DataTaskSkip"
  }
}

export const defineDataTask = (task: DataTask): DataTask => task
