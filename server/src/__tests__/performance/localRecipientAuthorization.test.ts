import { afterAll, beforeAll, describe, expect, spyOn, test } from "bun:test"
import { and, eq } from "drizzle-orm"
import { ServerProtocolMessage, Update } from "@inline-chat/protocol/core"
import { db, schema } from "@in/server/db"
import { deactivateCommittedSpaceMembership } from "@in/server/modules/authorization/spaceMembershipLifecycle"
import { authorizeLiveDeliveries } from "@in/server/modules/internalMessaging/liveAuthorization"
import { recentRealtimeRepair } from "@in/server/modules/internalMessaging/recentRepair"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { ConnVersion, connectionManager } from "@in/server/ws/connections"
import { setupTestDatabase, teardownTestDatabase, testUtils } from "../setup"

// Every test owns distinct users/Spaces/chats. Reusing the file's disposable DB
// avoids a full-schema truncate between fixtures without sharing authority.
beforeAll(setupTestDatabase)
afterAll(teardownTestDatabase)

type SocketRecord = { connectionId: string; frames: Update[][] }
const TEST_TIMEOUT_MS = 120_000

async function connect(userId: number, connectionId: string, transportError?: Error): Promise<SocketRecord> {
  const { session } = await testUtils.createSessionForUser(userId)
  return admit(userId, session.id, connectionId, transportError)
}

function admit(userId: number, sessionId: number, connectionId: string, transportError?: Error): SocketRecord {
  const record: SocketRecord = { connectionId, frames: [] }
  connectionManager.addConnection({
    id: connectionId,
    close() {},
    subscribe() {},
    raw: {
      sendBinary(bytes: Uint8Array) {
        if (transportError) throw transportError
        const frame = ServerProtocolMessage.fromBinary(bytes)
        if (frame.body.oneofKind === "message" && frame.body.message.payload.oneofKind === "update") {
          record.frames.push(frame.body.message.payload.update.updates)
        }
        return 1
      },
    },
  } as never, ConnVersion.REALTIME_V1)
  connectionManager.authenticateConnection(connectionId, userId, sessionId)
  return record
}

function content(chatId: number, title = "protected content"): Update {
  return Update.create({ update: { oneofKind: "chatInfo", chatInfo: { chatId: BigInt(chatId), title } } })
}

/** Admission membership hydration is separate from the delivery being measured. */
function preventMembershipHydration() {
  return spyOn(connectionManager as unknown as { getUserSpaceIds(userId: number): Promise<number[]> }, "getUserSpaceIds")
    .mockResolvedValue([])
}

