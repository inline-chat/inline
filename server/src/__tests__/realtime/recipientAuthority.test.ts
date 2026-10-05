import { afterAll, afterEach, beforeAll, expect, mock, spyOn, test } from "bun:test"
import { generateKeyPairSync, randomUUID, type KeyObject } from "node:crypto"
import { and, eq } from "drizzle-orm"
import { ClientMessage, ServerProtocolMessage, Update, UpdateNewMessageNotification_Reason, type Message } from "@inline-chat/protocol/core"
import { RealtimeDelivery } from "@in/server/protocol/server"
import { db, schema } from "@in/server/db"
import { setupTestDatabase, teardownTestDatabase, testUtils } from "@in/server/__tests__/setup"
import { trackBackgroundWork } from "@in/server/__tests__/background"
import { makeCandidateHttpApplication } from "@in/server/core/http/candidateApplication"
import { startCoreProductionServer } from "@in/server/core/http/productionHost"
import { createSubthread } from "@in/server/functions/messages.createSubthread"
import { moveThread } from "@in/server/functions/messages.moveThread"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { editMessage } from "@in/server/functions/messages.editMessage"
import { addReaction } from "@in/server/functions/messages.addReaction"
import { getChatHistory } from "@in/server/functions/messages.getChatHistory"
import { getChats } from "@in/server/functions/messages.getChats"
import { deleteMemberHandler } from "@in/server/realtime/handlers/space.deleteMember"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { getUpdateGroupFromInputPeer } from "@in/server/modules/updates"
import * as updateGroups from "@in/server/modules/updates"
import { SessionsModel } from "@in/server/db/models/sessions"
import * as apn from "@in/server/libs/apn"
import { desktopPushSuppressionTracker } from "@in/server/modules/notifications/desktopPushSuppression"
import {
  decryptSendMessagePushContentForTests, PUSH_CONTENT_ALGORITHM, PUSH_CONTENT_VERSION,
  type EncryptedPushContentEnvelope, type EncryptedSendMessagePushContent,
} from "@in/server/modules/notifications/pushContentEncryption"
import { InternalMessagingService } from "@in/server/modules/internalMessaging/service"
import { LiveRealtimeDelivery, deliveryPartition } from "@in/server/modules/internalMessaging/liveDelivery"
import { encodeEnvelope } from "@in/server/modules/internalMessaging/schemas"
import { Encryption2 } from "@in/server/modules/encryption/encryption2"
import { applicationBackgroundWork } from "@in/server/lifecycle/backgroundWork"
import { connectionBackgroundWork } from "@in/server/ws/backgroundWork"
import { connectionManager } from "@in/server/ws/connections"
import { waitForPostCommitHooks } from "@in/server/db/commitHooks"
import * as threadTitles from "@in/server/modules/threadTitles"
import * as threadLinks from "@in/server/modules/threadGraph/links"
import * as parentMaterialization from "@in/server/modules/subthreadParentMaterialization"
import * as subthreads from "@in/server/modules/subthreads"

// Only provider boundaries are replaced. Creation, authorization, persistence,
// realtime admission, envelope decoding, and the WebSocket transport stay real.
mock.module("@in/server/libs/openAI", () => ({
  openaiClient: { chat: { completions: { parse: async () => ({
    choices: [{ finish_reason: "stop", message: { parsed: { title: null, emoji: null } } }],
  }) } } },
}))

let host: Awaited<ReturnType<typeof startCoreProductionServer>> | undefined
// This production runtime owns the database pool. Keep it alive across the
// file's resets and close it only after every socket and test job has settled.
beforeAll(setupTestDatabase, 120_000)
afterAll(async () => {
  try { await settleWork(); await host?.shutdown() }
  finally { await teardownTestDatabase() }
}, 120_000)
// Each case creates distinct users/Spaces/chats. Keeping the file-owned clone
// avoids repeated full-schema TRUNCATE work while exercising one live listener.
async function startHost() {
  if (host) return host
  console.info("RECIPIENT_AUTHORITY:HOST_START")
  host = await startCoreProductionServer({
    application: makeCandidateHttpApplication({ apiBaseUrl: "http://127.0.0.1", middleware: { isProduction: false } }),
    hostname: "127.0.0.1", port: 0, inlineProtocolConfiguration: { enabled: false },
    installSignalHandlers: false, startBackgroundProcesses: false, startClusterServices: false,
    markShuttingDown: () => {},
  })
  console.info("RECIPIENT_AUTHORITY:HOST_READY")
  return host
}

const background = trackBackgroundWork()
const trackedTitle = background.wrap(threadTitles.maybeScheduleThreadTitleGeneration)
const trackedReplyLink = background.wrap(threadLinks.materializeReplyThreadLink)
const trackedMessageLinks = background.wrap(threadLinks.replaceMessageThreadLinks)
const trackedParentCard = background.wrap(parentMaterialization.materializeFirstMessageExperience)
const trackedParentUpdate = background.wrap(subthreads.emitMessageSubthreadUpdateIfNeeded)
const spies = [
  spyOn(threadTitles, "maybeScheduleThreadTitleGeneration").mockImplementation(trackedTitle),
  spyOn(threadLinks, "materializeReplyThreadLink").mockImplementation(trackedReplyLink),
  spyOn(threadLinks, "replaceMessageThreadLinks").mockImplementation(trackedMessageLinks),
  spyOn(parentMaterialization, "materializeFirstMessageExperience").mockImplementation(trackedParentCard),
  spyOn(subthreads, "emitMessageSubthreadUpdateIfNeeded").mockImplementation(trackedParentUpdate),
]
afterEach(() => background.drain())
afterAll(() => { for (const spy of spies) spy.mockRestore() })

