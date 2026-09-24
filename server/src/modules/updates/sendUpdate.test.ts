import { describe, expect, spyOn, test } from "bun:test"
import { DialogsModel } from "@in/server/db/models/dialogs"
import * as transientRealtime from "@in/server/modules/internalMessaging/transient"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { getNewUpdatesForUserPresenceUpdate, sendTransientUpdateFor } from "./sendUpdate"

describe("presence update encoding", () => {
  test("encodes last-online timestamps as Unix seconds", () => {
    const update = getNewUpdatesForUserPresenceUpdate(
      42,
      false,
      new Date("2026-08-16T00:00:00.000Z"),
    )

    expect(update.update.oneofKind).toBe("updateUserStatus")
    if (update.update.oneofKind !== "updateUserStatus") {
      throw new Error("Expected a user status update")
    }

    expect(update.update.updateUserStatus.status?.lastOnline?.date)
      .toBe(1_786_838_400n)
  })

  test("limits concurrent private-dialog presence deliveries", async () => {
    const recipients = Array.from({ length: 33 }, (_, index) => index + 1)
    const releaseDeliveries = Promise.withResolvers<void>()
    let activeDeliveries = 0
    let maximumActiveDeliveries = 0

    const dialogs = spyOn(DialogsModel, "getUserIdsWeHavePrivateDialogsWith").mockResolvedValue(recipients)
    const deliveries = spyOn(RealtimeUpdates, "pushToUser").mockImplementation(async () => {
      activeDeliveries += 1
      maximumActiveDeliveries = Math.max(maximumActiveDeliveries, activeDeliveries)
      await releaseDeliveries.promise
      activeDeliveries -= 1
    })
    const publications = spyOn(transientRealtime, "publishUserPresence").mockImplementation(() => {})

    try {
      const pending = sendTransientUpdateFor({
        reason: {
          userPresenceUpdate: { userId: 100, online: true, lastOnline: null },
        },
      })

      for (let attempt = 0; attempt < 8 && deliveries.mock.calls.length < 32; attempt += 1) {
        await Promise.resolve()
      }
      expect(deliveries).toHaveBeenCalledTimes(32)
      expect(maximumActiveDeliveries).toBe(32)

      releaseDeliveries.resolve()
      await pending

      expect(deliveries).toHaveBeenCalledTimes(33)
      expect(publications).toHaveBeenCalledTimes(33)
      expect(maximumActiveDeliveries).toBe(32)
    } finally {
      releaseDeliveries.resolve()
      dialogs.mockRestore()
      deliveries.mockRestore()
      publications.mockRestore()
    }
  })
})
