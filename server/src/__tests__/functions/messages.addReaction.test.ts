import { describe, expect, test } from "bun:test"
import { addReaction } from "@in/server/functions/messages.addReaction"
import { deleteReaction } from "@in/server/functions/messages.deleteReaction"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { setupTestLifecycle, testUtils } from "../setup"
import { db } from "@in/server/db"
import { chats, UpdateBucket, updates } from "@in/server/db/schema"
import { and, eq } from "drizzle-orm"

describe("addReaction", () => {
  setupTestLifecycle()

  test("rejects arbitrary non-emoji strings before resolving the target chat", async () => {
    await expect(addReaction(
      {
        emoji: "not-an-emoji",
        messageId: 1n,
        peer: { type: { oneofKind: "chat", chat: { chatId: 1n } } },
      },
      { currentUserId: 1, currentSessionId: 1 },
    )).rejects.toMatchObject({ code: RealtimeRpcError.Code.BAD_REQUEST })
  })

  test("publishes reaction mutations without consuming the chat sequence", async () => {
    const sender = await testUtils.createUser("ephemeral-reaction-sender@example.com")
    const peer = await testUtils.createUser("ephemeral-reaction-peer@example.com")
    const chat = await testUtils.createPrivateChat(sender, peer)
    if (!chat) throw new Error("Failed to create reaction DM")
    const message = await testUtils.createTestMessage({
      messageId: 1,
      fromId: sender.id,
      chatId: chat.id,
      text: "reaction target",
    })
    const [before] = await db
      .select({ updateSeq: chats.updateSeq, lastUpdateDate: chats.lastUpdateDate })
      .from(chats)
      .where(eq(chats.id, chat.id))
      .limit(1)

    const result = await addReaction(
      {
        emoji: "👍",
        messageId: BigInt(message.messageId),
        peer: { type: { oneofKind: "user", user: { userId: BigInt(peer.id) } } },
      },
      testUtils.functionContext({ userId: sender.id }),
    )

    expect(result.updates).toHaveLength(1)
    expect(result.updates[0]?.seq).toBeUndefined()
    expect(result.updates[0]?.date).toBeUndefined()

    const deleted = await deleteReaction(
      {
        emoji: "👍",
        messageId: BigInt(message.messageId),
        peer: { type: { oneofKind: "user", user: { userId: BigInt(peer.id) } } },
      },
      testUtils.functionContext({ userId: sender.id }),
    )
    expect(deleted.updates).toHaveLength(1)
    expect(deleted.updates[0]?.seq).toBeUndefined()
    expect(deleted.updates[0]?.date).toBeUndefined()

    const durableReactionUpdates = await db
      .select({ seq: updates.seq })
      .from(updates)
      .where(and(eq(updates.bucket, UpdateBucket.Chat), eq(updates.entityId, chat.id)))
    expect(durableReactionUpdates).toEqual([])
    const [after] = await db
      .select({ updateSeq: chats.updateSeq, lastUpdateDate: chats.lastUpdateDate })
      .from(chats)
      .where(eq(chats.id, chat.id))
      .limit(1)
    expect(after).toEqual(before)
  })
})
