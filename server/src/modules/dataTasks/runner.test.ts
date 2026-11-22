import { afterEach, describe, expect, test } from "bun:test"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { db } from "@in/server/db"
import { dataTaskItems, dataTaskRuns, users } from "@in/server/db/schema"
import { and, eq, inArray, sql } from "drizzle-orm"
import { runPendingDataTasks } from "./automatic"
import { DataTaskSkip, defineDataTask, type DataTaskItem, type DataTaskLimits } from "./dataTask"
import { buildPlan, DataTaskError, revertDataTask } from "./runner"

const noSleep = async () => {}

/**
 * Sets `bio` to "done" on the given users whose bio is a tier name: "todo"
 * applies, "keep" is a noop, "skip" refuses at apply time, "bad" applies
 * something `verify` rejects.
 */
function bioTask(id: string, userIds: number[], limits: Partial<DataTaskLimits> = {}, check?: () => string | undefined) {
  return defineDataTask({
    id,
    description: "test",
    limits: { maxItems: 100, maxPerTier: { todo: 100, keep: 100, skip: 100, bad: 100 }, ...limits },
    check,
    async select() {
      const rows = await db.select({ id: users.id, bio: users.bio }).from(users).where(inArray(users.id, userIds))
      return rows
        .filter((row) => ["todo", "keep", "skip", "bad"].includes(row.bio ?? ""))
        .map((row): DataTaskItem => ({ key: `user:${row.id}`, tier: row.bio!, noop: row.bio === "keep", plan: { userId: row.id } }))
    },
    async apply(tx, item) {
      const { userId } = item.plan as { userId: number }
      // Written before a skip, so a skipped item proves its transaction rolled back.
      await tx.update(users).set({ bio: item.tier === "bad" ? "wrong" : "done" }).where(eq(users.id, userId))
      if (item.tier === "skip") throw new DataTaskSkip("refused")
      return { before: { bio: item.tier }, after: { bio: "done" } }
    },
    async verify(tx, item) {
      const { userId } = item.plan as { userId: number }
      const [row] = await tx.select({ bio: users.bio }).from(users).where(eq(users.id, userId))
      return row?.bio === "done" ? undefined : `bio is ${row?.bio}`
    },
    async revert(tx, entry) {
      const { userId } = entry.plan as { userId: number }
      const [row] = await tx.select({ bio: users.bio }).from(users).where(eq(users.id, userId))
      if (row?.bio !== "done") throw new DataTaskSkip("changed since apply")
      await tx.update(users).set({ bio: "todo" }).where(eq(users.id, userId))
      return {}
    },
  })
}

let userCount = 0
async function usersWithBio(bios: string[]) {
  const created = []
  for (const bio of bios) {
    const user = await testUtils.createUser(`bio-${++userCount}@example.test`)
    await db.update(users).set({ bio }).where(eq(users.id, user.id))
    created.push(user.id)
  }
  return created
}

const bioOf = async (id: number) => (await db.select({ bio: users.bio }).from(users).where(eq(users.id, id)))[0]?.bio
const runsOf = (taskId: string) => db.select().from(dataTaskRuns).where(eq(dataTaskRuns.taskId, taskId)).orderBy(dataTaskRuns.id)
const ledgerKeys = async (taskId: string) =>
  (await db.select({ key: dataTaskItems.itemKey }).from(dataTaskItems).where(eq(dataTaskItems.taskId, taskId))).map((row) => row.key).sort()

describe("buildPlan", () => {
  test("hashes the same items equally whatever their order or key order", () => {
    const a = buildPlan("t", [
      { key: "b", tier: "x", plan: { one: 1, two: [2, { z: 1, a: 2 }] } },
      { key: "a", tier: "y", plan: null },
    ])
    const b = buildPlan("t", [
      { key: "a", tier: "y", plan: null },
      { key: "b", tier: "x", plan: { two: [2, { a: 2, z: 1 }], one: 1 } },
    ])
    expect(a.hash).toBe(b.hash)
    expect(a.tiers).toEqual({ x: 1, y: 1 })
    expect(buildPlan("t", [{ key: "a", tier: "y", plan: 1 }]).hash).not.toBe(buildPlan("t", [{ key: "a", tier: "y", plan: 2 }]).hash)
  })

  test("rejects duplicate keys", () => {
    expect(() => buildPlan("t", [{ key: "a", tier: "x", plan: 1 }, { key: "a", tier: "x", plan: 2 }])).toThrow(DataTaskError)
  })
})

