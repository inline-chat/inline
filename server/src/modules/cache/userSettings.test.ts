import { afterEach, beforeEach, describe, expect, spyOn, test } from "bun:test"
import {
  UserSettingsNotificationsMode,
  type UserSettingsGeneral,
} from "@in/server/db/models/userSettings/types"
import { UserSettingsModel } from "@in/server/db/models/userSettings"
import {
  clearUserSettingsCache,
  getCachedUserSettings,
  invalidateUserSettingsCache,
} from "@in/server/modules/cache/userSettings"

const staleSettings: UserSettingsGeneral = {
  notifications: { mode: UserSettingsNotificationsMode.All, silent: false, disableDmNotifications: false },
  privacy: { shareTimeZone: true, appearInGlobalSearch: true },
  compose: { replacePastedLinksWithTitles: false },
}

const freshSettings: UserSettingsGeneral = {
  ...staleSettings,
  privacy: { ...staleSettings.privacy, shareTimeZone: false },
}

describe("User Settings Cache", () => {
  beforeEach(() => {
    clearUserSettingsCache()
  })

  afterEach(() => {
    clearUserSettingsCache()
  })

  test("does not install a fill that started before invalidation", async () => {
    const userId = 90401
    let resolveStarted!: () => void
    const started = new Promise<void>((resolve) => {
      resolveStarted = resolve
    })
    let resolveFetch!: (settings: UserSettingsGeneral) => void
    const fetch = new Promise<UserSettingsGeneral>((resolve) => {
      resolveFetch = resolve
    })
    const getGeneral = spyOn(UserSettingsModel, "getGeneral").mockImplementation(async () => {
      resolveStarted()
      return await fetch
    })

    try {
      const inFlight = getCachedUserSettings(userId)
      await started

      invalidateUserSettingsCache(userId)
      resolveFetch(staleSettings)
      await expect(inFlight).resolves.toEqual(staleSettings)

      getGeneral.mockImplementation(async () => freshSettings)
      await expect(getCachedUserSettings(userId)).resolves.toEqual(freshSettings)
      expect(getGeneral).toHaveBeenCalledTimes(2)
    } finally {
      getGeneral.mockRestore()
    }
  })

  test("an unrelated invalidation does not discard another user's background refresh", async () => {
    const userA = 90402
    const userB = 90403
    let now = 1_000_000
    const dateNow = spyOn(Date, "now").mockImplementation(() => now)
    let resolveRefreshStarted!: () => void
    const refreshStarted = new Promise<void>((resolve) => { resolveRefreshStarted = resolve })
    let resolveRefresh!: (settings: UserSettingsGeneral) => void
    const refresh = new Promise<UserSettingsGeneral>((resolve) => { resolveRefresh = resolve })
    let fetches = 0
    const getGeneral = spyOn(UserSettingsModel, "getGeneral").mockImplementation(async (userId) => {
      expect(userId).toBe(userB)
      fetches += 1
      if (fetches === 1) return staleSettings
      resolveRefreshStarted()
      return await refresh
    })

    try {
      await expect(getCachedUserSettings(userB)).resolves.toEqual(staleSettings)
      now += 61 * 60 * 1000
      await expect(getCachedUserSettings(userB)).resolves.toEqual(staleSettings)
      await refreshStarted

      invalidateUserSettingsCache(userA)
      resolveRefresh(freshSettings)
      for (let attempt = 0; attempt < 20 && fetches < 2; attempt += 1) await Bun.sleep(1)
      await Bun.sleep(1)

      await expect(getCachedUserSettings(userB)).resolves.toEqual(freshSettings)
      expect(getGeneral).toHaveBeenCalledTimes(2)
    } finally {
      getGeneral.mockRestore()
      dateNow.mockRestore()
    }
  })
})