const peer = (chatId: number) => ({ type: { oneofKind: "chat" as const, chat: { chatId: BigInt(chatId) } } })
const context = (userId: number) => testUtils.functionContext({ userId })
const bounded = async <T>(work: Promise<T>, label: string): Promise<T> => {
  let timer: ReturnType<typeof setTimeout> | undefined
  try {
    return await Promise.race([work, new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new Error(`Timed out: ${label}`)), 5_000)
    })])
  } finally { clearTimeout(timer) }
}

async function settleWork() {
  await background.drain()
  await applicationBackgroundWork.waitForIdle()
  await waitForPostCommitHooks()
  await background.drain()
  await connectionBackgroundWork.waitForIdle()
}

async function connect(port: number, userId: number) {
  const { token } = await testUtils.createSessionForUser(userId, { clientType: "cli" })
  const socket = new WebSocket(`ws://127.0.0.1:${port}/realtime`)
  socket.binaryType = "arraybuffer"
  const frames: ServerProtocolMessage[] = []
  const waiters = new Set<{ matches: (frame: ServerProtocolMessage) => boolean; resolve: (frame: ServerProtocolMessage) => void }>()
  const failures: unknown[] = []
  socket.addEventListener("message", ({ data }) => {
    try {
      const frame = ServerProtocolMessage.fromBinary(new Uint8Array(data as ArrayBuffer))
      frames.push(frame)
      for (const waiter of waiters) {
        if (!waiter.matches(frame)) continue
        waiters.delete(waiter)
        waiter.resolve(frame)
      }
    } catch (error) { failures.push(error) }
  })
  const waitFor = (matches: (frame: ServerProtocolMessage) => boolean) => bounded(new Promise<ServerProtocolMessage>((resolve) => {
    waiters.add({ matches, resolve })
  }), "socket frame")
  let requestId = 10n
  const send = (body: ClientMessage["body"]) => {
    const id = requestId++
    socket.send(Uint8Array.from(ClientMessage.toBinary({ id, seq: Number(id), body })).buffer)
  }
  const opened = new Promise<void>((resolve, reject) => {
    socket.addEventListener("open", () => resolve(), { once: true })
    socket.addEventListener("error", () => reject(new Error("Local WebSocket error")), { once: true })
  })
  await bounded(opened, "socket open")
  const authenticated = waitFor((frame) => frame.body.oneofKind === "connectionOpen")
  send({ oneofKind: "connectionInit", connectionInit: { token, layer: 2, clientVersion: "1.0.0" } })
  await authenticated
  await connectionBackgroundWork.waitForIdle()
  return {
    socket,
    frames,
    updates: () => frames.flatMap((frame) => frame.body.oneofKind === "message" && frame.body.message.payload.oneofKind === "update"
      ? frame.body.message.payload.update.updates : []),
    clear: () => { frames.length = 0 },
    // The pong is ordered behind all already accepted outbound frames. This
    // proves absence without a delay or a negative assertion on a mocked send.
    barrier: async () => {
      const nonce = requestId
      const pong = waitFor((frame) => frame.body.oneofKind === "pong" && frame.body.pong.nonce === nonce)
      send({ oneofKind: "ping", ping: { nonce } })
      await pong
      expect(failures).toEqual([])
    },
    close: async () => {
      if (socket.readyState === WebSocket.CLOSED) return
      const closed = new Promise<void>((resolve) => socket.addEventListener("close", () => resolve(), { once: true }))
      socket.close()
      await bounded(closed, "socket close")
    },
  }
}

type Client = Awaited<ReturnType<typeof connect>>

