import { describe, test, expect, beforeAll, afterAll } from "bun:test"
import { setupTestDatabase, teardownTestDatabase, testUtils } from "./setup"
import { getUserSettingsHandler } from "@in/server/realtime/handlers/user.getUserSettings"
import { updateUserSettingsHandler } from "@in/server/realtime/handlers/user.updateUserSettings"
import { UserSettingsNotificationsMode } from "@in/server/db/models/userSettings/types"
import { UserSettingsModel } from "@in/server/db/models/userSettings/userSettings"
import { NotificationSettings_Mode } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { users } from "@in/server/db/schema"
import { UpdateBucket, updates } from "@in/server/db/schema/updates"
import { Sync } from "@in/server/modules/updates/sync"
import { eq } from "drizzle-orm"
import { clearUserSettingsCache } from "@in/server/modules/cache/userSettings"

describe("User Settings RPC", () => {
  let userId: number

  beforeAll(async () => {
    await setupTestDatabase()
    const user = await testUtils.createUser()
    userId = user!.id
  })

  afterAll(async () => {
    await teardownTestDatabase()
  })

  test("getUserSettings should return null for new user", async () => {
    const context = {
      userId,
      sessionId: 1,
      connectionId: "test",
      sendRaw: () => {},
      sendRpcReply: () => {},
    }

    const result = await getUserSettingsHandler({}, context)

    expect(result.userSettings).toBeDefined()
    expect(result.userSettings?.notificationSettings).toBeUndefined()
    expect(result.userSettings?.privacySettings?.shareTimeZone).toBe(true)
    expect(result.userSettings?.privacySettings?.appearInGlobalSearch).toBe(true)
    expect(result.userSettings?.composeSettings?.replacePastedLinksWithTitles).toBe(false)
  })

  test("updates compose settings without changing other settings", async () => {
    const context = {
      userId,
      sessionId: 1,
      connectionId: "test",
      sendRaw: () => {},
      sendRpcReply: () => {},
    }

    await updateUserSettingsHandler(
      {
        userSettings: {
          composeSettings: {
            replacePastedLinksWithTitles: true,
          },
        },
      },
      context,
    )

    const result = await getUserSettingsHandler({}, context)
    expect(result.userSettings?.composeSettings?.replacePastedLinksWithTitles).toBe(true)
    expect(result.userSettings?.privacySettings?.shareTimeZone).toBe(true)
  })

  test("updates privacy settings and their user-row projections", async () => {
    const context = {
      userId,
      sessionId: 1,
      connectionId: "test",
      sendRaw: () => {},
      sendRpcReply: () => {},
    }

    await updateUserSettingsHandler(
      {
        userSettings: {
          privacySettings: {
            shareTimeZone: false,
            appearInGlobalSearch: false,
          },
        },
      },
      context,
    )

    const result = await getUserSettingsHandler({}, context)
    expect(result.userSettings?.privacySettings?.shareTimeZone).toBe(false)
    expect(result.userSettings?.privacySettings?.appearInGlobalSearch).toBe(false)

    const [user] = await db
      .select({
        shareTimeZone: users.shareTimeZone,
        appearInGlobalSearch: users.appearInGlobalSearch,
      })
      .from(users)
      .where(eq(users.id, userId))
      .limit(1)
    expect(user).toEqual({ shareTimeZone: false, appearInGlobalSearch: false })
  })

  test("merges concurrent partial updates instead of losing a field", async () => {
    await UserSettingsModel.updateGeneral(userId, {
      notifications: { mode: UserSettingsNotificationsMode.All, silent: false, disableDmNotifications: false },
      privacy: { shareTimeZone: true, appearInGlobalSearch: true },
      compose: { replacePastedLinksWithTitles: false },
    })
    clearUserSettingsCache()

    const makeContext = (sessionId: number) => ({
      userId,
      sessionId,
      connectionId: `settings-race-${sessionId}`,
      sendRaw: () => {},
      sendRpcReply: () => {},
    })

    await Promise.all([
      updateUserSettingsHandler(
        { userSettings: { composeSettings: { replacePastedLinksWithTitles: true } } },
        makeContext(11),
      ),
      updateUserSettingsHandler(
        { userSettings: { privacySettings: { shareTimeZone: false } } },
        makeContext(12),
      ),
    ])

    const stored = await UserSettingsModel.getGeneral(userId)
    expect(stored?.compose.replacePastedLinksWithTitles).toBe(true)
    expect(stored?.privacy.shareTimeZone).toBe(false)
    expect(stored?.privacy.appearInGlobalSearch).toBe(true)
  })

  test("sequences concurrent full-payload projections in the user bucket", async () => {
    await UserSettingsModel.updateGeneral(userId, {
      notifications: { mode: UserSettingsNotificationsMode.All, silent: false, disableDmNotifications: false },
      privacy: { shareTimeZone: true, appearInGlobalSearch: true },
      compose: { replacePastedLinksWithTitles: false },
    })
    clearUserSettingsCache()

    const makeContext = (sessionId: number) => ({
      userId,
      sessionId,
      connectionId: `settings-projection-${sessionId}`,
      sendRaw: () => {},
      sendRpcReply: () => {},
    })

    const results = await Promise.all([
      updateUserSettingsHandler(
        { userSettings: { composeSettings: { replacePastedLinksWithTitles: true } } },
        makeContext(21),
      ),
      updateUserSettingsHandler(
        { userSettings: { privacySettings: { shareTimeZone: false } } },
        makeContext(22),
      ),
    ])

    const projected = results.flatMap((result) => result.updates)
    expect(projected).toHaveLength(2)
    expect(projected.every((update) => update.seq !== undefined && update.seq > 0)).toBe(true)
    const sequences = projected.map((update) => update.seq!).sort((a, b) => a - b)
    expect(sequences[1]).toBe(sequences[0]! + 1)
    expect(projected.every((update) => update.date !== undefined && update.date > 0n)).toBe(true)

    const durableRows = (await db.select().from(updates).where(eq(updates.entityId, userId))).filter(
      (row) => row.bucket === UpdateBucket.User && sequences.includes(row.seq),
    )
    const durableProjection = Sync.inflateUserUpdates(durableRows)
    expect(durableProjection.map((update) => update.seq).sort((a, b) => a! - b!)).toEqual(sequences)
    expect(durableProjection.every((update) => update.update.oneofKind === "updateUserSettings")).toBe(true)
  })

  test("updateUserSettings should save and return settings", async () => {
    const context = {
      userId,
      sessionId: 1,
      connectionId: "test",
      sendRaw: () => {},
      sendRpcReply: () => {},
    }

    const updateInput = {
      userSettings: {
        notificationSettings: {
          mode: NotificationSettings_Mode.MENTIONS,
          silent: true,
        },
      },
    }

    const updateResult = await updateUserSettingsHandler(updateInput, context)

    expect(updateResult.updates).toHaveLength(1)
    expect(updateResult.updates[0]?.update.oneofKind).toBe("updateUserSettings")

    // Now get the settings and verify they were saved
    const getResult = await getUserSettingsHandler({}, context)

    expect(getResult.userSettings?.notificationSettings?.mode).toBe(NotificationSettings_Mode.MENTIONS)
    expect(getResult.userSettings?.notificationSettings?.silent).toBe(true)
  })

  test("updateUserSettings should map legacy disable DM to only-mentions", async () => {
    const context = {
      userId,
      sessionId: 1,
      connectionId: "test",
      sendRaw: () => {},
      sendRpcReply: () => {},
    }

    const updateInput = {
      userSettings: {
        notificationSettings: {
          mode: NotificationSettings_Mode.MENTIONS,
          disableDmNotifications: true,
        },
      },
    }

    await updateUserSettingsHandler(updateInput, context)

    const stored = await UserSettingsModel.getGeneral(userId)
    expect(stored?.notifications.mode).toBe(UserSettingsNotificationsMode.OnlyMentions)
    expect(stored?.notifications.disableDmNotifications).toBe(true)

    const getResult = await getUserSettingsHandler({}, context)
    expect(getResult.userSettings?.notificationSettings?.mode).toBe(NotificationSettings_Mode.MENTIONS)
    expect(getResult.userSettings?.notificationSettings?.disableDmNotifications).toBe(true)
  })

  test("updateUserSettings should accept only-mentions mode and downlevel on read", async () => {
    const context = {
      userId,
      sessionId: 1,
      connectionId: "test",
      sendRaw: () => {},
      sendRpcReply: () => {},
    }

    const updateInput = {
      userSettings: {
        notificationSettings: {
          mode: NotificationSettings_Mode.ONLY_MENTIONS,
        },
      },
    }

    await updateUserSettingsHandler(updateInput, context)

    const stored = await UserSettingsModel.getGeneral(userId)
    expect(stored?.notifications.mode).toBe(UserSettingsNotificationsMode.OnlyMentions)
    expect(stored?.notifications.disableDmNotifications).toBe(true)

    const getResult = await getUserSettingsHandler({}, context)
    expect(getResult.userSettings?.notificationSettings?.mode).toBe(NotificationSettings_Mode.MENTIONS)
    expect(getResult.userSettings?.notificationSettings?.disableDmNotifications).toBe(true)
  })

  test("updateUserSettings should map legacy important-only to mentions", async () => {
    const context = {
      userId,
      sessionId: 1,
      connectionId: "test",
      sendRaw: () => {},
      sendRpcReply: () => {},
    }

    const updateInput = {
      userSettings: {
        notificationSettings: {
          mode: NotificationSettings_Mode.IMPORTANT_ONLY,
          disableDmNotifications: true,
        },
      },
    }

    await updateUserSettingsHandler(updateInput, context)

    const stored = await UserSettingsModel.getGeneral(userId)
    expect(stored?.notifications.mode).toBe(UserSettingsNotificationsMode.Mentions)
    expect(stored?.notifications.disableDmNotifications).toBe(false)

    const getResult = await getUserSettingsHandler({}, context)
    expect(getResult.userSettings?.notificationSettings?.mode).toBe(NotificationSettings_Mode.MENTIONS)
    expect(getResult.userSettings?.notificationSettings?.disableDmNotifications).toBe(false)
  })
})
