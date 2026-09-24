import { describe, expect, spyOn, test } from "bun:test"
import { db } from "@in/server/db"
import * as schema from "@in/server/db/schema"
import { deliverTargetedBucketHint } from "@in/server/modules/internalMessaging/repair"
import { ConnVersion, connectionManager } from "@in/server/ws/connections"
import { setupTestLifecycle, testUtils } from "../setup"

setupTestLifecycle()

describe("durable broker hint fanout", () => {
  for (const recipientCount of [1, 10, 100]) {
    test(`authorizes and delivers a chat hint to ${recipientCount} local recipients in one access query`, async () => {
      const membershipReader = connectionManager as unknown as {
        getUserSpaceIds(userId: number): Promise<number[]>
      }
      const readMemberships = spyOn(membershipReader, "getUserSpaceIds").mockResolvedValue([])
      const sockets: Array<{ connectionId: string; sent: number }> = []
      try {
        const space = await testUtils.createSpace(`durable-fanout-${recipientCount}`)
        if (!space) throw new Error("Expected test space")
        const users = await Promise.all(Array.from({ length: recipientCount }, (_, index) =>
          testUtils.createUser(`durable-fanout-${recipientCount}-${index}@example.test`)))
        await db.insert(schema.members).values(users.map((user) => ({
          spaceId: space.id,
          userId: user.id,
          role: "member" as const,
          canAccessPublicChats: true,
        })))
        const [chat] = await db.insert(schema.chats).values({
          type: "thread",
          spaceId: space.id,
          publicThread: true,
          title: "Durable fanout",
          isUntitled: false,
        }).returning()
        if (!chat) throw new Error("Expected test chat")

        for (const [index, user] of users.entries()) {
          const { session } = await testUtils.createSessionForUser(user.id)
          const connectionId = `durable-fanout-${recipientCount}-${index}`
          const record = { connectionId, sent: 0 }
          const socket = {
            id: connectionId,
            close() {},
            subscribe() {},
            raw: { sendBinary: () => { record.sent += 1; return 1 } },
          }
          connectionManager.addConnection(socket as never, ConnVersion.REALTIME_V1)
          connectionManager.authenticateConnection(connectionId, user.id, session.id)
          sockets.push(record)
        }
        await Promise.resolve()

        const select = spyOn(db, "select")
        const execute = spyOn(db, "execute")
        try {
          await deliverTargetedBucketHint({
            kind: "DurableUpdatesAvailable",
            bucket: { kind: "chat", chatId: chat.id },
            frontier: 17,
          } as never)

          // One read fetches the target chat and one source-of-truth access
          // projection covers every local candidate up to the 512-user batch.
          // Thread authorization remains O(local connected users / 512), but
          // broker fanout no longer invokes getUpdatesState per recipient.
          expect(select).toHaveBeenCalledTimes(1)
          expect(execute).toHaveBeenCalledTimes(1)
          expect(sockets.map(({ sent }) => sent)).toEqual(Array(recipientCount).fill(1))
        } finally {
          execute.mockRestore()
          select.mockRestore()
        }
      } finally {
        for (const { connectionId } of sockets) connectionManager.removeConnection(connectionId)
        readMemberships.mockRestore()
      }
    })

    if (recipientCount === 100) {
      test("limits a direct-message hint to its two connected participants", async () => {
        const membershipReader = connectionManager as unknown as {
          getUserSpaceIds(userId: number): Promise<number[]>
        }
        const readMemberships = spyOn(membershipReader, "getUserSpaceIds").mockResolvedValue([])
        const sockets: Array<{ connectionId: string; sent: number; participant: boolean }> = []
        try {
          const sender = await testUtils.createUser("durable-dm-sender@example.test")
          const recipient = await testUtils.createUser("durable-dm-recipient@example.test")
          const unrelated = await Promise.all(Array.from({ length: 100 }, (_, index) =>
            testUtils.createUser(`durable-dm-unrelated-${index}@example.test`)))
          const [minUserId, maxUserId] = [sender.id, recipient.id].sort((a, b) => a - b)
          const [chat] = await db.insert(schema.chats).values({
            type: "private",
            minUserId,
            maxUserId,
          }).returning()
          if (!chat) throw new Error("Expected direct chat")

          for (const [index, user] of [sender, recipient, ...unrelated].entries()) {
            const { session } = await testUtils.createSessionForUser(user.id)
            const connectionId = `durable-dm-${index}`
            const record = {
              connectionId,
              sent: 0,
              participant: user.id === sender.id || user.id === recipient.id,
            }
            const socket = {
              id: connectionId,
              close() {},
              subscribe() {},
              raw: { sendBinary: () => { record.sent += 1; return 1 } },
            }
            connectionManager.addConnection(socket as never, ConnVersion.REALTIME_V1)
            connectionManager.authenticateConnection(connectionId, user.id, session.id)
            sockets.push(record)
          }
          await Promise.resolve()

          const select = spyOn(db, "select")
          const execute = spyOn(db, "execute")
          try {
            await deliverTargetedBucketHint({
              kind: "DurableUpdatesAvailable",
              bucket: { kind: "chat", chatId: chat.id },
              frontier: 17,
            } as never)

            expect(select).toHaveBeenCalledTimes(1)
            expect(execute).toHaveBeenCalledTimes(1)
            expect(sockets.filter(({ participant }) => participant).map(({ sent }) => sent)).toEqual([1, 1])
            expect(sockets.filter(({ participant }) => !participant).every(({ sent }) => sent === 0)).toBe(true)
          } finally {
            execute.mockRestore()
            select.mockRestore()
          }
        } finally {
          for (const { connectionId } of sockets) connectionManager.removeConnection(connectionId)
          readMemberships.mockRestore()
        }
      })
    }

    test(`authorizes and delivers a space hint to ${recipientCount} local recipients in one membership query`, async () => {
      const membershipReader = connectionManager as unknown as {
        getUserSpaceIds(userId: number): Promise<number[]>
      }
      const readMemberships = spyOn(membershipReader, "getUserSpaceIds").mockResolvedValue([])
      const sockets: Array<{ connectionId: string; sent: number }> = []
      try {
        const space = await testUtils.createSpace(`durable-space-fanout-${recipientCount}`)
        if (!space) throw new Error("Expected test space")
        const users = await Promise.all(Array.from({ length: recipientCount }, (_, index) =>
          testUtils.createUser(`durable-space-fanout-${recipientCount}-${index}@example.test`)))
        await db.insert(schema.members).values(users.map((user) => ({
          spaceId: space.id,
          userId: user.id,
          role: "member" as const,
        })))

        for (const [index, user] of users.entries()) {
          const { session } = await testUtils.createSessionForUser(user.id)
          const connectionId = `durable-space-fanout-${recipientCount}-${index}`
          const record = { connectionId, sent: 0 }
          const socket = {
            id: connectionId,
            close() {},
            subscribe() {},
            raw: { sendBinary: () => { record.sent += 1; return 1 } },
          }
          connectionManager.addConnection(socket as never, ConnVersion.REALTIME_V1)
          connectionManager.authenticateConnection(connectionId, user.id, session.id)
          connectionManager.subscribeToSpace(user.id, space.id)
          sockets.push(record)
        }
        await Promise.resolve()

        const select = spyOn(db, "select")
        try {
          await deliverTargetedBucketHint({
            kind: "DurableUpdatesAvailable",
            bucket: { kind: "space", spaceId: space.id },
            frontier: 17,
          } as never)

          expect(select).toHaveBeenCalledTimes(1)
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