async function withWire(run: (wire: {
  connect: (userId: number) => Promise<Client>
  remote: (userIds: number[], updates: Update[], options?: { grouped: boolean }) => Promise<void>
  notifications: number[]
  notificationContent: { userId: number; content: EncryptedSendMessagePushContent }[]
}) => Promise<void>) {
  const previousMode = process.env["INLINE_REALTIME_DISTRIBUTED"]
  process.env["INLINE_REALTIME_DISTRIBUTED"] = "1"
  const notifications: number[] = []
  const notificationContent: { userId: number; content: EncryptedSendMessagePushContent }[] = []
  const pushKeys = new Map<number, KeyObject>()
  const provider = {
    send: async (notification: { payload: Record<string, unknown> }) => {
      const userId = Number(notification.payload["recipientUserId"])
      notifications.push(userId)
      const privateKey = pushKeys.get(userId)
      if (privateKey && notification.payload["encryptedContent"]) {
        notificationContent.push({ userId, content: decryptSendMessagePushContentForTests({
          privateKey, envelope: notification.payload["encryptedContent"] as EncryptedPushContentEnvelope,
        }) })
      }
      return { sent: [], failed: [] }
    },
  }
  const push = spyOn(apn, "getApnProvider").mockReturnValue(provider as unknown as ReturnType<typeof apn.getApnProvider>)
  const service = new InternalMessagingService("")
  let receive: ((frame: string, channel: string) => void) | undefined
  const transport = {
    health: "ready" as const,
    start: async (_channels: readonly string[], callback: (frame: string, channel: string) => void) => { receive = callback },
    publish: async () => ({ status: "published" as const, subscribers: 1 }),
    close: async () => {}, onContinuityLost: () => () => {}, onReady: () => () => {},
  }
  // Substitute Redis's raw publication transport; use the default real receiver.
  ;(service as unknown as { transport: typeof transport }).transport = transport
  const live = new LiveRealtimeDelivery(service)
  const clients: Client[] = []
  const cleanupFailures: unknown[] = []
  try {
    const listener = await startHost()
    await service.start()
    live.start()
    await run({
      notifications,
      notificationContent,
      connect: async (userId) => {
        const key = generateKeyPairSync("x25519")
        const publicDer = key.publicKey.export({ format: "der", type: "spki" })
        if (!Buffer.isBuffer(publicDer)) throw new Error("Unexpected fixture public key format")
        pushKeys.set(userId, key.privateKey)
        const ios = await testUtils.createSessionForUser(userId, { clientType: "ios" })
        await SessionsModel.updatePushNotificationDetails(ios.session.id, {
          applePushToken: `authority-fixture-${userId}`,
          pushContentEncryptionKey: { publicKey: publicDer.subarray(publicDer.length - 32), keyId: `fixture-${userId}`, algorithm: PUSH_CONTENT_ALGORITHM },
          pushContentVersion: PUSH_CONTENT_VERSION,
        })
        const client = await connect(listener.port, userId)
        clients.push(client)
        return client
      },
      remote: async (userIds, updates, options) => {
        const consumed = live.diagnostics.received
        // Recipients in different ordering lanes require separate envelopes;
        // a shared Space lane also lets the real receiver exercise one batch.
        const groups = options?.grouped ? [userIds] : userIds.map((userId) => [userId])
        for (const recipients of groups) {
          const eventId = randomUUID()
          const originBootId = randomUUID()
          const first = recipients[0]
          if (first === undefined) throw new Error("Missing grouped remote recipient")
          const partition = deliveryPartition(updates, first)
          if (recipients.some((userId) => deliveryPartition(updates, userId) !== partition)) {
            throw new Error("Grouped remote recipients must share an ordering lane")
          }
          const bytes = RealtimeDelivery.toBinary({
            version: 1, eventId, originBootId, partition,
            expiresAtMs: BigInt(Date.now() + 5_000), userIds: recipients.map(BigInt), updates,
          })
          if (!receive) throw new Error("Missing real service consumer")
          receive(encodeEnvelope({
            version: 1, eventId, originBootId, target: { kind: "cluster" },
            event: { kind: "RealtimeDelivery", partition, payload: Encryption2.encrypt(bytes).toString("base64") },
          }), service.key("internal:v1:cluster"))
        }
        await service.waitForIncomingWork()
        expect(live.diagnostics.received - consumed).toBe(groups.length)
      },
    })
  } finally {
    const cleanup = async (work: () => Promise<unknown>) => {
      try { await work() } catch (error) { cleanupFailures.push(error) }
    }
    await cleanup(settleWork)
    const closed = await Promise.allSettled(clients.map((client) => client.close()))
    for (const result of closed) if (result.status === "rejected") cleanupFailures.push(result.reason)
    await cleanup(() => live.stop())
    await cleanup(() => service.close())
    push.mockRestore()
    if (previousMode === undefined) delete process.env["INLINE_REALTIME_DISTRIBUTED"]
    else process.env["INLINE_REALTIME_DISTRIBUTED"] = previousMode
  }
  if (cleanupFailures.length) throw new AggregateError(cleanupFailures, "Recipient authority fixture cleanup failed")
}

function sentMessage(updates: Update[]): Message {
  const update = updates.find((value) => value.update.oneofKind === "newMessage")
  if (update?.update.oneofKind !== "newMessage" || !update.update.newMessage.message) throw new Error("Expected sent message")
  return update.update.newMessage.message
}

function content(message: Message): Update[] {
  return [
    Update.create({ update: { oneofKind: "newMessage", newMessage: { message } } }),
    Update.create({ update: { oneofKind: "editMessage", editMessage: { message: { ...message, message: "stale edited content" } } } }),
    Update.create({ update: { oneofKind: "newMessageNotification", newMessageNotification: {
      message, reason: UpdateNewMessageNotification_Reason.UNSPECIFIED,
    } } }),
    Update.create({ update: { oneofKind: "deleteReaction", deleteReaction: {
      chatId: message.chatId, messageId: message.id, userId: message.fromId, emoji: "👍",
    } } }),
    Update.create({ update: { oneofKind: "chatInfo", chatInfo: { chatId: message.chatId, title: "private title" } } }),
  ]
}

