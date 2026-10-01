import { describe, expect, spyOn, test } from "bun:test"
import { setupTestLifecycle, testUtils } from "../setup"
import { db } from "@in/server/db"
import * as schema from "@in/server/db/schema"
import { sendMessageToRealtimeSpace } from "@in/server/realtime/message"
import { ConnVersion, connectionManager } from "@in/server/ws/connections"
import { deliverTargetedBucketHint } from "@in/server/modules/internalMessaging/repair"
import { SpaceId } from "@in/server/core/schema/identifiers"
import { eq } from "drizzle-orm"

setupTestLifecycle()

describe("protected realtime space delivery", () => {
  test("repairs a new member missing from the local Space index without notifying an outsider", async () => {
    const membershipReader = connectionManager as unknown as {
      getUserSpaceIds(userId: number): Promise<number[]>
    }
    const readMemberships = spyOn(membershipReader, "getUserSpaceIds").mockResolvedValue([])
    const sockets: Array<{ connectionId: string; sent: number }> = []
    try {
      const space = await testUtils.createSpace("space-repair-uncached-member")
      if (!space) throw new Error("Failed to create test space")
      const member = await testUtils.createUser("space-repair-member@example.com")
      const outsider = await testUtils.createUser("space-repair-outsider@example.com")
      const [memberSession, outsiderSession] = await Promise.all([
        testUtils.createSessionForUser(member.id),
        testUtils.createSessionForUser(outsider.id),
      ])

      for (const [userId, sessionId, connectionId] of [
        [member.id, memberSession.session.id, "space-repair-member"],
        [outsider.id, outsiderSession.session.id, "space-repair-outsider"],
      ] as const) {
        const record = { connectionId, sent: 0 }
        const socket = {
          id: connectionId,
          close() {},
          subscribe() {},
          raw: { sendBinary: () => { record.sent += 1; return 1 } },
        }
        connectionManager.addConnection(socket as never, ConnVersion.REALTIME_V1)
        connectionManager.authenticateConnection(connectionId, userId, sessionId)
        sockets.push(record)
      }
      await Promise.resolve()
      // Model a grant on another API while Redis invalidation is unavailable:
      // PostgreSQL sees the member, but this process's index remains empty.
      await db.insert(schema.members).values({ spaceId: space.id, userId: member.id, role: "member" })
      expect(connectionManager.getSpaceUserIds(space.id)).toEqual([])
      const accepted: number[] = []
      const select = spyOn(db, "select")
      try {
        await deliverTargetedBucketHint({
          kind: "DurableUpdatesAvailable",
          bucket: { kind: "space", spaceId: SpaceId.make(space.id) },
          frontier: 2,
        }, { onDelivered: (userId, count) => { if (count > 0) accepted.push(userId) } })
        expect(select).toHaveBeenCalledTimes(1)
        expect(sockets.map(({ sent }) => sent)).toEqual([1, 0])
        expect(accepted).toEqual([member.id])
      } finally {
        select.mockRestore()
      }
    } finally {
      for (const { connectionId } of sockets) connectionManager.removeConnection(connectionId)
      readMemberships.mockRestore()
    }
  })

  test("uses one current-authority query and excludes stale members, deleted users, and deleted spaces", async () => {
    const membershipReader = connectionManager as unknown as {
      getUserSpaceIds(userId: number): Promise<number[]>
    }
    const readMemberships = spyOn(membershipReader, "getUserSpaceIds").mockResolvedValue([])
    const sockets: Array<{ connectionId: string; sent: number }> = []
    try {
      const space = await testUtils.createSpace("protected-fanout-authority")
      const deletedSpace = await testUtils.createSpace("protected-fanout-deleted-space")
      if (!space || !deletedSpace) throw new Error("Failed to create test spaces")
      const active = await testUtils.createUser("protected-fanout-active@example.com")
      const removed = await testUtils.createUser("protected-fanout-removed@example.com")
      const deleted = await testUtils.createUser("protected-fanout-deleted@example.com")
      const [activeSession, removedSession, deletedSession] = await Promise.all([
        testUtils.createSessionForUser(active.id),
        testUtils.createSessionForUser(removed.id),
        testUtils.createSessionForUser(deleted.id),
      ])
      await db.insert(schema.members).values([
        { spaceId: space.id, userId: active.id, role: "member" },
        { spaceId: space.id, userId: removed.id, role: "member" },
        { spaceId: space.id, userId: deleted.id, role: "member" },
        { spaceId: deletedSpace.id, userId: active.id, role: "member" },
      ])
      await db.delete(schema.members).where(eq(schema.members.userId, removed.id))
      await db.update(schema.users).set({ deleted: true }).where(eq(schema.users.id, deleted.id))
      await db.update(schema.spaces).set({ deleted: new Date() }).where(eq(schema.spaces.id, deletedSpace.id))

      for (const [userId, sessionId, connectionId] of [
        [active.id, activeSession.session.id, "protected-fanout-active"],
        [removed.id, removedSession.session.id, "protected-fanout-removed"],
        [deleted.id, deletedSession.session.id, "protected-fanout-deleted"],
      ] as const) {
        const record = { connectionId, sent: 0 }
        const socket = {
          id: connectionId,
          close() {},
          subscribe() {},
          raw: { sendBinary: () => { record.sent += 1; return 1 } },
        }
        connectionManager.addConnection(socket as never, ConnVersion.REALTIME_V1)
        connectionManager.authenticateConnection(connectionId, userId, sessionId)
        sockets.push(record)
      }
      await Promise.resolve()
      for (const userId of [active.id, removed.id, deleted.id]) {
        connectionManager.subscribeToSpace(userId, space.id)
      }
      connectionManager.subscribeToSpace(active.id, deletedSpace.id)

      const select = spyOn(db, "select")
      try {
        await sendMessageToRealtimeSpace(space.id, { oneofKind: "update", update: { updates: [] } })
        expect(select).toHaveBeenCalledTimes(1)
        expect(sockets.map(({ sent }) => sent)).toEqual([1, 0, 0])

        select.mockClear()
        await sendMessageToRealtimeSpace(deletedSpace.id, { oneofKind: "update", update: { updates: [] } })
        expect(select).toHaveBeenCalledTimes(1)
        expect(sockets.map(({ sent }) => sent)).toEqual([1, 0, 0])
      } finally {
        select.mockRestore()
      }
    } finally {
      for (const { connectionId } of sockets) connectionManager.removeConnection(connectionId)
      readMemberships.mockRestore()
    }
  })
})