describe("ordinary local recipient authorization", () => {
  for (const recipientCount of [1, 10, 100]) {
    test(`delivers current content to ${recipientCount} connected recipients with one batched authority query`, async () => {
      const hydration = preventMembershipHydration()
      const sockets: SocketRecord[] = []
      try {
        const space = await testUtils.createSpace(`local-recipient-batch-${recipientCount}`)
        if (!space) throw new Error("Expected Space")
        const users = await db.insert(schema.users).values(Array.from({ length: recipientCount }, (_, index) => ({
          email: `local-recipient-batch-${recipientCount}-${index}@example.test`,
        }))).returning()
        await db.insert(schema.members).values(users.map(({ id }) => ({
          spaceId: space.id, userId: id, role: "member" as const, canAccessPublicChats: null,
        })))
        const chat = await testUtils.createChat(space.id)
        if (!chat) throw new Error("Expected chat")
        for (let offset = 0; offset < users.length; offset += 10) {
          sockets.push(...await Promise.all(users.slice(offset, offset + 10).map((user, index) =>
            connect(user.id, `local-recipient-batch-${recipientCount}-${offset + index}`))))
        }
        await connectionManager.waitForBackgroundWork()
        const update = content(chat.id)
        const select = spyOn(db, "select")
        const execute = spyOn(db, "execute")
        try {
          await Promise.all(users.map(({ id }) => RealtimeUpdates.pushToUser(id, [update])))
          expect(execute).toHaveBeenCalledTimes(1)
          expect(select).toHaveBeenCalledTimes(0)
          expect(sockets.map(({ frames }) => frames)).toEqual(Array.from({ length: recipientCount }, () => [[update]]))
        } finally {
          execute.mockRestore()
          select.mockRestore()
        }
      } finally {
        for (const { connectionId } of sockets) connectionManager.removeConnection(connectionId)
        hydration.mockRestore()
      }
    }, TEST_TIMEOUT_MS)
  }

  test("evaluates distinct deliveries to the same socket independently", async () => {
    const hydration = preventMembershipHydration()
    const sockets: SocketRecord[] = []
    try {
      const user = await testUtils.createUser("local-recipient-mixed@example.test")
      const allowed = await testUtils.createChat(null, "allowed", "thread", false)
      const denied = await testUtils.createChat(null, "denied", "thread", false)
      if (!allowed || !denied) throw new Error("Expected chats")
      await testUtils.addParticipant(allowed.id, user.id)
      const socket = await connect(user.id, "local-recipient-mixed")
      sockets.push(socket)
      await connectionManager.waitForBackgroundWork()
      const accepted = content(allowed.id, "allowed payload")
      const rejected = content(denied.id, "denied payload")
      const execute = spyOn(db, "execute")
      try {
        await Promise.all([
          RealtimeUpdates.pushToUser(user.id, [accepted]),
          RealtimeUpdates.pushToUser(user.id, [rejected]),
        ])
        expect(socket.frames).toEqual([[accepted]])
        // Same-user FIFO admission preserves transport order between calls.
        expect(execute).toHaveBeenCalledTimes(2)
        execute.mockClear()
        const acceptedDelivery = { userId: user.id, updates: [accepted], label: "allowed" }
        const deniedDelivery = { userId: user.id, updates: [rejected], label: "denied" }
        expect(await authorizeLiveDeliveries([acceptedDelivery, deniedDelivery])).toEqual([acceptedDelivery])
        expect(execute).toHaveBeenCalledTimes(1)
      } finally {
        execute.mockRestore()
      }
    } finally {
      for (const { connectionId } of sockets) connectionManager.removeConnection(connectionId)
      hydration.mockRestore()
    }
  }, TEST_TIMEOUT_MS)

  test("resolves each recipient's DM alias while rejecting an unrelated canonical chat", async () => {
    const hydration = preventMembershipHydration()
    const sockets: SocketRecord[] = []
    try {
      const a = await testUtils.createUser("local-recipient-dm-a@example.test")
      const b = await testUtils.createUser("local-recipient-dm-b@example.test")
      const stranger = await testUtils.createUser("local-recipient-dm-stranger@example.test")
      const chat = await testUtils.createPrivateChat(a, b)
      const unrelated = await testUtils.createPrivateChat(b, stranger)
      if (!chat || !unrelated) throw new Error("Expected DMs")
      const forA = await connect(a.id, "local-recipient-dm-a")
      const forB = await connect(b.id, "local-recipient-dm-b")
      sockets.push(forA, forB)
      await connectionManager.waitForBackgroundWork()
      const alias = (peerId: number) => Update.create({ update: { oneofKind: "deleteMessages", deleteMessages: {
        messageIds: [1n], peerId: { type: { oneofKind: "user", user: { userId: BigInt(peerId) } } },
      } } })
      const aUpdate = alias(b.id)
      const bUpdate = alias(a.id)
      const select = spyOn(db, "select")
      const execute = spyOn(db, "execute")
      try {
        await Promise.all([
          RealtimeUpdates.pushToUser(a.id, [aUpdate]),
          RealtimeUpdates.pushToUser(b.id, [bUpdate]),
          RealtimeUpdates.pushToUser(a.id, [content(unrelated.id)]),
        ])
        expect(forA.frames).toEqual([[aUpdate]])
        expect(forB.frames).toEqual([[bUpdate]])
        expect(select).toHaveBeenCalledTimes(1)
        expect(execute).toHaveBeenCalledTimes(2)
      } finally {
        execute.mockRestore()
        select.mockRestore()
      }
    } finally {
      for (const { connectionId } of sockets) connectionManager.removeConnection(connectionId)
      hydration.mockRestore()
    }
  }, TEST_TIMEOUT_MS)

  test("an admission changed during the authority query receives no content or repair receipt", async () => {
    const hydration = preventMembershipHydration()
    const sockets: SocketRecord[] = []
    const previousMode = process.env["INLINE_REALTIME_DISTRIBUTED"]
    const resume = Promise.withResolvers<void>()
    try {
      const user = await testUtils.createUser("local-recipient-epoch@example.test")
      const chat = await testUtils.createChat(null, "epoch", "thread", false)
      if (!chat) throw new Error("Expected chat")
      await testUtils.addParticipant(chat.id, user.id)
      const { session } = await testUtils.createSessionForUser(user.id)
      const original = admit(user.id, session.id, "local-recipient-epoch-original")
      sockets.push(original)
      await connectionManager.waitForBackgroundWork()
      const started = Promise.withResolvers<void>()
      const executeQuery = db.execute.bind(db)
      const restoreQueryExecutions: (() => void)[] = []
      let heldQuery = false
      const execute = spyOn(db, "execute").mockImplementation(
        <TRow extends Record<string, unknown> = Record<string, unknown>>(query: Parameters<typeof db.execute>[0]) => {
          const result = executeQuery<TRow>(query)
          if (heldQuery) return result
          heldQuery = true
          const executeResult = result.execute.bind(result)
          const delayed = spyOn(result, "execute").mockImplementation(async () => {
            const rows = await executeResult()
            started.resolve()
            await resume.promise
            return rows
          })
          restoreQueryExecutions.push(() => delayed.mockRestore())
          return result
        },
      )
      const observe = spyOn(recentRealtimeRepair, "observeDelivery")
      process.env["INLINE_REALTIME_DISTRIBUTED"] = "1"
      let delivery: Promise<void> | undefined
      try {
        delivery = RealtimeUpdates.pushToUser(user.id, [content(chat.id)])
        await Promise.race([started.promise, delivery.then(() => {
          throw new Error("Content delivery finished before its authority query")
        })])
        connectionManager.removeConnection(original.connectionId)
        const replacement = admit(user.id, session.id, "local-recipient-epoch-replacement")
        sockets.push(replacement)
        resume.resolve()
        await delivery
        expect(original.frames).toEqual([])
        expect(replacement.frames).toEqual([])
        expect(observe).not.toHaveBeenCalled()
      } finally {
        resume.resolve()
        await Promise.allSettled([delivery])
        observe.mockRestore()
        for (const restore of restoreQueryExecutions) restore()
        execute.mockRestore()
      }
    } finally {
      if (previousMode === undefined) delete process.env["INLINE_REALTIME_DISTRIBUTED"]
      else process.env["INLINE_REALTIME_DISTRIBUTED"] = previousMode
      for (const { connectionId } of sockets) connectionManager.removeConnection(connectionId)
      hydration.mockRestore()
    }
  }, TEST_TIMEOUT_MS)

  test("own Space removal reaches the transport inside the locked membership callback", async () => {
    const hydration = preventMembershipHydration()
    const sockets: SocketRecord[] = []
    try {
      const user = await testUtils.createUser("local-recipient-own-removal@example.test")
      const space = await testUtils.createSpace("local-recipient-own-removal")
      if (!space) throw new Error("Expected Space")
      const [member] = await db.insert(schema.members).values({ spaceId: space.id, userId: user.id, role: "member" }).returning()
      if (!member) throw new Error("Expected member")
      const socket = await connect(user.id, "local-recipient-own-removal")
      sockets.push(socket)
      await connectionManager.waitForBackgroundWork()
      await db.delete(schema.members).where(and(eq(schema.members.spaceId, space.id), eq(schema.members.userId, user.id)))
      const removal = Update.create({ update: { oneofKind: "spaceMemberDelete", spaceMemberDelete: {
        spaceId: BigInt(space.id), userId: BigInt(user.id), memberId: BigInt(member.id),
      } } })
      let queued: Promise<void> | undefined
      const removed = await deactivateCommittedSpaceMembership({ spaceId: space.id, userId: user.id, memberId: member.id }, () => {
        queued = RealtimeUpdates.pushToUser(user.id, [removal])
        // A deferred database admission here would release the generation lock
        // before the unsequenced eviction can reach this retained socket.
        expect(socket.frames).toEqual([[removal]])
        return undefined
      })
      await queued
      expect(removed).toBe(true)
      expect(socket.frames).toEqual([[removal]])
    } finally {
      for (const { connectionId } of sockets) connectionManager.removeConnection(connectionId)
      hydration.mockRestore()
    }
  }, TEST_TIMEOUT_MS)

  test("a throwing transport does not suppress another authorized recipient or the mutation receipt", async () => {
    const hydration = preventMembershipHydration()
    const sockets: SocketRecord[] = []
    try {
      const broken = await testUtils.createUser("local-recipient-broken-transport@example.test")
      const healthy = await testUtils.createUser("local-recipient-healthy-transport@example.test")
      const chat = await testUtils.createChat(null, "transport isolation", "thread", false)
      if (!chat) throw new Error("Expected chat")
      await db.insert(schema.chatParticipants).values([broken, healthy].map(({ id }) => ({ chatId: chat.id, userId: id })))
      sockets.push(...await Promise.all([
        connect(broken.id, "local-recipient-broken-transport", new Error("synthetic transport failure")),
        connect(healthy.id, "local-recipient-healthy-transport"),
      ]))
      await connectionManager.waitForBackgroundWork()
      const update = content(chat.id)
      const results = await Promise.allSettled([broken, healthy].map(({ id }) => RealtimeUpdates.pushToUser(id, [update])))
      expect(results.map(({ status }) => status)).toEqual(["fulfilled", "fulfilled"])
      expect(sockets.map(({ frames }) => frames)).toEqual([[], [[update]]])
    } finally {
      for (const { connectionId } of sockets) connectionManager.removeConnection(connectionId)
      hydration.mockRestore()
    }
  }, TEST_TIMEOUT_MS)

  test("deferred authorization and transport retain the caller's original update projection", async () => {
    const hydration = preventMembershipHydration()
    const sockets: SocketRecord[] = []
    try {
      const user = await testUtils.createUser("local-recipient-projection-snapshot@example.test")
      const allowed = await testUtils.createChat(null, "snapshot allowed", "thread", false)
      const denied = await testUtils.createChat(null, "snapshot denied", "thread", false)
      if (!allowed || !denied) throw new Error("Expected chats")
      await testUtils.addParticipant(allowed.id, user.id)
      const socket = await connect(user.id, "local-recipient-projection-snapshot")
      sockets.push(socket)
      await connectionManager.waitForBackgroundWork()
      const expected = content(allowed.id, "original projection")
      const callerUpdate = Update.clone(expected)
      const delivery = RealtimeUpdates.pushToUser(user.id, [callerUpdate])
      if (callerUpdate.update.oneofKind !== "chatInfo") throw new Error("Expected chatInfo fixture")
      callerUpdate.update.chatInfo.chatId = BigInt(denied.id)
      callerUpdate.update.chatInfo.title = "mutated projection"
      await delivery
      expect(socket.frames).toEqual([[expected]])
    } finally {
      for (const { connectionId } of sockets) connectionManager.removeConnection(connectionId)
      hydration.mockRestore()
    }
  }, TEST_TIMEOUT_MS)

  test("a blocked user's queued content observes pre-query revocation without blocking another user", async () => {
    const hydration = preventMembershipHydration()
    const sockets: SocketRecord[] = []
    const resume = Promise.withResolvers<void>()
    const deliveries: Promise<void>[] = []
    try {
      const blocked = await testUtils.createUser("local-recipient-blocked@example.test")
      const independent = await testUtils.createUser("local-recipient-independent@example.test")
      const chat = await testUtils.createChat(null, "independent admission", "thread", false)
      if (!chat) throw new Error("Expected chat")
      await db.insert(schema.chatParticipants).values([blocked, independent].map(({ id }) => ({ chatId: chat.id, userId: id })))
      sockets.push(...await Promise.all([
        connect(blocked.id, "local-recipient-blocked"),
        connect(independent.id, "local-recipient-independent"),
      ]))
      await connectionManager.waitForBackgroundWork()
      const started = Promise.withResolvers<void>()
      const executeQuery = db.execute.bind(db)
      const restoreQueryExecutions: (() => void)[] = []
      let queryCount = 0
      const execute = spyOn(db, "execute").mockImplementation(
        <TRow extends Record<string, unknown> = Record<string, unknown>>(query: Parameters<typeof db.execute>[0]) => {
          const result = executeQuery<TRow>(query)
          if (++queryCount !== 1) return result
          const executeResult = result.execute.bind(result)
          const delayed = spyOn(result, "execute").mockImplementation(async () => {
            started.resolve()
            await resume.promise
            return executeResult()
          })
          restoreQueryExecutions.push(() => delayed.mockRestore())
          return result
        },
      )
      try {
        const first = content(chat.id, "first blocked-user payload")
        const second = content(chat.id, "second blocked-user payload")
        const independentUpdate = content(chat.id, "independent-user payload")
        const firstDelivery = RealtimeUpdates.pushToUser(blocked.id, [first])
        deliveries.push(firstDelivery)
        await Promise.race([started.promise, firstDelivery.then(() => {
          throw new Error("Content delivery finished before its authority query")
        })])
        deliveries.push(RealtimeUpdates.pushToUser(blocked.id, [second]))
        const independentDelivery = RealtimeUpdates.pushToUser(independent.id, [independentUpdate])
        deliveries.push(independentDelivery)
        let timer: ReturnType<typeof setTimeout> | undefined
        try {
          await Promise.race([independentDelivery, new Promise<never>((_, reject) => {
            timer = setTimeout(() => reject(new Error("An independent recipient waited on the blocked user's query")), 15_000)
          })])
        } finally {
          clearTimeout(timer)
        }
        expect(sockets[0]?.frames).toEqual([])
        expect(sockets[1]?.frames).toEqual([[independentUpdate]])
        expect(queryCount).toBe(2)
        // Neither decision for this user may use a snapshot taken before the
        // revocation: the first final authority statement has not started yet,
        // and the queued second call waits for its predecessor to complete.
        await db.delete(schema.chatParticipants).where(and(eq(schema.chatParticipants.chatId, chat.id), eq(schema.chatParticipants.userId, blocked.id)))
        resume.resolve()
        await Promise.all(deliveries)
        expect(sockets[0]?.frames).toEqual([])
        expect(sockets[1]?.frames).toEqual([[independentUpdate]])
        expect(queryCount).toBe(3)
      } finally {
        resume.resolve()
        await Promise.allSettled(deliveries)
        for (const restore of restoreQueryExecutions) restore()
        execute.mockRestore()
      }
    } finally {
      resume.resolve()
      for (const { connectionId } of sockets) connectionManager.removeConnection(connectionId)
      hydration.mockRestore()
    }
  }, TEST_TIMEOUT_MS)

  test("a coalesced chat and Space batch uses one final snapshot after pre-query membership revocation", async () => {
    const hydration = preventMembershipHydration()
    const sockets: SocketRecord[] = []
    const resume = Promise.withResolvers<void>()
    const deliveries: Promise<void>[] = []
    try {
      const removed = await testUtils.createUser("local-recipient-final-snapshot-removed@example.test")
      const remaining = await testUtils.createUser("local-recipient-final-snapshot-remaining@example.test")
      const space = await testUtils.createSpace("local-recipient-final-snapshot")
      if (!space) throw new Error("Expected Space")
      await db.insert(schema.members).values([removed, remaining].map(({ id }) => ({
        spaceId: space.id, userId: id, role: "member" as const, canAccessPublicChats: null,
      })))
      const chat = await testUtils.createChat(space.id)
      if (!chat) throw new Error("Expected chat")
      sockets.push(...await Promise.all([
        connect(removed.id, "local-recipient-final-snapshot-removed"),
        connect(remaining.id, "local-recipient-final-snapshot-remaining"),
      ]))
      await connectionManager.waitForBackgroundWork()
      const started = Promise.withResolvers<void>()
      const executeQuery = db.execute.bind(db)
      const restoreQueryExecutions: (() => void)[] = []
      const execute = spyOn(db, "execute").mockImplementation(
        <TRow extends Record<string, unknown> = Record<string, unknown>>(query: Parameters<typeof db.execute>[0]) => {
          const result = executeQuery<TRow>(query)
          const executeResult = result.execute.bind(result)
          const delayed = spyOn(result, "execute").mockImplementation(async () => {
            started.resolve()
            await resume.promise
            return executeResult()
          })
          restoreQueryExecutions.push(() => delayed.mockRestore())
          return result
        },
      )
      const select = spyOn(db, "select")
      try {
        const chatUpdate = content(chat.id, "revoked chat content")
        const spaceUpdate = Update.create({ update: { oneofKind: "spaceProfile", spaceProfile: {
          spaceId: BigInt(space.id), isPro: false,
        } } })
        deliveries.push(
          RealtimeUpdates.pushToUser(removed.id, [chatUpdate]),
          RealtimeUpdates.pushToUser(remaining.id, [spaceUpdate]),
        )
        await Promise.race([started.promise, Promise.all(deliveries).then(() => {
          throw new Error("Content delivery finished before its final authority statement")
        })])
        await db.delete(schema.members).where(and(eq(schema.members.spaceId, space.id), eq(schema.members.userId, removed.id)))
        expect(connectionManager.getUserConnections(removed.id)).toHaveLength(1)
        resume.resolve()
        await Promise.all(deliveries)
        expect(sockets[0]?.frames).toEqual([])
        expect(sockets[1]?.frames).toEqual([[spaceUpdate]])
        expect(execute).toHaveBeenCalledTimes(1)
        // There is no separate membership or active-account read after chat
        // authority. All batch requirements share the final statement's snapshot.
        expect(select).toHaveBeenCalledTimes(0)
      } finally {
        resume.resolve()
        await Promise.allSettled(deliveries)
        select.mockRestore()
        for (const restore of restoreQueryExecutions) restore()
        execute.mockRestore()
      }
    } finally {
      resume.resolve()
      for (const { connectionId } of sockets) connectionManager.removeConnection(connectionId)
      hydration.mockRestore()
    }
  }, TEST_TIMEOUT_MS)
})