async function assertAccess(chatId: number, allowed: number[], denied: number[], senderId: number) {
  const [chat] = await db.select().from(schema.chats).where(eq(schema.chats.id, chatId))
  if (!chat) throw new Error("Missing authority fixture chat")
  const group = await getUpdateGroupFromInputPeer(peer(chatId), { currentUserId: senderId })
  for (const userId of allowed) {
    await expect(AccessGuards.ensureChatAccess(chat, userId)).resolves.toBeUndefined()
    await expect(getChatHistory({ peerId: peer(chatId) }, context(userId))).resolves.toBeDefined()
    expect((await getChats({ includeSubthreads: true }, context(userId))).chats.some((value) => Number(value.id) === chatId)).toBe(true)
    expect(group.userIds).toContain(userId)
  }
  for (const userId of denied) {
    await expect(AccessGuards.ensureChatAccess(chat, userId)).rejects.toBeDefined()
    await expect(getChatHistory({ peerId: peer(chatId) }, context(userId))).rejects.toBeDefined()
    expect((await getChats({ includeSubthreads: true }, context(userId))).chats.some((value) => Number(value.id) === chatId)).toBe(false)
    expect(group.userIds).not.toContain(userId)
  }
}

async function assertStaleContent(wire: Parameters<Parameters<typeof withWire>[0]>[0], message: Message, reader: Client, denied: Client, readerId: number, deniedId: number) {
  const updates = content(message)
  reader.clear(); denied.clear()
  await Promise.all([RealtimeUpdates.pushToUser(readerId, updates), RealtimeUpdates.pushToUser(deniedId, updates)])
  await Promise.all([reader.barrier(), denied.barrier()])
  expect(reader.updates().map((update) => update.update.oneofKind)).toEqual(updates.map((update) => update.update.oneofKind))
  expect(denied.updates()).toEqual([])
  reader.clear(); denied.clear()
  await wire.remote([readerId, deniedId], updates)
  await Promise.all([reader.barrier(), denied.barrier()])
  expect(reader.updates().map((update) => update.update.oneofKind)).toEqual(updates.map((update) => update.update.oneofKind))
  expect(denied.updates()).toEqual([])
}

test("an explicit Space-child outsider grant cannot deliver content or notifications to an existing socket", async () => {
  const { users: [owner, reader], space } = await testUtils.createSpaceWithMembers("Child delivery", ["child-owner@example.test", "child-reader@example.test"])
  await db.update(schema.users).set({ firstName: "Sender" }).where(eq(schema.users.id, owner.id))
  const outsider = await testUtils.createUser("child-outsider@example.test")
  const root = await testUtils.createChat(space.id, "Public parent", "thread", true, owner.id)
  if (!root) throw new Error("Expected parent")
  const created = await createSubthread({ parentChatId: BigInt(root.id), title: "Private child", participants: [
    { userId: BigInt(reader.id) }, { userId: BigInt(outsider.id) },
  ] }, context(owner.id))
  const childId = Number(created.chat.id)
  expect(await db.select().from(schema.chatParticipants).where(and(eq(schema.chatParticipants.chatId, childId), eq(schema.chatParticipants.userId, outsider.id)))).toHaveLength(1)
  await assertAccess(childId, [reader.id], [outsider.id], owner.id)
  await withWire(async (wire) => {
    const readerSocket = await wire.connect(reader.id)
    const outsiderSocket = await wire.connect(outsider.id)
    readerSocket.clear(); outsiderSocket.clear()
    const sent = await sendMessage({ peerId: peer(childId), message: "Space child secret" }, context(owner.id))
    await settleWork()
    await Promise.all([readerSocket.barrier(), outsiderSocket.barrier()])
    expect(readerSocket.updates().some(({ update }) => update.oneofKind === "newMessage" && update.newMessage.message?.message === "Space child secret")).toBe(true)
    expect(outsiderSocket.updates()).toEqual([])
    expect(wire.notifications).not.toContain(outsider.id)
    expect(wire.notificationContent.some(({ userId, content }) => userId === reader.id && content.body === "Sender: Space child secret")).toBe(true)
    await assertAccess(childId, [reader.id], [outsider.id], owner.id)
    const message = sentMessage(sent.updates)
    readerSocket.clear(); outsiderSocket.clear()
    await editMessage({ messageId: message.id, peer: peer(childId), text: "Edited Space child secret" }, context(owner.id))
    await addReaction({ messageId: message.id, peer: peer(childId), emoji: "👍" }, context(owner.id))
    await settleWork()
    await Promise.all([readerSocket.barrier(), outsiderSocket.barrier()])
    expect(readerSocket.updates().some(({ update }) => update.oneofKind === "editMessage" && update.editMessage.message?.message === "Edited Space child secret")).toBe(true)
    expect(readerSocket.updates().some(({ update }) => update.oneofKind === "updateReaction")).toBe(true)
    expect(outsiderSocket.updates()).toEqual([])
    await assertStaleContent(wire, message, readerSocket, outsiderSocket, reader.id, outsider.id)
  })
}, 120_000)

