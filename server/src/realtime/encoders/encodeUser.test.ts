import { describe, expect, test } from "bun:test"
import type { DbUser } from "@in/server/db/schema"
import { encodeUser } from "@in/server/realtime/encoders/encodeUser"

const user: DbUser = {
  id: 100,
  email: null,
  phoneNumber: null,
  emailVerified: null,
  phoneVerified: null,
  firstName: "Privacy",
  lastName: "Tester",
  bio: null,
  username: "privacy-tester",
  deleted: null,
  online: false,
  lastOnline: null,
  date: new Date("2026-08-14T00:00:00Z"),
  photoFileId: null,
  pendingSetup: false,
  timeZone: "Asia/Tehran",
  shareTimeZone: false,
  appearInGlobalSearch: true,
  nextThreadNumber: 1,
  bot: false,
  botCreatorId: null,
  updateSeq: 0,
  lastUpdateDate: null,
}

describe("encodeUser time-zone privacy", () => {
  test("redacts a hidden time zone from peers", () => {
    expect(encodeUser({ user, viewerUserId: 200 }).timeZone).toBeUndefined()
  })

  test("keeps a hidden time zone visible to its owner", () => {
    expect(encodeUser({ user, viewerUserId: user.id }).timeZone).toBe("Asia/Tehran")
  })

  test("shares the time zone when enabled", () => {
    expect(encodeUser({ user: { ...user, shareTimeZone: true }, viewerUserId: 200 }).timeZone).toBe("Asia/Tehran")
  })

  test("includes a shared time zone in an explicitly authorized min projection", () => {
    expect(
      encodeUser({
        user: { ...user, shareTimeZone: true },
        min: true,
        includeTimeZone: true,
        viewerUserId: 200,
      }).timeZone,
    ).toBe("Asia/Tehran")
  })

  test("keeps ordinary and hidden min projections redacted", () => {
    expect(encodeUser({ user: { ...user, shareTimeZone: true }, min: true, viewerUserId: 200 }).timeZone).toBeUndefined()
    expect(encodeUser({ user, min: true, includeTimeZone: true, viewerUserId: 200 }).timeZone).toBeUndefined()
  })
})
