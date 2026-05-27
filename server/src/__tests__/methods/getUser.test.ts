import { describe, expect, test } from "bun:test"
import { handler as getUser } from "@in/server/methods/getUser"
import { setupTestLifecycle, testUtils } from "../setup"

describe("getUser", () => {
  setupTestLifecycle()

  test("returns public user info without private metadata for arbitrary users", async () => {
    const viewer = await testUtils.createUser("get-user-viewer@example.com")
    const target = await testUtils.createUser("get-user-target@example.com")

    const result = await getUser({ id: target.id }, { currentUserId: viewer.id, currentSessionId: 1, ip: "127.0.0.1" })

    const user = result.user as any
    expect(user.id).toBe(target.id)
    expect(user.email).toBeUndefined()
    expect(user.phoneNumber).toBeUndefined()
    expect(user.online).toBeUndefined()
    expect(user.lastOnline).toBeUndefined()
  })
})
