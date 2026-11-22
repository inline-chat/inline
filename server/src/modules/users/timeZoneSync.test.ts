import { describe, expect, test } from "bun:test"
import { db } from "@in/server/db"
import { sessions, users } from "@in/server/db/schema"
import { syncTimeZoneForElectedAppleSession } from "@in/server/modules/users/timeZoneSync"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { eq } from "drizzle-orm"
import { SessionsModel } from "@in/server/db/models/sessions"
import { UserSettingsModel } from "@in/server/db/models/userSettings"
import { encodeUserSettings } from "@in/server/realtime/encoders/encodeUserSettings"
import { decodeUserSettings } from "@in/server/realtime/decoders/decodeUserSettings"

describe("time-zone writer election", () => {
  setupTestLifecycle()

  test("only the newest non-revoked Apple session writes", async () => {
    const user = await testUtils.createUser("timezone-election@example.com")
    const oldSession = await testUtils.createSessionForUser(user.id, { clientType: "ios" })
    const webSession = await testUtils.createSessionForUser(user.id, { clientType: "web" })
    const newSession = await testUtils.createSessionForUser(user.id, { clientType: "macos" })

    expect(
      await syncTimeZoneForElectedAppleSession({
        userId: user.id,
        sessionId: oldSession.session.id,
        timeZone: "America/Toronto",
      }),
    ).toBeUndefined()
    expect(
      await syncTimeZoneForElectedAppleSession({
        userId: user.id,
        sessionId: webSession.session.id,
        timeZone: "Europe/London",
      }),
    ).toBeUndefined()

    const updated = await syncTimeZoneForElectedAppleSession({
      userId: user.id,
      sessionId: newSession.session.id,
      timeZone: "Asia/Tehran",
    })
    expect(updated?.timeZone).toBe("Asia/Tehran")

    const [storedUser] = await db.select().from(users).where(eq(users.id, user.id))
    expect(storedUser?.timeZone).toBe("Asia/Tehran")

    await db.update(sessions).set({ revoked: new Date() }).where(eq(sessions.id, newSession.session.id))
    const fallbackUpdate = await syncTimeZoneForElectedAppleSession({
      userId: user.id,
      sessionId: oldSession.session.id,
      timeZone: "America/Toronto",
    })
    expect(fallbackUpdate?.timeZone).toBe("America/Toronto")
  })
})

describe("manual time zone", () => {
  setupTestLifecycle()

  test("pins the time zone over device syncs and restores the device's on automatic", async () => {
    const user = await testUtils.createUser("timezone-manual@example.com")
    const { session } = await testUtils.createSessionForUser(user.id, { clientType: "macos" })
    const storedTimeZone = async () => (await db.select().from(users).where(eq(users.id, user.id)))[0]?.timeZone

    await SessionsModel.updateMetadata(session.id, user.id, { timezone: "America/Toronto" })
    await syncTimeZoneForElectedAppleSession({ userId: user.id, sessionId: session.id, timeZone: "America/Toronto" })
    expect(await storedTimeZone()).toBe("America/Toronto")

    await UserSettingsModel.updateGeneralWithPatch(user.id, { privacy: { manualTimeZone: "Asia/Tokyo" } })
    expect(await storedTimeZone()).toBe("Asia/Tokyo")

    // The device moves while the manual choice holds.
    await SessionsModel.updateMetadata(session.id, user.id, { timezone: "Europe/Berlin" })
    expect(
      await syncTimeZoneForElectedAppleSession({ userId: user.id, sessionId: session.id, timeZone: "Europe/Berlin" }),
    ).toBeUndefined()
    expect(await storedTimeZone()).toBe("Asia/Tokyo")

    // Saves that omit the field keep the choice.
    await UserSettingsModel.updateGeneralWithPatch(user.id, { privacy: { appearInGlobalSearch: false } })
    expect((await UserSettingsModel.getGeneral(user.id))?.privacy.manualTimeZone).toBe("Asia/Tokyo")

    await UserSettingsModel.updateGeneralWithPatch(user.id, { privacy: { manualTimeZone: "" } })
    expect((await UserSettingsModel.getGeneral(user.id))?.privacy.manualTimeZone).toBeUndefined()
    expect(await storedTimeZone()).toBe("Europe/Berlin")
  })

  test("settings encode automatic as an empty time zone and reject unknown ones", () => {
    expect(encodeUserSettings({ general: null }).privacySettings?.manualTimeZone).toBe("")
    expect(() =>
      decodeUserSettings({ privacySettings: { manualTimeZone: "Mars/Olympus" } }),
    ).toThrow()
    expect(decodeUserSettings({ privacySettings: { manualTimeZone: "" } })?.privacy?.manualTimeZone).toBe("")
  })
})
