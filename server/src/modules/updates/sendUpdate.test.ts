import { describe, expect, test } from "bun:test"
import { getNewUpdatesForUserPresenceUpdate } from "./sendUpdate"

describe("presence update encoding", () => {
  test("encodes last-online timestamps as Unix seconds", () => {
    const update = getNewUpdatesForUserPresenceUpdate(
      42,
      false,
      new Date("2026-08-16T00:00:00.000Z"),
    )

    expect(update.update.oneofKind).toBe("updateUserStatus")
    if (update.update.oneofKind !== "updateUserStatus") {
      throw new Error("Expected a user status update")
    }

    expect(update.update.updateUserStatus.status?.lastOnline?.date)
      .toBe(1_786_838_400n)
  })
})
