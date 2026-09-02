import { describe, expect, test } from "bun:test"
import { eq } from "drizzle-orm"
import { db } from "@in/server/db"
import * as schema from "@in/server/db/schema"
import { handler as getChatHistory } from "@in/server/methods/getChatHistory"
import { setupTestLifecycle, testUtils } from "../setup"

describe("legacy getChatHistory", () => {
  setupTestLifecycle()

  test("orders messages with the same date by descending message ID", async () => {
    const space = await testUtils.createSpace("legacy-history-order-space")
    const user = await testUtils.createUser("legacy-history-order@example.com")
    if (!space || !user) throw new Error("Failed to create test data")

    await db.insert(schema.members).values({ spaceId: space.id, userId: user.id, role: "owner" })
    const { chat, msg } = await testUtils.createThreadWithDialogAndMessage({ spaceId: space.id, user })
    const date = new Date("2026-01-01T00:00:00.000Z")
    await db.update(schema.messages).set({ date }).where(eq(schema.messages.globalId, msg.globalId))
    await db.insert(schema.messages).values({
      messageId: 2,
      chatId: chat.id,
      fromId: user.id,
      text: "newer ID",
      date,
    })

    const result = await getChatHistory(
      { peerThreadId: chat.id, limit: 10 },
      { currentUserId: user.id },
    )

    expect(result.messages.map((message) => message.id)).toEqual([2, 1])
  })
})