test("moving a Home root fences retained NULL-space child grants after real member removal", async () => {
  const { users: [owner, reader, former], space } = await testUtils.createSpaceWithMembers("Moved root delivery", [
    "move-owner@example.test", "move-reader@example.test", "move-former@example.test",
  ])
  await db.update(schema.members).set({ role: "owner" }).where(and(eq(schema.members.spaceId, space.id), eq(schema.members.userId, owner.id)))
  const root = await testUtils.createChat(null, "Moved Home parent", "thread", false, owner.id)
  if (!root) throw new Error("Expected Home root")
  for (const user of [owner, reader, former]) await testUtils.addParticipant(root.id, user.id)
  const created = await createSubthread({ parentChatId: BigInt(root.id), title: "Retained Home child", participants: [
    { userId: BigInt(reader.id) }, { userId: BigInt(former.id) },
  ] }, context(owner.id))
  const childId = Number(created.chat.id)
  await moveThread({ chatId: root.id, spaceId: space.id }, context(owner.id))
  const [child] = await db.select().from(schema.chats).where(eq(schema.chats.id, childId))
  expect(child?.spaceId).toBeNull()
  await withWire(async (wire) => {
    const readerSocket = await wire.connect(reader.id)
    const formerSocket = await wire.connect(former.id)
    await deleteMemberHandler({ spaceId: BigInt(space.id), userId: BigInt(former.id), blockJoin: false }, {
      userId: owner.id, sessionId: 456, connectionId: "fixture-admin", sendRaw() {}, sendRpcReply() {},
    })
    await settleWork()
    await Promise.all([readerSocket.barrier(), formerSocket.barrier()])
    expect(await db.select().from(schema.chatParticipants).where(and(eq(schema.chatParticipants.chatId, childId), eq(schema.chatParticipants.userId, former.id)))).toHaveLength(1)
    readerSocket.clear(); formerSocket.clear()
    const sent = await sendMessage({ peerId: peer(childId), message: "Secret after departure" }, context(owner.id))
    await settleWork()
    await Promise.all([readerSocket.barrier(), formerSocket.barrier()])
    expect(readerSocket.updates().some(({ update }) => update.oneofKind === "newMessage" && update.newMessage.message?.message === "Secret after departure")).toBe(true)
    expect(formerSocket.updates()).toEqual([])
    expect(wire.notifications).not.toContain(former.id)
    await assertAccess(childId, [reader.id], [former.id], owner.id)
    await assertStaleContent(wire, sentMessage(sent.updates), readerSocket, formerSocket, reader.id, former.id)
    // Addressed removals still arrive after membership authority is gone.
    const removal = Update.create({ update: { oneofKind: "spaceMemberDelete", spaceMemberDelete: {
      spaceId: BigInt(space.id), userId: BigInt(former.id),
    } } })
    await RealtimeUpdates.pushToUser(former.id, [removal])
    await wire.remote([former.id], [removal])
    await formerSocket.barrier()
    expect(formerSocket.updates().map((update) => update.update.oneofKind)).toEqual(["spaceMemberDelete", "spaceMemberDelete"])
  })
}, 120_000)

test("legacy NULL public-access membership receives real sends while a restricted member does not", async () => {
  const { users: [owner, reader, restricted], space } = await testUtils.createSpaceWithMembers("Nullable delivery", [
    "null-owner@example.test", "null-reader@example.test", "false-reader@example.test",
  ])
  await db.update(schema.members).set({ canAccessPublicChats: null }).where(and(eq(schema.members.spaceId, space.id), eq(schema.members.userId, reader.id)))
  await db.update(schema.members).set({ canAccessPublicChats: false }).where(and(eq(schema.members.spaceId, space.id), eq(schema.members.userId, restricted.id)))
  const root = await testUtils.createChat(space.id, "Public NULL access", "thread", true, owner.id)
  if (!root) throw new Error("Expected public root")
  await withWire(async (wire) => {
    const readerSocket = await wire.connect(reader.id)
    const restrictedSocket = await wire.connect(restricted.id)
    const sent = await sendMessage({ peerId: peer(root.id), message: "Legacy member delivery" }, context(owner.id))
    await settleWork()
    await Promise.all([readerSocket.barrier(), restrictedSocket.barrier()])
    expect(readerSocket.updates().some(({ update }) => update.oneofKind === "newMessage" && update.newMessage.message?.message === "Legacy member delivery")).toBe(true)
    expect(restrictedSocket.updates()).toEqual([])
    await assertAccess(root.id, [reader.id], [restricted.id], owner.id)
    await assertStaleContent(wire, sentMessage(sent.updates), readerSocket, restrictedSocket, reader.id, restricted.id)
  })
}, 120_000)

test("a soft-deleted account with an existing socket cannot receive stale content", async () => {
  const { users: [owner, reader, deleted], space } = await testUtils.createSpaceWithMembers("Deleted account delivery", [
    "delete-owner@example.test", "delete-reader@example.test", "delete-account@example.test",
  ])
  const root = await testUtils.createChat(space.id, "Private account content", "thread", false, owner.id)
  if (!root) throw new Error("Expected private root")
  for (const user of [owner, reader, deleted]) await testUtils.addParticipant(root.id, user.id)
  await withWire(async (wire) => {
    const readerSocket = await wire.connect(reader.id)
    const deletedSocket = await wire.connect(deleted.id)
    const sent = await sendMessage({ peerId: peer(root.id), message: "Pre-deletion content" }, context(owner.id))
    await settleWork()
    await Promise.all([readerSocket.barrier(), deletedSocket.barrier()])
    await db.update(schema.users).set({ deleted: true }).where(eq(schema.users.id, deleted.id))
    expect((await getUpdateGroupFromInputPeer(peer(root.id), { currentUserId: owner.id })).userIds).not.toContain(deleted.id)
    await assertStaleContent(wire, sentMessage(sent.updates), readerSocket, deletedSocket, reader.id, deleted.id)
    const removal = Update.create({ update: { oneofKind: "participantDelete", participantDelete: {
      chatId: BigInt(root.id), userId: BigInt(deleted.id),
    } } })
    await RealtimeUpdates.pushToUser(deleted.id, [removal])
    await wire.remote([deleted.id], [removal])
    await deletedSocket.barrier()
    // The local exact-recipient ID-only eviction retains its existing contract;
    // the remote consumer additionally checks account authority for controls.
    expect(deletedSocket.updates().map((update) => update.update.oneofKind)).toEqual(["participantDelete"])
  })
}, 120_000)

