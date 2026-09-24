import { describe, expect, spyOn, test } from "bun:test"
import { setupTestLifecycle, testUtils } from "../setup"
import { db } from "@in/server/db"
import { sendMessageToRealtimeUserWithDelivery } from "@in/server/realtime/message"
import { ConnVersion, connectionManager } from "@in/server/ws/connections"

setupTestLifecycle()

describe("realtime delivery session-query regression", () => {
  for (const recipientCount of [1, 10, 100]) {
    test(`delivers to ${recipientCount} connected recipients with zero delivery-time session queries`, async () => {
      const membershipReader = connectionManager as unknown as {
        getUserSpaceIds(userId: number): Promise<number[]>
      }
      const readMemberships = spyOn(membershipReader, "getUserSpaceIds").mockResolvedValue([])
      const sockets: Array<{ connectionId: string; sent: number }> = []
      try {
        for (let index = 0; index < recipientCount; index++) {
          const user = await testUtils.createUser(`delivery-session-query-${recipientCount}-${index}@test.com`)
          const { session } = await testUtils.createSessionForUser(user.id)
          const connectionId = `delivery-session-query-${recipientCount}-${index}`
          const socket = {
            id: connectionId,
            close() {},
            subscribe() {},
            raw: { sendBinary: () => 1 },
          }
          connectionManager.addConnection(socket as never, ConnVersion.REALTIME_V1)
          connectionManager.authenticateConnection(connectionId, user.id, session.id)
          sockets.push({ connectionId, sent: 0 })
          socket.raw.sendBinary = () => {
            const record = sockets.find((candidate) => candidate.connectionId === connectionId)
            if (record) record.sent += 1
            return 1
          }
        }
        await Promise.resolve()
        const select = spyOn(db, "select")
        try {
          await Promise.all(sockets.map(async ({ connectionId }) => {
            const connection = connectionManager.getConnection(connectionId)
            if (!connection?.userId) throw new Error("Synthetic realtime connection was not authenticated")
            await sendMessageToRealtimeUserWithDelivery(connection.userId, {
              oneofKind: "update",
              update: { updates: [] },
            })
          }))

          expect(select).toHaveBeenCalledTimes(0)
          expect(sockets.map(({ sent }) => sent)).toEqual(Array(recipientCount).fill(1))
        } finally {
          select.mockRestore()
        }
      } finally {
        for (const { connectionId } of sockets) connectionManager.removeConnection(connectionId)
        readMemberships.mockRestore()
      }
    })
  }
})
