import { describe, expect, it, spyOn } from "bun:test"
import { UserSettingsModel } from "@in/server/db/models/userSettings"
import { UserSettingsGeneralSchema } from "@in/server/db/models/userSettings/types"
import { internalMessaging } from "@in/server/modules/internalMessaging/service"
import { connectionManager } from "@in/server/ws/connections"
import { clearClusterCaches, refreshSpaceMemberships, subscribeClusterCaches } from "./cluster"
import { getCachedUserSettings } from "./userSettings"

describe("refreshSpaceMemberships", () => {
  it("keeps one AccessChanged event at sixteen membership refreshes", async () => {
    let active = 0
    let maximumActive = 0
    const refresh = spyOn(connectionManager, "refreshSpaceMembership").mockImplementation(async () => {
      active += 1
      maximumActive = Math.max(maximumActive, active)
      await Promise.resolve()
      active -= 1
    })

    try {
      await refreshSpaceMemberships(Array.from({ length: 33 }, (_, index) => index + 1), 42)
      expect(refresh).toHaveBeenCalledTimes(33)
      expect(maximumActive).toBe(16)
    } finally {
      refresh.mockRestore()
    }
  })
})

describe("cluster cache recovery", () => {
  for (const inFlight of [false, true]) {
    it(`refreshes a ${inFlight ? "pending" : "completed"} outage refill after broker recovery`, async () => {
      const readyListeners = new Set<() => void>()
      const continuityListeners = new Set<() => void>()
      const ready = spyOn(internalMessaging, "onReady").mockImplementation((listener) => {
        readyListeners.add(listener)
        return () => { readyListeners.delete(listener) }
      })
      const continuity = spyOn(internalMessaging, "onContinuityLost").mockImplementation((listener) => {
        continuityListeners.add(listener)
        return () => { continuityListeners.delete(listener) }
      })
      const before = UserSettingsGeneralSchema.parse({ privacy: { shareTimeZone: true } })
      const after = UserSettingsGeneralSchema.parse({ privacy: { shareTimeZone: false } })
      const refillStarted = Promise.withResolvers<void>()
      const releaseRefill = Promise.withResolvers<typeof before>()
      let current = before
      let reads = 0
      const getGeneral = spyOn(UserSettingsModel, "getGeneral").mockImplementation(async () => {
        if (++reads === 2 && inFlight) {
          refillStarted.resolve()
          return releaseRefill.promise
        }
        return current
      })
      clearClusterCaches()
      const unsubscribe = subscribeClusterCaches()
      try {
        const userId = 90420
        await expect(getCachedUserSettings(userId)).resolves.toEqual(before)

        // The lost connection clears the old value, but reads during the gap
        // can refill it before a remote mutation's invalidation is missed.
        for (const listener of continuityListeners) listener()
        const refill = getCachedUserSettings(userId)
        if (inFlight) await refillStarted.promise
        else await expect(refill).resolves.toEqual(before)
        current = after
        if (!inFlight) {
          await expect(getCachedUserSettings(userId)).resolves.toEqual(before)
        }

        for (const listener of readyListeners) listener()
        releaseRefill.resolve(before)
        if (inFlight) await expect(refill).resolves.toEqual(after)
        await expect(getCachedUserSettings(userId)).resolves.toEqual(after)
        await expect(getCachedUserSettings(userId)).resolves.toEqual(after)
        expect(getGeneral).toHaveBeenCalledTimes(3)

        unsubscribe()
        expect(readyListeners.size).toBe(0)
        expect(continuityListeners.size).toBe(0)
      } finally {
        releaseRefill.resolve(before)
        unsubscribe()
        ready.mockRestore()
        continuity.mockRestore()
        getGeneral.mockRestore()
        clearClusterCaches()
      }
    })
  }
})