test("soft-deleting the owning Space prevents local and remote content while addressed revocation survives", async () => {
  const { users: [owner, reader], space } = await testUtils.createSpaceWithMembers("Deleted Space delivery", [
    "space-delete-owner@example.test", "space-delete-reader@example.test",
  ])
  const root = await testUtils.createChat(space.id, "Public deleted Space", "thread", true, owner.id)
  if (!root) throw new Error("Expected public root")
  await withWire(async (wire) => {
    const readerSocket = await wire.connect(reader.id)
    const sent = await sendMessage({ peerId: peer(root.id), message: "Before Space deletion" }, context(owner.id))
    await settleWork()
    await readerSocket.barrier()
    await db.update(schema.spaces).set({ deleted: new Date() }).where(eq(schema.spaces.id, space.id))
    await assertAccess(root.id, [], [reader.id], owner.id)
    readerSocket.clear()
    await RealtimeUpdates.pushToUser(reader.id, content(sentMessage(sent.updates)))
    await wire.remote([reader.id], content(sentMessage(sent.updates)))
    await readerSocket.barrier()
    expect(readerSocket.updates()).toEqual([])
    const removal = Update.create({ update: { oneofKind: "spaceMemberDelete", spaceMemberDelete: {
      spaceId: BigInt(space.id), userId: BigInt(reader.id),
    } } })
    await RealtimeUpdates.pushToUser(reader.id, [removal])
    await wire.remote([reader.id], [removal])
    await readerSocket.barrier()
    expect(readerSocket.updates().map((update) => update.update.oneofKind)).toEqual(["spaceMemberDelete", "spaceMemberDelete"])
  })
}, 120_000)

test("member removal during notification preparation prevents provider content submission", async () => {
  const { users: [owner, reader, former], space } = await testUtils.createSpaceWithMembers("Notification authority", [
    "notify-owner@example.test", "notify-reader@example.test", "notify-former@example.test",
  ])
  await db.update(schema.members).set({ role: "owner" }).where(and(eq(schema.members.spaceId, space.id), eq(schema.members.userId, owner.id)))
  await db.update(schema.users).set({ firstName: "Sender" }).where(eq(schema.users.id, owner.id))
  const root = await testUtils.createChat(space.id, "Notification race", "thread", true, owner.id)
  if (!root) throw new Error("Expected public root")
  await withWire(async (wire) => {
    await wire.connect(reader.id)
    const formerSocket = await wire.connect(former.id)
    const preparing = Promise.withResolvers<void>()
    const release = Promise.withResolvers<void>()
    const original = desktopPushSuppressionTracker.shouldSuppressIOSSendMessagePush.bind(desktopPushSuppressionTracker)
    const suppression = spyOn(desktopPushSuppressionTracker, "shouldSuppressIOSSendMessagePush").mockImplementation(async (input) => {
      if (input.userId === former.id) {
        preparing.resolve()
        await release.promise
      }
      return original(input)
    })
    try {
      const sent = await sendMessage({ peerId: peer(root.id), message: "Notification preparation race" }, context(owner.id))
      expect(sentMessage(sent.updates).message).toBe("Notification preparation race")
      await bounded(preparing.promise, "notification preparation")
      await deleteMemberHandler({ spaceId: BigInt(space.id), userId: BigInt(former.id), blockJoin: false }, {
        userId: owner.id, sessionId: 456, connectionId: "fixture-admin", sendRaw() {}, sendRpcReply() {},
      })
      release.resolve()
      await settleWork()
      await formerSocket.barrier()
      expect(wire.notifications).toContain(reader.id)
      expect(wire.notifications).not.toContain(former.id)
      expect(wire.notificationContent.some(({ userId, content }) => userId === reader.id && content.body === "Sender: Notification preparation race")).toBe(true)
    } finally {
      release.resolve()
      await settleWork()
      suppression.mockRestore()
    }
  })
}, 120_000)

