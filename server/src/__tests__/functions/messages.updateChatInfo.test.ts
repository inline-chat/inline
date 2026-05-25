import { describe, expect, test } from "bun:test"
import { eq } from "drizzle-orm"
import { db } from "@in/server/db"
import * as schema from "@in/server/db/schema"
import { updateChatInfo } from "@in/server/functions/messages.updateChatInfo"
import { setupTestLifecycle, testUtils } from "../setup"

describe("messages.updateChatInfo", () => {
  setupTestLifecycle()

  test("renames linked reply threads through inherited parent access", async () => {
    const owner = await testUtils.createUser("rename-reply-owner@example.com")
    const participant = await testUtils.createUser("rename-reply-participant@example.com")

    const parentChat = await testUtils.createChat(null, "Parent Thread", "thread", false, owner.id)
    if (!parentChat) {
      throw new Error("Parent chat not created")
    }

    await testUtils.addParticipant(parentChat.id, owner.id)
    await testUtils.addParticipant(parentChat.id, participant.id)

    await db.insert(schema.messages).values({
      chatId: parentChat.id,
      messageId: 1,
      fromId: owner.id,
      text: "anchor",
    })

    const [replyThread] = await db
      .insert(schema.chats)
      .values({
        type: "thread",
        title: null,
        publicThread: false,
        createdBy: owner.id,
        parentChatId: parentChat.id,
        parentMessageId: 1,
      })
      .returning()

    if (!replyThread) {
      throw new Error("Reply thread not created")
    }

    const result = await updateChatInfo(
      {
        chatId: replyThread.id,
        title: "Renamed reply",
      },
      testUtils.functionContext({ userId: participant.id }),
    )

    expect(result.chat.title).toBe("Renamed reply")

    const [saved] = await db
      .select({ title: schema.chats.title })
      .from(schema.chats)
      .where(eq(schema.chats.id, replyThread.id))
      .limit(1)

    expect(saved?.title).toBe("Renamed reply")
  })
})
