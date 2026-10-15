import { expect, test } from "bun:test"
import { eq } from "drizzle-orm"
import { RpcError_Code } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { chatParticipants, members } from "@in/server/db/schema"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { getChatHistory } from "@in/server/functions/messages.getChatHistory"
import { measureOperation } from "@in/server/__tests__/performance/measure"
import { prepareScenario } from "@in/server/__tests__/performance/scenarios"
import { selectScenarios } from "@in/server/__tests__/performance/catalog"
import { withHistorySnapshot } from "./historySnapshot"

setupTestLifecycle()

const peer = (id: number) => ({ type: { oneofKind: "chat" as const, chat: { chatId: BigInt(id) } } })

async function fixture() {
  const owner = await testUtils.createUser("snapshot-owner@example.test")
  const other = await testUtils.createUser("snapshot-peer@example.test")
  const chat = await testUtils.createPrivateChat(owner, other)
  if (!chat) throw new Error("Missing private chat")
  return { owner, chat }
}

test("an explicit chat peer needs one SELECT inside its read-only snapshot", async () => {
  const { owner, chat } = await fixture()
  let returnedId: number | undefined
  const sample = await measureOperation(db.$client.options, async () => {
    returnedId = await withHistorySnapshot(peer(chat.id), owner.id, async (_tx, row) => row.id)
  }, async () => {})
  expect(returnedId).toBe(chat.id)
  // BEGIN, SET TRANSACTION, one chat SELECT, COMMIT. Authorization for a DM
  // checks this row directly; no outside-snapshot lookup is needed.
  expect(sample.sql.commands).toBe(4)
  expect(Object.entries(sample.sql.shapes).filter(([shape]) => shape.startsWith("SELECT:")).reduce((sum, [, count]) => sum + count, 0)).toBe(1)
})

test("a complete explicit-chat history page saves the redundant lookup", async () => {
  const operation = await prepareScenario(selectScenarios(["history.50"])[0]!)
  const sample = await measureOperation(db.$client.options, operation.run, async () => {})
  await operation.verify()
  expect(sample.sql.commands).toBe(10)
})

test("a missing explicit chat preserves CHAT_ID_INVALID and never enters the response reader", async () => {
  const { owner } = await fixture()
  let entered = false
  await expect(withHistorySnapshot(peer(2_147_483_647), owner.id, async () => { entered = true })).rejects.toMatchObject({ code: RpcError_Code.CHAT_ID_INVALID })
  expect(entered).toBe(false)
})

test("an explicit private-chat ID gives an outsider no history or response metadata", async () => {
  const { owner, chat } = await fixture()
  const outsider = await testUtils.createUser("snapshot-outsider@example.test")
  await testUtils.createTestMessage({ chatId: chat.id, fromId: owner.id, messageId: 1, text: "private snapshot body" })
  let entered = false
  await expect(withHistorySnapshot(peer(chat.id), outsider.id, async () => { entered = true })).rejects.toMatchObject({ code: RpcError_Code.PEER_ID_INVALID })
  expect(entered).toBe(false)
  await expect(getChatHistory({ peerId: peer(chat.id) }, testUtils.functionContext({ userId: outsider.id }))).rejects.toMatchObject({ code: RpcError_Code.PEER_ID_INVALID })
})

test("a warmed explicit-chat history read rechecks Space membership despite a retained grant", async () => {
  const { space, users } = await testUtils.createSpaceWithMembers("Snapshot authority", ["snapshot-member@example.test"])
  const viewer = users[0]!
  const chat = await testUtils.createChat(space.id, "Private snapshot title", "thread", false)
  if (!chat) throw new Error("Missing private thread")
  await testUtils.addParticipant(chat.id, viewer.id)
  await testUtils.createTestMessage({ chatId: chat.id, fromId: viewer.id, messageId: 1, text: "Private snapshot body" })
  const context = testUtils.functionContext({ userId: viewer.id })
  expect((await getChatHistory({ peerId: peer(chat.id) }, context)).messages[0]?.message).toBe("Private snapshot body")
  await db.delete(members).where(eq(members.userId, viewer.id))
  expect(await db.select().from(chatParticipants).where(eq(chatParticipants.chatId, chat.id))).toHaveLength(1)
  await expect(getChatHistory({ peerId: peer(chat.id) }, context)).rejects.toMatchObject({ code: RpcError_Code.SPACE_ID_INVALID })
})
