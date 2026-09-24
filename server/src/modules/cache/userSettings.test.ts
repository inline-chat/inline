import { afterEach, beforeEach, describe, expect, spyOn, test } from "bun:test"
import {
  UserSettingsNotificationsMode,
  type UserSettingsGeneral,
} from "@in/server/db/models/userSettings/types"
import { UserSettingsModel } from "@in/server/db/models/userSettings"
import {
  clearUserSettingsCache,
  getCachedUserSettings,
  getUserSettingsCacheStats,
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
    let calls = 0
    const getGeneral = spyOn(UserSettingsModel, "getGeneral").mockImplementation(async () => {
      if (++calls === 1) {
        resolveStarted()
        return await fetch
      }
      return freshSettings
    })

    try {
      const inFlight = getCachedUserSettings(userId)
      await started

      invalidateUserSettingsCache(userId)
      resolveFetch(staleSettings)
      await expect(inFlight).resolves.toEqual(freshSettings)
      await expect(getCachedUserSettings(userId)).resolves.toEqual(freshSettings)
      expect(getGeneral).toHaveBeenCalledTimes(2)
    } finally {
      getGeneral.mockRestore()
    }
  })

  test("returns a newer fresh fill when an invalidated older fill fails", async () => {
    const userId = 90406
    const oldFetchStarted = Promise.withResolvers<void>()
    const releaseOldFetch = Promise.withResolvers<void>()
    let calls = 0
    const getGeneral = spyOn(UserSettingsModel, "getGeneral").mockImplementation(async () => {
      if (++calls === 1) {
        oldFetchStarted.resolve()
        await releaseOldFetch.promise
        throw new Error("old database request failed")
      }
      return freshSettings
    })

    try {
      const oldFill = getCachedUserSettings(userId)
      await oldFetchStarted.promise

      invalidateUserSettingsCache(userId)
      await expect(getCachedUserSettings(userId)).resolves.toEqual(freshSettings)

      releaseOldFetch.resolve()
      await expect(oldFill).resolves.toEqual(freshSettings)
      expect(getGeneral).toHaveBeenCalledTimes(2)
    } finally {
      releaseOldFetch.resolve()
      getGeneral.mockRestore()
    }
  })

  test("uses a whole-cache epoch fence when distinct invalidations reach their metadata bound", async () => {
    const userId = 90405
    const fetchStarted = Promise.withResolvers<void>()
    const releaseOldFetch = Promise.withResolvers<UserSettingsGeneral>()
    let calls = 0
    const getGeneral = spyOn(UserSettingsModel, "getGeneral").mockImplementation(async () => {
      if (++calls === 1) {
        fetchStarted.resolve()
        return await releaseOldFetch.promise
      }
      return freshSettings
    })

    try {
      const inFlight = getCachedUserSettings(userId)
      await fetchStarted.promise

      // maxSize is 10,000 and invalidation generations retain at most 20,000
      // entries. The next distinct invalidation must fence the pending fill.
      for (let invalidatedUserId = 200_000; invalidatedUserId <= 220_000; invalidatedUserId++) {
        invalidateUserSettingsCache(invalidatedUserId)
      }
      releaseOldFetch.resolve(staleSettings)

      await expect(inFlight).resolves.toEqual(freshSettings)
      await expect(getCachedUserSettings(userId)).resolves.toEqual(freshSettings)
      expect(getGeneral).toHaveBeenCalledTimes(2)
    } finally {
      releaseOldFetch.resolve(staleSettings)
      getGeneral.mockRestore()
    }
  })

  test("stays within its capacity when all fills share one timestamp", async () => {
    const now = 1_000_000
    const dateNow = spyOn(Date, "now").mockImplementation(() => now)
    const getGeneral = spyOn(UserSettingsModel, "getGeneral").mockResolvedValue(staleSettings)

    try {
      for (let userId = 300_000; userId <= 310_000; userId++) {
        await getCachedUserSettings(userId)
      }

      expect(getUserSettingsCacheStats().size).toBe(10_000)
    } finally {
      getGeneral.mockRestore()
      dateNow.mockRestore()
    }
  })

  test("keeps a user's fresh settings for 30 seconds and awaits its next fill", async () => {
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
      now += 29 * 1000
      await expect(getCachedUserSettings(userB)).resolves.toEqual(staleSettings)
      expect(getGeneral).toHaveBeenCalledTimes(1)

      now += 2 * 1000
      const inFlight = getCachedUserSettings(userB)
      await refreshStarted

      invalidateUserSettingsCache(userA)
      resolveRefresh(freshSettings)
      await expect(inFlight).resolves.toEqual(freshSettings)

      await expect(getCachedUserSettings(userB)).resolves.toEqual(freshSettings)
      expect(getGeneral).toHaveBeenCalledTimes(2)
    } finally {
      getGeneral.mockRestore()
      dateNow.mockRestore()
    }
  })

  test("does not serve an expired settings value when its fresh fill fails", async () => {
    const userId = 90404
    let now = 1_000_000
    const dateNow = spyOn(Date, "now").mockImplementation(() => now)
    const getGeneral = spyOn(UserSettingsModel, "getGeneral")
      .mockResolvedValueOnce(staleSettings)
      .mockRejectedValueOnce(new Error("database unavailable"))

    try {
      await expect(getCachedUserSettings(userId)).resolves.toEqual(staleSettings)
      now += 30 * 1000
      await expect(getCachedUserSettings(userId)).rejects.toThrow("database unavailable")
    } finally {
      getGeneral.mockRestore()
      dateNow.mockRestore()
    }
  })
})
