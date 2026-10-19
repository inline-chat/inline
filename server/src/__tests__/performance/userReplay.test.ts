import { expect, test } from "bun:test"
import { eq } from "drizzle-orm"
import { GetUpdatesResult as ResultMessage } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { members } from "@in/server/db/schema"
import { accessQueryComment } from "@in/server/db/databaseDiagnostics"
import { getUpdates } from "@in/server/functions/updates.getUpdates"
import { setupTestLifecycle, testUtils } from "../setup"
import { prepareScenario } from "./scenarios"
import { selectScenarios } from "./catalog"
import { assertQueryBudget, measureOperation } from "./measure"

setupTestLifecycle()

test.each(["updates.user-replay.100", "updates.user-replay.revoked.100"])("%s projects page access once and keeps complete page accounting", async (id) => {
  const spec = selectScenarios([id])[0]!
  const operation = await prepareScenario(spec)
  const reads: { source: string; parameters: number }[] = []
  const sample = await measureOperation(db.$client.options, async () => {
    const debug = db.$client.options.debug
    db.$client.options.debug = (connection, query, parameters, types) => {
      for (const source of ["sync.replay", "sync.sidecars"] as const) {
        if (query.trimEnd().endsWith(accessQueryComment(source))) reads.push({ source, parameters: parameters.length })
      }
      if (typeof debug === "function") debug(connection, query, parameters, types)
    }
    try { await operation.run() } finally { db.$client.options.debug = debug }
  }, async () => {})
  assertQueryBudget(id, sample, spec.maxCommands)
  await operation.verify()
  // The replay filter projects every chat on the page once; the sidecar pass
  // reuses those results through the per-request access cache, so a 100-chat
  // page costs one access batch instead of two.
  expect(reads).toEqual([
    { source: "sync.replay", parameters: 301 },
  ])
})

test("a warmed 100-chat user page cannot disclose snapshots after Space membership revocation", async () => {
  const operation = await prepareScenario(selectScenarios(["updates.user-replay.100"])[0]!)
  await operation.run()
  await operation.verify()
  const viewer = await db.query.users.findFirst({ where: { email: "bench-replay-viewer@example.test" } })
  if (!viewer) throw new Error("Missing replay viewer")
  await db.delete(members).where(eq(members.userId, viewer.id))
  const result = await getUpdates({
    bucket: { type: { oneofKind: "user", user: {} } }, startSeq: 0n, seqEnd: 0n, totalLimit: 0, limit: 100,
  }, testUtils.functionContext({ userId: viewer.id }))
  expect(result.seq).toBe(100n)
  expect(result.final).toBe(true)
  expect(result.updates).toEqual([])
  expect(result.skippedSequences.map((entry) => entry.seq)).toEqual(Array.from({ length: 100 }, (_, index) => BigInt(index + 1)))
  expect(result.sidecars).toBeUndefined()
  expect(Buffer.from(ResultMessage.toBinary(result)).includes(Buffer.from("Replay private snapshot"))).toBe(false)
})
