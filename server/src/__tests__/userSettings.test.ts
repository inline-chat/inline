import { describe, test, expect, beforeAll, afterAll } from "bun:test"
import { setupTestDatabase, teardownTestDatabase, testUtils } from "./setup"
import { getUserSettingsHandler } from "@in/server/realtime/handlers/user.getUserSettings"
import { updateUserSettingsHandler } from "@in/server/realtime/handlers/user.updateUserSettings"
import { UserSettingsNotificationsMode } from "@in/server/db/models/userSettings/types"
import { UserSettingsModel } from "@in/server/db/models/userSettings/userSettings"
import { NotificationSettings_Mode } from "@in/protocol/core"

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
          importantOnly: false,
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
})