test("member removal during real push-session lookup prevents APN submission", async () => {
  const { users: [owner, reader, former], space } = await testUtils.createSpaceWithMembers("Provider authority", [
    "provider-owner@example.test", "provider-reader@example.test", "provider-former@example.test",
  ])
  await db.update(schema.members).set({ role: "owner" }).where(and(eq(schema.members.spaceId, space.id), eq(schema.members.userId, owner.id)))
  await db.update(schema.users).set({ firstName: "Sender" }).where(eq(schema.users.id, owner.id))
  const root = await testUtils.createChat(space.id, "Provider preparation race", "thread", true, owner.id)
  if (!root) throw new Error("Expected public root")
  await withWire(async (wire) => {
    await wire.connect(reader.id)
    const formerSocket = await wire.connect(former.id)
    const preparing = Promise.withResolvers<void>()
    const release = Promise.withResolvers<void>()
    const original = SessionsModel.getValidPushSessionsByUserId.bind(SessionsModel)
    const sessions = spyOn(SessionsModel, "getValidPushSessionsByUserId").mockImplementation(async (userId) => {
      if (userId === former.id) {
        preparing.resolve()
        await release.promise
      }
      return original(userId)
    })
    try {
      await sendMessage({ peerId: peer(root.id), message: "Provider session lookup race" }, context(owner.id))
      await bounded(preparing.promise, "real push-session lookup")
      await deleteMemberHandler({ spaceId: BigInt(space.id), userId: BigInt(former.id), blockJoin: false }, {
        userId: owner.id, sessionId: 456, connectionId: "fixture-admin", sendRaw() {}, sendRpcReply() {},
      })
      release.resolve()
      await settleWork()
      await formerSocket.barrier()
      expect(wire.notifications).toContain(reader.id)
      expect(wire.notifications).not.toContain(former.id)
      expect(wire.notificationContent.some(({ userId, content }) => userId === reader.id && content.body === "Sender: Provider session lookup race")).toBe(true)
    } finally {
      release.resolve()
      await settleWork()
      sessions.mockRestore()
    }
  })
}, 120_000)

test("a committed send retains its RPC receipt when sender authority disappears before recipient resolution", async () => {
  const { users: [admin, sender, reader], space } = await testUtils.createSpaceWithMembers("Committed receipt", [
    "receipt-admin@example.test", "receipt-sender@example.test", "receipt-reader@example.test",
  ])
  await db.update(schema.members).set({ role: "owner" }).where(and(eq(schema.members.spaceId, space.id), eq(schema.members.userId, admin.id)))
  const root = await testUtils.createChat(space.id, "Receipt race", "thread", true, admin.id)
  if (!root) throw new Error("Expected public root")
  const resolving = Promise.withResolvers<void>()
  const release = Promise.withResolvers<void>()
  const original = updateGroups.getUpdateGroupFromInputPeer
  let paused = false
  const group = spyOn(updateGroups, "getUpdateGroupFromInputPeer").mockImplementation(async (inputPeer, actor) => {
    if (!paused && actor.currentUserId === sender.id) {
      paused = true
      resolving.resolve()
      await release.promise
    }
    return original(inputPeer, actor)
  })
  const pending = sendMessage({ peerId: peer(root.id), message: "Committed before revocation", randomId: 71234n }, context(sender.id))
  try {
    await bounded(resolving.promise, "post-commit recipient resolution")
    expect(await db.select({ id: schema.messages.messageId }).from(schema.messages).where(and(
      eq(schema.messages.chatId, root.id), eq(schema.messages.randomId, 71234n),
    ))).toHaveLength(1)
    await deleteMemberHandler({ spaceId: BigInt(space.id), userId: BigInt(sender.id), blockJoin: false }, {
      userId: admin.id, sessionId: 456, connectionId: "fixture-admin", sendRaw() {}, sendRpcReply() {},
    })
    release.resolve()
    const result = await pending
    expect(result.updates.map((update) => update.update.oneofKind)).toEqual(["updateMessageId", "newMessage"])
    expect(sentMessage(result.updates).message).toBe("Committed before revocation")
    const idUpdate = result.updates[0]?.update
    if (idUpdate?.oneofKind !== "updateMessageId") throw new Error("Missing committed receipt")
    expect(idUpdate.updateMessageId.randomId).toBe(71234n)
    expect((await getChatHistory({ peerId: peer(root.id) }, context(reader.id))).messages.some((message) => message.id === idUpdate.updateMessageId.messageId)).toBe(true)
  } finally {
    release.resolve()
    await Promise.allSettled([pending])
    await settleWork()
    group.mockRestore()
  }
}, 120_000)

