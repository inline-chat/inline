import { describe, expect, test } from "bun:test"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { handler as createSpace } from "@in/server/methods/createSpace"

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
})
