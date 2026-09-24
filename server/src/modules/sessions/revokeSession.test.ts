import { describe, expect, test, spyOn } from "bun:test"
import { connectionManager } from "@in/server/ws/connections"
import { internalMessaging } from "@in/server/modules/internalMessaging/service"
import { outboundPublications } from "@in/server/modules/internalMessaging/outbound"
import type { BrokerPublication } from "@in/server/modules/internalMessaging/redis"
import { finishSessionRevocation } from "./revokeSession"

describe("finishSessionRevocation", () => {
  test("closes local sockets and returns before the critical broker hint settles", async () => {
    const publication = Promise.withResolvers<BrokerPublication>()
    const close = spyOn(connectionManager, "closeConnectionForSession")
    const publish = spyOn(internalMessaging, "publish").mockImplementation(() => publication.promise)

    const finished = finishSessionRevocation({
      result: { session: {} as never, revoked: true, alreadyRevoked: false },
      gridState: undefined,
    }, {
      actor: "admin",
      targetUserId: 82_002,
      sessionId: 91_002,
    })

    try {
      await finished
      expect(close).toHaveBeenCalledWith(82_002, 91_002, { authenticationInvalidated: true }, undefined)
      for (let attempt = 0; attempt < 8 && publish.mock.calls.length === 0; attempt += 1) await Promise.resolve()
      expect(publish).toHaveBeenCalledTimes(1)

      publication.resolve({ status: "unavailable" })
      await outboundPublications.drain()
    } finally {
      publication.resolve({ status: "unavailable" })
      await outboundPublications.drain()
      publish.mockRestore()
      close.mockRestore()
    }
  })
})
