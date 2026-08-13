import { describe, expect, test } from "bun:test"
import { handler as getSpace } from "@in/server/methods/getSpace"
import { InlineError } from "@in/server/types/errors"
import { setupTestLifecycle, testUtils } from "../setup"

describe("legacy getSpace error boundary", () => {
  setupTestLifecycle()

  test("preserves the exact expected error for a non-member", async () => {
    const { space } = await testUtils.createSpaceWithMembers("Private Space", ["member@get-space.test"])
    const outsider = await testUtils.createUser("outsider@get-space.test")

    try {
      await getSpace({ id: space.id }, { currentUserId: outsider.id })
      throw new Error("Expected getSpace to reject")
    } catch (error) {
      expect(error).toBeInstanceOf(InlineError)
      expect(error).toMatchObject({
        type: "USER_NOT_PARTICIPANT",
        code: 400,
      })
    }
  })
})
