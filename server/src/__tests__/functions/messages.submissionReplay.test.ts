import { describe, expect, spyOn, test } from "bun:test"
import { and, eq, sql } from "drizzle-orm"
import { Effect } from "effect"
import { db, schema } from "@in/server/db"
import type { Transaction } from "@in/server/db/types"
import { MessageModel } from "@in/server/db/models/messages"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { deleteMessage } from "@in/server/functions/messages.deleteMessage"
import { deleteChat } from "@in/server/functions/messages.deleteChat"
import { removeChatParticipant } from "@in/server/functions/messages.removeChatParticipant"
import { moveThread } from "@in/server/functions/messages.moveThread"
import { deleteMember } from "@in/server/functions/space.deleteMember"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { applicationBackgroundWork } from "@in/server/lifecycle/backgroundWork"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { setupTestLifecycle, testUtils } from "../setup"

const peer = (chatId: number) => ({ type: { oneofKind: "chat" as const, chat: { chatId: BigInt(chatId) } } })

describe("ordinary submission replay current authority", () => {
  setupTestLifecycle()

  for (const legacy of [false, true]) {
    for (const child of [false, true]) {
      test(`${legacy ? "pre-ledger" : "receipt"} replay rechecks ${child ? "inherited root" : "direct"} removal after preflight`, async () => {
        const scenario = await createScenario(`${legacy}-${child}`, { legacy, child })
        await afterPreflight(scenario, () => removeChatParticipant(
          { chatId: scenario.root.id, userId: scenario.actor.id }, scenario.ownerContext,
        ), RealtimeRpcError.Code.PEER_ID_INVALID)
        expect(await destinationMessages(scenario)).toHaveLength(1)
        expect(await receipts(scenario)).toHaveLength(legacy ? 0 : 1)
      })
    }
  }

  test("a deleted-message receipt cannot return its tombstone after inherited access is revoked", async () => {
    const scenario = await createScenario("tombstone")
    await deleteMessage({ peer: scenario.input.peerId, messageIds: [1n] }, scenario.context)
    await applicationBackgroundWork.waitForIdle()
    await afterPreflight(scenario, () => removeChatParticipant(
      { chatId: scenario.root.id, userId: scenario.actor.id }, scenario.ownerContext,
    ), RealtimeRpcError.Code.PEER_ID_INVALID)
    expect(await destinationMessages(scenario)).toHaveLength(0)
    expect(await receipts(scenario)).toHaveLength(1)
  })

  test("destination deletion after preflight rejects replay without resurrecting its retained identity", async () => {
    const scenario = await createScenario("deleted-chat")
    await afterPreflight(scenario, () => deleteChat({ peer: scenario.input.peerId }, scenario.ownerContext), RealtimeRpcError.Code.PEER_ID_INVALID)
    expect(await destinationMessages(scenario)).toHaveLength(0)
    expect(await db.select().from(schema.chats).where(eq(schema.chats.id, scenario.chat.id))).toHaveLength(0)
    expect(await receipts(scenario)).toHaveLength(1)
  })

  test("an ancestor moved into a Space uses current inherited membership on replay", async () => {
    const scenario = await createScenario("moved-root")
    await afterPreflight(scenario, async () => {
      await moveThread({ chatId: scenario.root.id, spaceId: scenario.space.id }, scenario.ownerContext)
      await Effect.runPromise(deleteMember({
        spaceId: BigInt(scenario.space.id), userId: BigInt(scenario.actor.id), blockJoin: false,
      }, scenario.ownerContext))
    }, RealtimeRpcError.Code.SPACE_ID_INVALID)
    expect(await destinationMessages(scenario)).toHaveLength(1)
    expect(await receipts(scenario)).toHaveLength(1)
  })

  for (const legacy of [false, true]) {
    test(`${legacy ? "pre-ledger" : "receipt"} replay holds ancestor authority until identity recovery finishes`, async () => {
      const scenario = await createScenario(`replay-first-${legacy}`, { legacy })
      await observeTransactions(async (deadlocks) => {
        const entered = Promise.withResolvers<number>()
        const release = Promise.withResolvers<void>()
        const originalGuard = AccessGuards.ensureChatAccess
        const guard = spyOn(AccessGuards, "ensureChatAccess").mockImplementation(async (...args) => {
          await originalGuard(...args)
          if (args[0].id === scenario.chat.id && args[2] !== undefined) {
            const [row] = await (args[2] as Transaction).execute(sql`select pg_backend_pid() as pid`)
            entered.resolve(Number(row!["pid"]))
            await release.promise
          }
        })
        const replay = outcome(sendMessage(scenario.input, scenario.context))
        let removal: ReturnType<typeof outcome> | undefined
        try {
          const pid = await bounded(entered.promise)
          removal = outcome(removeChatParticipant({ chatId: scenario.root.id, userId: scenario.actor.id }, scenario.ownerContext))
          await waitForBlocked(pid)
          release.resolve()
          const [replayed, removed] = await bounded(Promise.all([replay, removal]))
          if ("error" in replayed) throw replayed.error
          if ("error" in removed) throw removed.error
          expect(replayed.value.updates.map((update) => update.update.oneofKind)).toEqual(["updateMessageId"])
          expect(deadlocks()).toBe(0)
        } finally {
          release.resolve()
          try { await bounded(Promise.all(removal ? [replay, removal] : [replay])) }
          finally { guard.mockRestore() }
        }
        // The sender's identity is retained, but the next request has no access.
        await expect(sendMessage(scenario.input, scenario.context)).rejects.toMatchObject({ code: RealtimeRpcError.Code.PEER_ID_INVALID })
      })
    })
  }

  test("a receipt replay reuses its supplied transaction when every other pool connection is occupied", async () => {
    const scenario = await createScenario("outer-transaction")
    const entered = Promise.withResolvers<void>()
    const release = Promise.withResolvers<void>()
    const originalGuard = AccessGuards.ensureChatAccess
    const guard = spyOn(AccessGuards, "ensureChatAccess").mockImplementation(async (...args) => {
      await originalGuard(...args)
      if (args[0].id === scenario.chat.id && args[2] === undefined) {
        entered.resolve()
        await release.promise
      }
    })
    const unpark = Promise.withResolvers<void>()
    const parked = Array.from({ length: 9 }, () => Promise.withResolvers<void>())
    const holders: Promise<unknown>[] = []
    let onCommittedCalls = 0
    const replay = outcome(db.transaction((tx) => sendMessage(scenario.input, scenario.context, {
      transaction: tx, onCommitted: () => { onCommittedCalls++ },
    })))
    try {
      await bounded(entered.promise)
      holders.push(...parked.map((ready) => db.transaction(async (tx) => {
        await tx.execute(sql`select 1`)
        ready.resolve()
        await unpark.promise
      })))
      await bounded(Promise.all(parked.map((ready) => ready.promise)))
      release.resolve()
      const result = await bounded(replay)
      if ("error" in result) throw result.error
      expect(result.value.updates.map((update) => update.update.oneofKind)).toEqual(["updateMessageId"])
      expect(onCommittedCalls).toBe(0)
    } finally {
      release.resolve(); unpark.resolve()
      try { await bounded(Promise.all([replay, ...holders])) }
      finally { guard.mockRestore() }
    }
  })

  test("pre-ledger compatibility returns only identity without pretending to prove submitted content", async () => {
    const scenario = await createScenario("legacy-content", { legacy: true })
    const replayed = await sendMessage({ ...scenario.input, message: "Different legacy request" }, scenario.context)
    expect(replayed.updates.map((update) => update.update.oneofKind)).toEqual(["updateMessageId"])
    expect((await MessageModel.getMessage(1, scenario.chat.id)).text).toBe(scenario.input.message)
    expect(await destinationMessages(scenario)).toHaveLength(1)
    expect(await receipts(scenario)).toHaveLength(0)
  })
})

