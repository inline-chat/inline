import { describe, expect, it, spyOn } from "bun:test"
import { connectionDirectory } from "@in/server/modules/internalMessaging/directory"
import { PresenceManager } from "./presence"
import type { SessionActivityTracker } from "./sessionActivity"

describe("PresenceManager", () => {
  it("removes logged-out sessions from activity without scheduling offline work", async () => {
    const manager = new PresenceManager()
    const internals = manager as unknown as {
      sessionActivity: SessionActivityTracker
      offlineEvaluations: Map<number, unknown>
    }
    const deactivate = spyOn(internals.sessionActivity, "deactivate")
    try {
      const generation = manager.start()
      await manager.handleConnectionClose({ userId: 1, sessionId: 2 }, generation, true)
      expect(deactivate).toHaveBeenCalledWith(2, generation)
      expect(internals.offlineEvaluations.size).toBe(0)
    } finally {
      deactivate.mockRestore()
      await manager.shutdown()
    }
  })

  it("invalidates and joins a started offline evaluation during shutdown", async () => {
    const directoryRead = Promise.withResolvers<{
      status: "available"
      complete: boolean
      connections: []
    }>()
    const list = spyOn(connectionDirectory, "list").mockImplementation(async () => directoryRead.promise)
    const manager = new PresenceManager()
    const update = spyOn(manager, "updateUserOnlineStatus").mockResolvedValue({
      online: false,
      lastOnline: new Date(),
    })
    const internals = manager as unknown as {
      offlineEvaluations: Map<number, { generation: number }>
      startOfflineEvaluation(
        userId: number,
        pending: { generation: number },
        generation: number,
        retryUnknown: boolean,
      ): void
    }
    const pending = { generation: 0 }
    internals.offlineEvaluations.set(55, pending)

    try {
      internals.startOfflineEvaluation(55, pending, 0, true)
      await Promise.resolve()

      let stopped = false
      const shutdown = manager.shutdown().then(() => { stopped = true })
      await Promise.resolve()
      expect(stopped).toBe(false)

      directoryRead.resolve({ status: "available", complete: true, connections: [] })
      await shutdown
      expect(update).not.toHaveBeenCalled()
    } finally {
      directoryRead.resolve({ status: "available", complete: true, connections: [] })
      await manager.shutdown()
      update.mockRestore()
      list.mockRestore()
    }
  })
})
