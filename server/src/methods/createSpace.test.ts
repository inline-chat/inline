import { describe, expect, test } from "bun:test"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { db } from "@in/server/db"
import { spaces } from "@in/server/db/schema"
import { createChat } from "@in/server/functions/messages.createChat"
import { handler as createSpace } from "@in/server/methods/createSpace"
import { eq } from "drizzle-orm"

const legacyContext = (userId: number) => ({ currentUserId: userId, currentSessionId: 1, ip: undefined })

describe("createSpace", () => {
  setupTestLifecycle()

  test("names the primary chat after the space", async () => {
    const owner = await testUtils.createUser("space-primary-chat-owner@example.com")

    const result = await createSpace({ name: "Town Hall" }, legacyContext(owner.id))

    expect(result.space.name).toBe("Town Hall")
    expect(result.chats).toHaveLength(1)
    expect(result.chats[0]?.title).toBe("Town Hall")
    expect(result.dialogs).toHaveLength(1)
    expect(result.dialogs[0]?.open).toBe(true)
    expect(result.dialogs[0]?.order).toBeString()
  })

  test("consumes the space counter for the primary chat", async () => {
    const owner = await testUtils.createUser("space-primary-thread-number-owner@example.com")
    const result = await createSpace({ name: "Numbered Town Hall" }, legacyContext(owner.id))

    expect(result.chats[0]?.number).toBe(1)

    const created = await createChat(
      {
        title: "Second Thread",
        spaceId: BigInt(result.space.id),
        isPublic: true,
      },
      { currentUserId: owner.id, currentSessionId: 1 },
    )

    expect(created.chat.number).toBe(2)

    const [storedSpace] = await db
      .select({ nextThreadNumber: spaces.nextThreadNumber })
      .from(spaces)
      .where(eq(spaces.id, result.space.id))
      .limit(1)
    expect(storedSpace?.nextThreadNumber).toBe(3)
  })
})
