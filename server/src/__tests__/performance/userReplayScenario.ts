import assert from "node:assert/strict"
import { and, eq } from "drizzle-orm"
import { GetUpdatesResult as ResultMessage, SyncSkippedSequence_Reason } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import * as S from "@in/server/db/schema"
import { UpdatesModel } from "@in/server/db/models/updates"
import { getUpdates } from "@in/server/functions/updates.getUpdates"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { testUtils } from "../setup"
import type { PreparedOperation } from "./scenarios"

/** A full user page, not a chat-bucket replay: both access sources see batches. */
export async function prepareUserReplayScenario(size: number, revokeOne: boolean): Promise<PreparedOperation> {
  const users = await db.insert(S.users).values([
    { email: "bench-replay-viewer@example.test" }, { email: "bench-replay-owner@example.test" },
  ]).returning()
  const viewer = users[0]!, owner = users[1]!
  const { session } = await testUtils.createSessionForUser(viewer.id, { clientType: "web" })
  const context = testUtils.functionContext({ userId: viewer.id, sessionId: session.id })
  const [space] = await db.insert(S.spaces).values({ name: "Replay benchmark space" }).returning()
  assert(space)
  await db.insert(S.members).values(users.map((user) => ({ userId: user.id, spaceId: space.id, role: "member" as const })))
  const chats = await db.insert(S.chats).values(Array.from({ length: size }, (_, index) => ({
    type: "thread" as const, spaceId: space.id, publicThread: false, createdBy: owner.id,
    title: `Replay private snapshot ${index}`, isUntitled: false,
  }))).returning()
  await db.insert(S.chatParticipants).values(chats.flatMap((chat) => users.map((user) => ({ chatId: chat.id, userId: user.id }))))
  const dialogs = await db.insert(S.dialogs).values(chats.map((chat) => ({
    userId: viewer.id, chatId: chat.id, spaceId: space.id, open: true, order: "a0",
  }))).returning()
  const dialogByChat = new Map(dialogs.map((dialog) => [dialog.chatId, dialog]))
  const date = new Date()
  // Seed a valid encrypted historic page in one write. Setup is outside timing;
  // there is no bypass or replacement of the real authenticated replay reader.
  await db.insert(S.updates).values(chats.map((chat, index) => ({
    bucket: S.UpdateBucket.User, entityId: viewer.id, seq: index + 1, date,
    payload: UpdatesModel.build({ seq: index + 1, date: encodeDateStrict(date), update: {
      oneofKind: "userChatOpen", userChatOpen: {
        chat: Encoders.chat(chat, { encodingForUserId: viewer.id }),
        dialog: Encoders.dialog(dialogByChat.get(chat.id)!, { unreadCount: 0 }),
      },
    } }).encrypted,
  })))
  await db.update(S.users).set({ updateSeq: size, lastUpdateDate: date }).where(eq(S.users.id, viewer.id))
  const input = { bucket: { type: { oneofKind: "user" as const, user: {} } }, startSeq: 0n, seqEnd: 0n, totalLimit: 0, limit: 100 }
  const hidden = revokeOne ? chats.at(-1)! : undefined
  if (hidden) {
    // Warm both access queries before revocation. Retained dialogs and embedded
    // journal snapshots must not turn a warmed plan into cached authority.
    const warm = await getUpdates(input, context)
    assert.equal(warm.updates.length, size)
    await db.delete(S.chatParticipants).where(and(eq(S.chatParticipants.chatId, hidden.id), eq(S.chatParticipants.userId, viewer.id)))
  }
  const visible = chats.filter((chat) => chat.id !== hidden?.id).map((chat) => BigInt(chat.id))
  let result: Awaited<ReturnType<typeof getUpdates>>
  return {
    async run() { result = await getUpdates(input, context) },
    async verify() {
      assert.equal(result.seq, BigInt(size))
      assert.equal(result.final, true)
      assert.deepEqual(result.updates.map((update) => {
        assert.equal(update.update.oneofKind, "chatOpen")
        return update.update.oneofKind === "chatOpen" ? update.update.chatOpen.chat?.id : undefined
      }), visible)
      assert.deepEqual(result.sidecars?.chats.map((chat) => chat.id).sort(), [...visible].sort())
      assert.deepEqual(result.sidecars?.dialogs.map((dialog) => dialog.chatId).sort(), [...visible].sort())
      assert.deepEqual(result.skippedSequences, hidden ? [{ seq: BigInt(size), reason: SyncSkippedSequence_Reason.IRRELEVANT_TO_BUCKET }] : [])
      if (hidden) {
        // Assert the complete encoded response, including embedded historical
        // metadata, not only the filtered chat sidecar list.
        assert(!Buffer.from(ResultMessage.toBinary(result)).includes(Buffer.from(hidden.title!)))
        assert(await db.query.dialogs.findFirst({ where: { chatId: hidden.id, userId: viewer.id } }))
      }
    },
  }
}
