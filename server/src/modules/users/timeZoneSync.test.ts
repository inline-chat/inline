import { describe, expect, test } from "bun:test"
import { db } from "@in/server/db"
import { sessions, users } from "@in/server/db/schema"
import { recomputeUserTimeZone } from "@in/server/modules/users/timeZoneSync"
import { revokeSession } from "@in/server/modules/sessions/revokeSession"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { eq } from "drizzle-orm"
import { SessionsModel } from "@in/server/db/models/sessions"
import { UserSettingsModel } from "@in/server/db/models/userSettings"
import { encodeUserSettings } from "@in/server/realtime/encoders/encodeUserSettings"
import { decodeUserSettings } from "@in/server/realtime/decoders/decodeUserSettings"

type ClientType = "ios" | "macos" | "web"

const daysAgo = (days: number) => new Date(Date.now() - days * 24 * 60 * 60 * 1000)

/** A session that signed in `signedInDaysAgo` with `timeZone` and was last seen `activeDaysAgo`. */
const device = async (
  userId: number,
  clientType: ClientType,
  timeZone: string,
  { signedInDaysAgo, activeDaysAgo = 0 }: { signedInDaysAgo: number; activeDaysAgo?: number },
) => {
  const session = await SessionsModel.create({
    userId,
    tokenHash: crypto.randomUUID(),
    personalData: { timezone: timeZone },
    clientType,
  })
  await db
    .update(sessions)
    .set({ date: daysAgo(signedInDaysAgo), lastActive: daysAgo(activeDaysAgo) })
    .where(eq(sessions.id, session.id))
  return session.id
}

/** What updateSession does for a device's time zone. */
const report = async (userId: number, sessionId: number, timeZone: string) => {
  await SessionsModel.updateMetadata(sessionId, userId, { timezone: timeZone })
  return recomputeUserTimeZone(userId, { reportingSessionId: sessionId })
}

const storedTimeZone = async (userId: number) =>
  (await db.select().from(users).where(eq(users.id, userId)))[0]?.timeZone

const setTimeZone = (userId: number, timeZone: string) =>
  db.update(users).set({ timeZone }).where(eq(users.id, userId))