async function createScenario(label: string, options: { legacy?: boolean; child?: boolean } = {}) {
  const { space, users: [owner, actor] } = await testUtils.createSpaceWithMembers("Replay authority", [
    `replay-${label}-owner@example.test`, `replay-${label}-actor@example.test`,
  ])
  await db.update(schema.members).set({ role: "owner" }).where(and(eq(schema.members.spaceId, space.id), eq(schema.members.userId, owner.id)))
  const root = await testUtils.createChat(null, "Replay root", "thread", false, owner.id)
  if (!root) throw new Error("Replay root missing")
  await testUtils.addParticipant(root.id, owner.id)
  await testUtils.addParticipant(root.id, actor.id)
  const child = options.child === false ? undefined : await testUtils.createChat(null, "Replay task", "thread", false, owner.id)
  if (options.child !== false && !child) throw new Error("Replay child missing")
  if (child) {
    await db.update(schema.chats).set({ parentChatId: root.id }).where(eq(schema.chats.id, child.id))
    await testUtils.addParticipant(child.id, owner.id)
  }
  const chat = child ?? root
  const context = testUtils.functionContext({ userId: actor.id })
  const ownerContext = testUtils.functionContext({ userId: owner.id })
  const input = { peerId: peer(chat.id), message: "Original ordinary request", randomId: 5001n }
  await sendMessage(input, context)
  await applicationBackgroundWork.waitForIdle()
  if (options.legacy) await db.delete(schema.messageSubmissions).where(and(
    eq(schema.messageSubmissions.fromId, actor.id), eq(schema.messageSubmissions.randomId, input.randomId),
  ))
  return { root, chat, space, owner, actor, context, ownerContext, input }
}