describe("automatic data tasks", () => {
  setupTestLifecycle()
  afterEach(() => { delete process.env["DATA_TASKS_PAUSED"] })

  test("apply every pending task once, in order, and then never again", async () => {
    const [a, keep, b] = await usersWithBio(["todo", "keep", "todo"])
    const first = bioTask("first", [a!, keep!])
    const second = bioTask("second", [b!])

    const reports = await runPendingDataTasks({ tasks: [first, second], sleep: noSleep, sourceCommit: "abc" })
    expect(reports).toEqual([
      { taskId: "first", status: "completed", applied: 1, skipped: 0 },
      { taskId: "second", status: "completed", applied: 1, skipped: 0 },
    ])
    expect([await bioOf(a!), await bioOf(keep!), await bioOf(b!)]).toEqual(["done", "keep", "done"])
    const [run] = await runsOf("first")
    expect(run).toMatchObject({ status: "completed", items: 2, applied: 1, sourceCommit: "abc" })
    expect(run?.finishedAt).not.toBeNull()

    // New matching rows after completion are not picked up: a task runs once, like a migration.
    const [late] = await usersWithBio(["todo"])
    const again = await runPendingDataTasks({ tasks: [bioTask("first", [a!, late!]), second], sleep: noSleep })
    expect(again.map((report) => report.status)).toEqual(["already-completed", "already-completed"])
    expect(await bioOf(late!)).toBe("todo")
  })

  test("a plan past its limits is blocked whole and holds back later tasks", async () => {
    const [a, b, c] = await usersWithBio(["todo", "todo", "todo"])
    const tooMany = bioTask("too-many", [a!, b!], { maxItems: 1 })
    const later = bioTask("later", [c!])

    const reports = await runPendingDataTasks({ tasks: [tooMany, later], sleep: noSleep })
    expect(reports).toEqual([{ taskId: "too-many", status: "blocked", applied: 0, skipped: 0, reason: "2 items exceed the limit of 1" }])
    expect([await bioOf(a!), await bioOf(b!), await bioOf(c!)]).toEqual(["todo", "todo", "todo"])

    const unexpectedTier = await runPendingDataTasks({ tasks: [bioTask("tiers", [a!], { maxPerTier: { keep: 1 } })], sleep: noSleep })
    expect(unexpectedTier[0]).toMatchObject({ status: "blocked", reason: 'unexpected tier "todo"' })
    const checked = await runPendingDataTasks({ tasks: [bioTask("checked", [a!], {}, () => "custom invariant")], sleep: noSleep })
    expect(checked[0]).toMatchObject({ status: "blocked", reason: "custom invariant" })
    expect(await bioOf(a!)).toBe("todo")

    // Blocked runs retry on a later tick; once the limit is fixed the task completes.
    const fixed = await runPendingDataTasks({ tasks: [bioTask("too-many", [a!, b!], { maxItems: 2 }), later], sleep: noSleep })
    expect(fixed.map((report) => report.status)).toEqual(["completed", "completed"])
    expect((await runsOf("too-many")).map((run) => run.status)).toEqual(["blocked", "completed"])
  })

  test("skips within the limit complete; past it the run stops, keeping what applied", async () => {
    const [skip, todo] = await usersWithBio(["skip", "todo"])
    const allowed = await runPendingDataTasks({ tasks: [bioTask("allowed", [skip!, todo!], { maxSkips: 1 })], sleep: noSleep })
    expect(allowed[0]).toMatchObject({ status: "completed", applied: 1, skipped: 1 })
    expect(await bioOf(skip!)).toBe("skip")
    expect(await ledgerKeys("allowed")).toEqual([`user:${todo}`])

    const [skip2, todo2] = await usersWithBio(["skip", "todo"])
    const strict = await runPendingDataTasks({ tasks: [bioTask("strict", [skip2!, todo2!])], sleep: noSleep })
    expect(strict[0]).toMatchObject({ status: "blocked", skipped: 1 })
    expect(strict[0]?.reason).toContain("1 items skipped, limit 0")
  })

  test("a failed verify rolls the item back and stops the run", async () => {
    const [bad, todo] = await usersWithBio(["bad", "todo"])
    const task = bioTask("verified", [bad!, todo!])
    const reports = await runPendingDataTasks({ tasks: [task], sleep: noSleep })
    expect(reports[0]).toMatchObject({ status: "failed", applied: 0 })
    expect(reports[0]?.reason).toBe(`Verification failed for user:${bad}: bio is wrong`)
    expect(await bioOf(bad!)).toBe("bad")
    expect(await ledgerKeys("verified")).toEqual([])
    // Keys sort, so the later item was never reached.
    expect(await bioOf(todo!)).toBe("todo")
  })

  test("a stopping process pauses between items and the next run resumes", async () => {
    const ids = await usersWithBio(["todo", "todo", "todo"])
    const task = bioTask("resumable", ids)
    let checks = 0
    const paused = await runPendingDataTasks({ tasks: [task], sleep: noSleep, shouldStop: () => ++checks > 1 })
    expect(paused[0]).toMatchObject({ status: "paused", applied: 1, reason: "process stopping" })

    const resumed = await runPendingDataTasks({ tasks: [task], sleep: noSleep })
    expect(resumed[0]).toMatchObject({ status: "completed", applied: 2 })
    expect(await ledgerKeys("resumable")).toHaveLength(3)
  })

  test("one live run per task; a stale lease is taken over", async () => {
    const [a] = await usersWithBio(["todo"])
    const task = bioTask("leased", [a!])
    await db.insert(dataTaskRuns).values({ taskId: "leased", status: "running" })
    expect((await runPendingDataTasks({ tasks: [task], sleep: noSleep }))[0]).toMatchObject({ status: "busy" })
    expect(await bioOf(a!)).toBe("todo")

    await db.update(dataTaskRuns).set({ heartbeatAt: sql`now() - interval '10 minutes'` }).where(eq(dataTaskRuns.taskId, "leased"))
    expect((await runPendingDataTasks({ tasks: [task], sleep: noSleep }))[0]).toMatchObject({ status: "completed" })
    expect((await runsOf("leased")).map((run) => [run.status, run.reason])).toEqual([["failed", "lease expired"], ["completed", null]])
  })

  test("DATA_TASKS_PAUSED stops every run", async () => {
    const [a] = await usersWithBio(["todo"])
    process.env["DATA_TASKS_PAUSED"] = "1"
    expect(await runPendingDataTasks({ tasks: [bioTask("paused", [a!])], sleep: noSleep })).toEqual([])
    expect(await runsOf("paused")).toHaveLength(0)
  })

  test("reverts applied items unless they changed since, and never reapplies them", async () => {
    const [a, b] = await usersWithBio(["todo", "todo"])
    const task = bioTask("reverted", [a!, b!])
    await runPendingDataTasks({ tasks: [task], sleep: noSleep })
    await db.update(users).set({ bio: "edited" }).where(eq(users.id, b!))

    const summary = await revertDataTask(task)
    expect(summary).toEqual({ reverted: 1, skipped: [{ key: `user:${b}`, reason: "changed since apply" }] })
    expect([await bioOf(a!), await bioOf(b!)]).toEqual(["todo", "edited"])
    expect(await revertDataTask(task, { keys: [`user:${a}`] })).toEqual({ reverted: 0, skipped: [] })
    const reverted = await db.select().from(dataTaskItems).where(and(eq(dataTaskItems.taskId, "reverted"), sql`${dataTaskItems.revertedAt} is not null`))
    expect(reverted).toHaveLength(1)
  })
})