test("a mixed chat and Space batch reaches retained WebSockets from one final authority snapshot", async () => {
  const { users: [removed, remaining], space } = await testUtils.createSpaceWithMembers("Mixed wire snapshot", [
    "mixed-wire-removed@example.test", "mixed-wire-remaining@example.test",
  ])
  const chat = await testUtils.createChat(space.id, "Mixed wire protected chat")
  if (!chat) throw new Error("Expected public chat")
  await withWire(async (wire) => {
    const removedSocket = await wire.connect(removed.id)
    const remainingSocket = await wire.connect(remaining.id)
    await settleWork()
    await Promise.all([removedSocket.barrier(), remainingSocket.barrier()])
    removedSocket.clear(); remainingSocket.clear()
    const retainedEpoch = connectionManager.getUserConnectionEpoch(removed.id)
    const chatUpdate = Update.create({ update: { oneofKind: "chatInfo", chatInfo: {
      chatId: BigInt(chat.id), title: "Revoked mixed-batch chat content",
    } } })
    const spaceUpdate = Update.create({ update: { oneofKind: "spaceProfile", spaceProfile: {
      spaceId: BigInt(space.id), isPro: false,
    } } })
    const starting = Promise.withResolvers<void>()
    const release = Promise.withResolvers<void>()
    const executeQuery = db.execute.bind(db)
    const selectQuery = db.select.bind(db)
    const restoreDelayedQueries: (() => void)[] = []
    // Gate the final resource read in both designs: before the combined SQL
    // starts, or before the former separate Space read after real chat SQL.
    // Every query still executes against PostgreSQL; no rows are substituted.
    const execute = spyOn(db, "execute").mockImplementation(<TRow extends Record<string, unknown>>(
      query: Parameters<typeof db.execute>[0],
    ) => {
      const pending = executeQuery<TRow>(query)
      if (pending.getQuery().sql.includes("'space'::text as kind")) {
        const run = pending.execute.bind(pending)
        const delayed = spyOn(pending, "execute").mockImplementation(async () => {
          starting.resolve()
          await release.promise
          return run()
        })
        restoreDelayedQueries.push(() => delayed.mockRestore())
      }
      return pending
    })
    const select = spyOn(db, "select").mockImplementation(((...args: Parameters<typeof db.select>) => {
      const builder = selectQuery(...args)
      const fields = args[0]
      if (fields?.["spaceId"] !== schema.members.spaceId || fields?.["userId"] !== schema.members.userId) return builder
      const fromQuery = builder.from.bind(builder)
      builder.from = ((...fromArgs: Parameters<typeof builder.from>) => {
        const query = fromQuery(...fromArgs)
        const thenQuery = query.then.bind(query)
        const delayed = spyOn(query, "then").mockImplementation(((...callbacks: Parameters<typeof query.then>) => {
          starting.resolve()
          return release.promise.then(() => thenQuery(...callbacks))
        }) as typeof query.then)
        restoreDelayedQueries.push(() => delayed.mockRestore())
        return query
      }) as typeof builder.from
      return builder
    }) as typeof db.select)
    const deliveries: Promise<void>[] = []
    try {
      deliveries.push(
        RealtimeUpdates.pushToUser(removed.id, [chatUpdate]),
        RealtimeUpdates.pushToUser(remaining.id, [spaceUpdate]),
      )
      await bounded(Promise.race([starting.promise, Promise.all(deliveries).then(() => {
        throw new Error("Mixed wire delivery finished before its final authority statement")
      })]), "mixed wire final authority statement")
      await db.delete(schema.members).where(and(eq(schema.members.spaceId, space.id), eq(schema.members.userId, removed.id)))
      expect(removedSocket.socket.readyState).toBe(WebSocket.OPEN)
      expect(connectionManager.getUserConnections(removed.id)).toHaveLength(1)
      expect(connectionManager.getUserConnectionEpoch(removed.id)).toBe(retainedEpoch)
      release.resolve()
      await Promise.all(deliveries)
      await Promise.all([removedSocket.barrier(), remainingSocket.barrier()])
      expect(removedSocket.updates()).toEqual([])
      expect(remainingSocket.updates()).toEqual([spaceUpdate])
      // No DM alias preparation is needed here. Chat and Space authority must
      // share one final statement, without a later membership/account read.
      expect(execute).toHaveBeenCalledTimes(1)
      expect(select).toHaveBeenCalledTimes(0)
    } finally {
      release.resolve()
      await Promise.allSettled(deliveries)
      for (const restore of restoreDelayedQueries) restore()
      select.mockRestore()
      execute.mockRestore()
    }
    // A single admission snapshot does not make later concurrent revocation
    // writes atomic with transport handoff; this case commits before that read.
  })
}, 120_000)

test("one remote batch submits both WebSockets before awaiting the first transport completion", async () => {
  const { users: [first, second], space } = await testUtils.createSpaceWithMembers("Remote handoff batch", [
    "remote-handoff-first@example.test", "remote-handoff-second@example.test",
  ])
  await withWire(async (wire) => {
    const firstSocket = await wire.connect(first.id)
    const secondSocket = await wire.connect(second.id)
    await settleWork()
    await Promise.all([firstSocket.barrier(), secondSocket.barrier()])
    firstSocket.clear(); secondSocket.clear()
    const update = Update.create({ update: { oneofKind: "spaceProfile", spaceProfile: {
      spaceId: BigInt(space.id), isPro: false,
    } } })
    const submitted = Promise.withResolvers<void>()
    const release = Promise.withResolvers<void>()
    const pushToUser = RealtimeUpdates.pushToUserWithDelivery.bind(RealtimeUpdates)
    let firstAccepted = 0
    const completion = spyOn(RealtimeUpdates, "pushToUserWithDelivery").mockImplementation((userId, updates, options) => {
      // Call the actual transport immediately. Only its returned completion is
      // held; frame serialization, raw submission, and both sockets stay real.
      const handoff = pushToUser(userId, updates, options)
      if (userId !== first.id) return handoff
      return handoff.then(async (accepted) => {
        firstAccepted = accepted
        submitted.resolve()
        await release.promise
        return accepted
      })
    })
    let finished = false
    const pending = wire.remote([first.id, second.id], [update], { grouped: true }).finally(() => { finished = true })
    try {
      await bounded(Promise.race([submitted.promise, pending.then(() => {
        throw new Error("Remote batch finished before its held transport completion")
      })]), "first real remote transport submission")
      expect(firstAccepted).toBe(1)
      await Promise.all([firstSocket.barrier(), secondSocket.barrier()])
      expect(firstSocket.updates()).toEqual([update])
      expect(secondSocket.updates()).toEqual([update])
      expect(finished).toBe(false)
      release.resolve()
      await pending
    } finally {
      release.resolve()
      await Promise.allSettled([pending])
      completion.mockRestore()
    }
    // This verifies the bounded batch's transport start boundary. It does not
    // make concurrent writes atomic with the receiver's authority snapshot.
  })
}, 120_000)
