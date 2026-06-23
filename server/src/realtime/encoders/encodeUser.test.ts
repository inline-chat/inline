import { describe, expect, it } from "bun:test"
import type { DbUser } from "@in/server/db/schema"
import { encodeUser } from "@in/server/realtime/encoders/encodeUser"

const baseUser: DbUser = {
  id: 100,
  email: null,
  phoneNumber: null,
  emailVerified: null,
  phoneVerified: null,
  firstName: null,
  lastName: null,
  bio: null,
  username: null,
  deleted: null,
  online: false,
  lastOnline: null,
  date: new Date("2025-01-01T00:00:00Z"),
  photoFileId: null,
  pendingSetup: null,
  timeZone: null,
  bot: null,
  botCreatorId: null,
  updateSeq: null,
  lastUpdateDate: null,
}

const buildUser = (overrides: Partial<DbUser> = {}): DbUser => ({
  ...baseUser,
  ...overrides,
})

describe("encodeUser", () => {
  it("marks ChatGPT as verified by username", () => {
    const user = encodeUser({ user: buildUser({ username: "ChatGPT", bot: true }) })

    expect(user.verified).toBe(true)
  })

  it("omits verified for non-verified users", () => {
    const user = encodeUser({ user: buildUser({ username: "linear", bot: true }) })

    expect(user.verified).toBeUndefined()
  })
})
