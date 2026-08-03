import { describe, expect, test } from "bun:test"
import { getChatTranscript } from "@in/server/functions/messages.getChatTranscript"
import { db, schema } from "@in/server/db"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"

const context = (userId: number) => ({ currentUserId: userId, currentSessionId: 1 })
const peer = (chatId: number) => ({
  type: { oneofKind: "chat" as const, chat: { chatId: BigInt(chatId) } },
})

describe("getChatTranscript", () => {
  setupTestLifecycle()

  test("returns explicit best-effort pages and reply-thread parent context", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers(
      "Transcript Space",
      ["transcript-owner@example.com", "transcript-other@example.com"],
    )
    const [owner, other] = users
    if (!owner || !other) throw new Error("Failed to create transcript users")
    const parentChat = await testUtils.createChat(space.id, "Planning", "thread", true, owner.id)
    if (!parentChat) throw new Error("Failed to create parent chat")

    await testUtils.createTestMessage({
      messageId: 10,
      chatId: parentChat.id,
      fromId: owner.id,
      text: "What should we ship?",
    })
    const [replyThread] = await db
      .insert(schema.chats)
      .values({
        type: "thread",
        title: "Launch plan",
        parentChatId: parentChat.id,
        parentMessageId: 10,
        createdBy: owner.id,
      })
      .returning()
    if (!replyThread) throw new Error("Failed to create reply thread")

    for (let messageId = 1; messageId <= 3; messageId += 1) {
      await testUtils.createTestMessage({
        messageId,
        chatId: replyThread.id,
        fromId: messageId === 2 ? other.id : owner.id,
        text: `Reply ${messageId}`,
      })
    }

    const latest = await getChatTranscript(
      { peerId: peer(replyThread.id), limit: 2 },
      context(owner.id),
    )

    expect(latest.messageCount).toBe(2)
    expect(latest.fromMessageId).toBe(2)
    expect(latest.toMessageId).toBe(3)
    expect(latest.hasMore).toBe(true)
    expect(latest.stopReason).toBe("messageLimit")
    expect(latest.markdown).toContain("# Launch plan")
    expect(latest.markdown).toContain("[Open in Inline](<https://inline.chat/c/")
    expect(latest.markdown).toContain("From [Planning](<https://inline.chat/c/")
    expect(latest.markdown).toContain("What should we ship?")
    expect(latest.markdown.indexOf("Reply 2")).toBeLessThan(latest.markdown.indexOf("Reply 3"))

    const older = await getChatTranscript(
      { peerId: peer(replyThread.id), beforeMessageId: 2n, limit: 2 },
      context(owner.id),
    )

    expect(older.messageCount).toBe(1)
    expect(older.fromMessageId).toBe(1)
    expect(older.toMessageId).toBe(1)
    expect(older.hasMore).toBe(false)
    expect(older.stopReason).toBe("complete")
  })

  test("rejects direct-message peers", async () => {
    const user = await testUtils.createUser("transcript-dm@example.com")
    await expect(
      getChatTranscript(
        {
          peerId: { type: { oneofKind: "user", user: { userId: BigInt(user.id) } } },
        },
        context(user.id),
      ),
    ).rejects.toThrow()
  })

  test("rejects non-integer transcript limits", async () => {
    await expect(
      getChatTranscript(
        { peerId: peer(1), limit: 1.5 },
        context(1),
      ),
    ).rejects.toThrow()
  })
})
