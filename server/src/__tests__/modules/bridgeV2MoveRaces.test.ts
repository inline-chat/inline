import { expect, test } from "bun:test"
import {
  AgentRunState, AgentSessionMessageRole, AgentSessionProvider, AgentSessionState,
  AgentSessionSyncMode, type InputPeer,
} from "@inline-chat/protocol/core"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { db } from "@in/server/db"
import { agentSessions, chats, users } from "@in/server/db/schema"
import { connectAgentSession, syncAgentSessionMessages } from "@in/server/modules/agentSessions/service"
import { moveAgentSession } from "@in/server/modules/agentSessions/move"
import { updateAgentSessionState } from "@in/server/modules/agentSessions/state"
import { eq, sql } from "drizzle-orm"

// Races between moving a work into a subthread and the writers that publish
// it. Each test holds the source chat's lock so both writers queue behind it
// in a known order, then releases it.
setupTestLifecycle()

const peer = (id: number): InputPeer => ({ type: { oneofKind: "chat", chat: { chatId: BigInt(id) } } })

async function fixture() {
  const [owner, bot] = await Promise.all(["owner", "bot"].map(name =>
    testUtils.createUser(`move-race-${name}-${crypto.randomUUID()}@example.test`)))
  if (!owner || !bot) throw new Error("users missing")
  await db.update(users).set({ bot: true, botCreatorId: owner.id }).where(eq(users.id, bot.id))
  const source = await testUtils.createChat(null, "Move source", "thread", false, owner.id)
  const target = await testUtils.createChat(null, "Move child", "thread", false, owner.id)
  if (!source || !target) throw new Error("chats missing")
  await db.update(chats).set({ parentChatId: source.id }).where(eq(chats.id, target.id))
  for (const chat of [source, target]) {
    for (const id of [owner.id, bot.id]) await testUtils.addParticipant(chat.id, id)
  }
  const connected = await connectAgentSession({
    peerId: peer(source.id), botUserId: BigInt(bot.id), provider: AgentSessionProvider.CODEX,
    instanceRef: "move-race-installation", sessionRef: crypto.randomUUID(), relation: 0,
  }, owner.id)
  if (!connected.agentSession) throw new Error("session missing")
  return { owner, bot, source, target, session: connected.agentSession }
}

async function waitForWaiters(count: number) {
  const deadline = Date.now() + 5_000
  while (Date.now() < deadline) {
    const rows = await db.execute(sql`select count(*)::int as n from pg_stat_activity
      where datname = current_database() and wait_event_type = 'Lock'`)
    if (Number(rows[0]?.n) >= count) return
    await Bun.sleep(10)
  }
  throw new Error(`did not observe ${count} lock waiters`)
}

async function holdChat(id: number) {
  let release!: () => void
  let acquired!: () => void
  const released = new Promise<void>(resolve => { release = resolve })
  const ready = new Promise<void>(resolve => { acquired = resolve })
  const transaction = db.transaction(async tx => {
    await tx.execute(sql`select id from chats where id = ${id} for update`)
    acquired()
    await released
  })
  await ready
  return { release, transaction }
}

test("a state report racing a move publishes in the destination", async () => {
  const f = await fixture()
  const lock = await holdChat(f.source.id)
  let moved: ReturnType<typeof moveAgentSession> | undefined
  let state: ReturnType<typeof updateAgentSessionState> | undefined
  try {
    moved = moveAgentSession({ agentSessionId: f.session.id, destinationPeerId: peer(f.target.id) }, f.bot.id)
    await waitForWaiters(1)
    state = updateAgentSessionState({ agentSessionId: f.session.id,
      state: AgentSessionState.create({ runState: AgentRunState.WORKING, revision: 1n }) }, f.bot.id)
    await waitForWaiters(2)
  } finally { lock.release() }
  await lock.transaction
  const moveResult = await moved!
  const stateResult = await state!
  const [stored] = await db.select().from(agentSessions).where(eq(agentSessions.id, f.session.id))
  expect(moveResult.moved).toBe(true)
  expect(stored?.chatId).toBe(f.target.id)
  const returned = stateResult.agentSession?.peerId?.type
  expect(returned?.oneofKind).toBe("chat")
  if (returned?.oneofKind !== "chat") throw new Error("not a chat")
  expect(returned.chat.chatId).toBe(BigInt(f.target.id))
}, 20_000)

test("transcript sync racing a move neither deadlocks nor publishes in the source", async () => {
  const f = await fixture()
  const lock = await holdChat(f.source.id)
  let outcomes: Promise<PromiseSettledResult<unknown>[]> | undefined
  try {
    const moved = moveAgentSession({ agentSessionId: f.session.id, destinationPeerId: peer(f.target.id) }, f.bot.id)
    await waitForWaiters(1)
    const synced = syncAgentSessionMessages({
      agentSessionId: f.session.id, mode: AgentSessionSyncMode.LIVE,
      messages: [{ role: AgentSessionMessageRole.ASSISTANT, itemRef: "move-race-output-1",
        sourceDate: 1_700_000_001n, revisionRef: "r1", complete: true,
        operation: { oneofKind: "upsert", upsert: { text: "Moved output" } } }],
    }, f.bot.id)
    outcomes = Promise.allSettled([moved, synced])
    await waitForWaiters(2)
  } finally { lock.release() }
  await lock.transaction
  const settled = await outcomes!
  const errors = settled.filter((r): r is PromiseRejectedResult => r.status === "rejected")
  const messages: string[] = []
  for (const result of errors) {
    let error: unknown = result.reason
    while (error instanceof Error) { messages.push(error.message); error = error.cause }
  }
  expect(messages).toEqual([])
  const [stored] = await db.select().from(agentSessions).where(eq(agentSessions.id, f.session.id))
  expect(stored?.chatId).toBe(f.target.id)
  const [target] = await db.select().from(chats).where(eq(chats.id, f.target.id))
  const [source] = await db.select().from(chats).where(eq(chats.id, f.source.id))
  // The output landed in the destination, not the chat the work left.
  expect(target?.lastMsgId ?? 0).toBeGreaterThan(0)
  expect(source?.lastMsgId ?? 0).toBe(0)
}, 20_000)
