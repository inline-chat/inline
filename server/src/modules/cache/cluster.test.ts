import { describe, expect, it, spyOn } from "bun:test"
import { connectionManager } from "@in/server/ws/connections"
import { refreshSpaceMemberships } from "./cluster"

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