describe("device time zone", () => {
  setupTestLifecycle()

  test("an abandoned newest install cannot hold the time zone", async () => {
    // Production shape from 2026-11-25: the newest Apple session went idle in May, while the
    // phone and Mac that moved to Taipei were dropped because they were not the newest.
    const user = await testUtils.createUser("timezone-abandoned@example.com")
    const phone = await device(user.id, "ios", "Asia/Taipei", { signedInDaysAgo: 430 })
    await device(user.id, "macos", "Asia/Taipei", { signedInDaysAgo: 560 })
    await device(user.id, "ios", "America/Vancouver", { signedInDaysAgo: 210, activeDaysAgo: 197 })
    await setTimeZone(user.id, "America/Vancouver")

    // An unchanged launch report heals it, with no backfill.
    const updated = await report(user.id, phone, "Asia/Taipei")
    expect(updated?.timeZone).toBe("Asia/Taipei")
    expect(await storedTimeZone(user.id)).toBe("Asia/Taipei")
  })

  test("a device that moves takes the time zone, and a stationary one cannot flip it back", async () => {
    const user = await testUtils.createUser("timezone-travel@example.com")
    const phone = await device(user.id, "ios", "America/Vancouver", { signedInDaysAgo: 90 })
    const desk = await device(user.id, "macos", "America/Vancouver", { signedInDaysAgo: 5 })
    await setTimeZone(user.id, "America/Vancouver")

    await report(user.id, phone, "Asia/Taipei")
    expect(await storedTimeZone(user.id)).toBe("Asia/Taipei")

    // The desk machine left at home relaunches and reports what it always had.
    expect(await report(user.id, desk, "America/Vancouver")).toBeUndefined()
    expect(await storedTimeZone(user.id)).toBe("Asia/Taipei")

    await report(user.id, phone, "America/Vancouver")
    expect(await storedTimeZone(user.id)).toBe("America/Vancouver")
  })

  test("a new sign-in counts as the device's report", async () => {
    const user = await testUtils.createUser("timezone-signin@example.com")
    await device(user.id, "macos", "America/Vancouver", { signedInDaysAgo: 30 })
    await setTimeZone(user.id, "America/Vancouver")

    const ipad = await device(user.id, "ios", "Asia/Taipei", { signedInDaysAgo: 0 })
    await recomputeUserTimeZone(user.id, { reportingSessionId: ipad })
    expect(await storedTimeZone(user.id)).toBe("Asia/Taipei")
  })

  test("a long-idle device that comes back and moves still counts", async () => {
    const user = await testUtils.createUser("timezone-returning@example.com")
    const laptop = await device(user.id, "macos", "Europe/Berlin", { signedInDaysAgo: 200, activeDaysAgo: 45 })
    await device(user.id, "ios", "Europe/Berlin", { signedInDaysAgo: 100 })
    await setTimeZone(user.id, "Europe/Berlin")

    await report(user.id, laptop, "Asia/Tokyo")
    expect(await storedTimeZone(user.id)).toBe("Asia/Tokyo")
  })

  test("signing out the device that set it falls back to another live device", async () => {
    const user = await testUtils.createUser("timezone-signout@example.com")
    await device(user.id, "macos", "America/Vancouver", { signedInDaysAgo: 40 })
    const phone = await device(user.id, "ios", "America/Vancouver", { signedInDaysAgo: 90 })
    await report(user.id, phone, "Asia/Taipei")
    expect(await storedTimeZone(user.id)).toBe("Asia/Taipei")

    await revokeSession({ actor: "user", actorUserId: user.id, targetUserId: user.id, sessionId: phone })
    expect(await storedTimeZone(user.id)).toBe("America/Vancouver")
  })

  test("web and revoked sessions never set it, and no live device leaves it alone", async () => {
    const user = await testUtils.createUser("timezone-ignored@example.com")
    const web = await device(user.id, "web", "Europe/London", { signedInDaysAgo: 0 })
    const revoked = await device(user.id, "ios", "Asia/Tehran", { signedInDaysAgo: 0 })
    await device(user.id, "macos", "Asia/Dubai", { signedInDaysAgo: 300, activeDaysAgo: 120 })
    await setTimeZone(user.id, "America/Toronto")
    await db.update(sessions).set({ revoked: new Date() }).where(eq(sessions.id, revoked))

    expect(await report(user.id, web, "Europe/Paris")).toBeUndefined()
    expect(await recomputeUserTimeZone(user.id)).toBeUndefined()
    expect(await storedTimeZone(user.id)).toBe("America/Toronto")
  })
})

describe("manual time zone", () => {
  setupTestLifecycle()

  test("pins the time zone over device reports and restores the device's on automatic", async () => {
    const user = await testUtils.createUser("timezone-manual@example.com")
    const mac = await device(user.id, "macos", "America/Toronto", { signedInDaysAgo: 10 })
    // An abandoned install must not be what automatic restores.
    await device(user.id, "ios", "America/Vancouver", { signedInDaysAgo: 5, activeDaysAgo: 60 })

    await report(user.id, mac, "America/Toronto")
    expect(await storedTimeZone(user.id)).toBe("America/Toronto")

    await UserSettingsModel.updateGeneralWithPatch(user.id, { privacy: { manualTimeZone: "Asia/Tokyo" } })
    expect(await storedTimeZone(user.id)).toBe("Asia/Tokyo")

    // The device moves while the manual choice holds.
    expect(await report(user.id, mac, "Europe/Berlin")).toBeUndefined()
    expect(await storedTimeZone(user.id)).toBe("Asia/Tokyo")

    // Saves that omit the field keep the choice.
    await UserSettingsModel.updateGeneralWithPatch(user.id, { privacy: { appearInGlobalSearch: false } })
    expect((await UserSettingsModel.getGeneral(user.id))?.privacy.manualTimeZone).toBe("Asia/Tokyo")

    await UserSettingsModel.updateGeneralWithPatch(user.id, { privacy: { manualTimeZone: "" } })
    expect((await UserSettingsModel.getGeneral(user.id))?.privacy.manualTimeZone).toBeUndefined()
    expect(await storedTimeZone(user.id)).toBe("Europe/Berlin")
  })

  test("settings encode automatic as an empty time zone and reject unknown ones", () => {
    expect(encodeUserSettings({ general: null }).privacySettings?.manualTimeZone).toBe("")
    expect(() =>
      decodeUserSettings({ privacySettings: { manualTimeZone: "Mars/Olympus" } }),
    ).toThrow()
    expect(decodeUserSettings({ privacySettings: { manualTimeZone: "" } })?.privacy?.manualTimeZone).toBe("")
  })
})