type Scenario = Awaited<ReturnType<typeof createScenario>>
const receipts = (scenario: Scenario) => db.select().from(schema.messageSubmissions).where(and(
  eq(schema.messageSubmissions.fromId, scenario.actor.id), eq(schema.messageSubmissions.randomId, scenario.input.randomId),
))
const destinationMessages = (scenario: Scenario) => db.select().from(schema.messages).where(eq(schema.messages.chatId, scenario.chat.id))

async function afterPreflight(scenario: Scenario, mutate: () => Promise<unknown>, expectedCode: RealtimeRpcError["code"]) {
  await observeTransactions(async (deadlocks) => {
    const entered = Promise.withResolvers<void>()
    const release = Promise.withResolvers<void>()
    const originalGuard = AccessGuards.ensureChatAccess
    const guard = spyOn(AccessGuards, "ensureChatAccess").mockImplementation(async (...args) => {
      await originalGuard(...args)
      if (args[0].id === scenario.chat.id && args[2] === undefined) {
        entered.resolve()
        await release.promise
      }
    })
    const replay = outcome(sendMessage(scenario.input, scenario.context))
    try {
      await bounded(entered.promise)
      await bounded(mutate())
      release.resolve()
      const result = await bounded(replay)
      expect("error" in result ? result.error : undefined).toMatchObject({ code: expectedCode })
      expect(deadlocks()).toBe(0)
    } finally {
      release.resolve()
      try { await bounded(replay) }
      finally { guard.mockRestore() }
    }
  })
}

async function observeTransactions(run: (deadlocks: () => number) => Promise<void>) {
  const original = db.transaction.bind(db)
  let deadlocks = 0
  const spy = spyOn(db, "transaction").mockImplementation((callback, config) => original(async (tx) => {
    await tx.execute(sql`set local lock_timeout = '3s'`)
    await tx.execute(sql`set local statement_timeout = '5s'`)
    return callback(tx)
  }, config).catch((error: unknown) => {
    let cause = error
    for (let i = 0; i < 4 && typeof cause === "object" && cause !== null; i++) {
      if ("code" in cause && cause.code === "40P01") deadlocks++
      cause = "cause" in cause ? cause.cause : undefined
    }
    throw error
  }))
  try { await run(() => deadlocks) }
  finally { spy.mockRestore() }
}

const outcome = <T>(operation: Promise<T>) => operation.then((value) => ({ value }), (error: unknown) => ({ error }))
async function bounded<T>(operation: Promise<T>): Promise<T> {
  return Promise.race([operation, Bun.sleep(6_000).then(() => { throw new Error("Replay race exceeded its bounded deadline") })])
}
async function waitForBlocked(pid: number) {
  const deadline = Date.now() + 3_000
  while (true) {
    const [row] = await db.execute(sql`select exists (
      select 1 from pg_stat_activity where datname = current_database() and ${pid} = any(pg_blocking_pids(pid))
    ) as blocked`)
    if (row?.["blocked"] === true) return
    if (Date.now() >= deadline) throw new Error("Actual removal did not wait on replay's authority lock")
    await Bun.sleep(5)
  }
}
