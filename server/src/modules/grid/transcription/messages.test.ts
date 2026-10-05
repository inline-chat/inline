import { afterEach, describe, expect, spyOn, test } from "bun:test"
import { createHmac, randomUUID } from "node:crypto"
import { and, eq, sql } from "drizzle-orm"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { db } from "@in/server/db"
import { waitForPostCommitHooks } from "@in/server/db/commitHooks"
import { ChatModel } from "@in/server/db/models/chats"
import { DialogsModel } from "@in/server/db/models/dialogs"
import { MessageModel } from "@in/server/db/models/messages"
import { SpaceSettingsModel } from "@in/server/db/models/spaceSettings"
import { chats, dialogs, gridPresence, gridRooms, gridTranscriptionRuns, gridTranscriptionSegments, members, messages, updates, users, UpdateBucket } from "@in/server/db/schema"
import { deleteMessage } from "@in/server/functions/messages.deleteMessage"
import { deleteChat } from "@in/server/functions/messages.deleteChat"
import { editMessage } from "@in/server/functions/messages.editMessage"
import { getChatHistory } from "@in/server/functions/messages.getChatHistory"
import { updateChatVisibility } from "@in/server/functions/messages.updateChatVisibility"
import { clearChatHistory } from "@in/server/modules/historyClear"
import { durableLiveKitProviderTarget } from "@in/server/modules/grid/livekit"
import { encryptMessage } from "@in/server/modules/encryption/encryptMessage"
import { Notifications } from "@in/server/modules/notifications/notifications"
import { Sync } from "@in/server/modules/updates/sync"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { GridTranscriptMessageKind, MessageEntity_Type, MessageSendMode, type MessageEntity, type Update } from "@inline-chat/protocol/core"
import { insertGridTranscriptMessage } from "./messages"
import { createGridTranscriptDestination, ensureGridRoomThread, grantGridTranscriptUsers } from "./threads"
import { handleGridTranscriptionWorkerRequest } from "./worker"
import { intactDestination } from "./state"

setupTestLifecycle()
const peer = (chatId: number) => ({ type: { oneofKind: "chat" as const, chat: { chatId: BigInt(chatId) } } })
const secret = "grid-transcript-test-secret-0123456789"
const previousConfig = new Map<string, string | undefined>()
function configureWorker() {
  for (const [key, value] of Object.entries({ GRID_TRANSCRIPTION_ENABLED: "true", GRID_TRANSCRIPTION_WORKER_SECRET: secret, GRID_TRANSCRIPTION_MODEL: "meeting", GRID_TRANSCRIPTION_ALLOWED_CLIENT_VERSIONS: "grid-transcript-qualified-test" })) {
    if (!previousConfig.has(key)) previousConfig.set(key, process.env[key])
    process.env[key] = value
  }
}
afterEach(async () => {
  await waitForPostCommitHooks()
  for (const [key, value] of previousConfig) {
    if (value === undefined) delete process.env[key]
    else process.env[key] = value
  }
  previousConfig.clear()
})

async function fixture(label: string) {
  configureWorker()
  const { space, users: people } = await testUtils.createSpaceWithMembers(label, [`${label}-actor@example.test`, `${label}-speaker@example.test`] as const)
  const [actor, speaker] = people
  await db.update(members).set({ role: "owner" }).where(and(eq(members.spaceId, space.id), eq(members.userId, actor.id)))
  await db.update(users).set({ firstName: "Ben" }).where(eq(users.id, speaker.id))
  const [room] = await db.insert(gridRooms).values({ spaceId: space.id, createdByUserId: actor.id, title: label, connectionGeneration: 1, connectionStartedAt: new Date() }).returning()
  if (!room) throw new Error("Room fixture missing")
  await db.transaction((tx) => SpaceSettingsModel.updateGrid(space.id, true, tx))
  const speakerMembershipId = randomUUID()
  for (const user of [actor, speaker]) {
    const { session } = await testUtils.createSessionForUser(user.id, { clientType: "macos", clientVersion: "grid-transcript-qualified-test" })
    await db.insert(gridPresence).values({ userId: user.id, roomId: room.id, ownerSessionId: session.id, mediaMembershipId: user.id === speaker.id ? speakerMembershipId : randomUUID(), microphoneEnabled: true, leaseExpiresAt: new Date(Date.now() + 60_000) })
  }
  const runId = randomUUID()
  const destination = await db.transaction(async (tx) => {
    const roomChatId = await ensureGridRoomThread(tx, { room, actorUserId: actor.id, participantUserIds: [actor.id, speaker.id] })
    const created = await createGridTranscriptDestination(tx, { roomChatId, spaceId: space.id, actorUserId: actor.id, participantUserIds: [actor.id, speaker.id], title: "Transcript", runId })
    return { ...created, roomChatId }
  })
  const [run] = await db.insert(gridTranscriptionRuns).values({
    id: runId, sourceRoomId: room.id, spaceId: space.id, roomChatId: destination.roomChatId,
    transcriptChatId: destination.transcriptChatId, destinationParentChatId: destination.destinationParentChatId,
    originalAnchorId: destination.originalAnchorId, actorUserId: actor.id, requestId: randomUUID(),
    model: "meeting", state: "active", generation: 1, providerTarget: durableLiveKitProviderTarget(),
    claimEpoch: 1, leaseExpiresAt: new Date(Date.now() + 60_000), expiresAt: new Date(Date.now() + 60_000),
  }).returning()
  if (!run) throw new Error("Run fixture missing")
  const [segment] = await db.insert(gridTranscriptionSegments).values({ runId, claimEpoch: 1, speakerUserId: speaker.id, membershipId: speakerMembershipId, trackSid: "TR-test-microphone", sourceTurnKey: "turn-1" }).returning()
  if (!segment) throw new Error("Segment fixture missing")
  await waitForPostCommitHooks()
  const body = Buffer.from(JSON.stringify({ runId, epoch: 1, expiresAt: Date.now() + 60_000 })).toString("base64url")
  const token = `${body}.${createHmac("sha256", secret).update(body).digest("base64url")}`
  const final = () => handleGridTranscriptionWorkerRequest(new Request("http://localhost/internal/grid-transcription/final", {
    method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify({ segmentId: segment.id, text: "@all /deploy https://example.test should remain speech" }),
  }))
  return { actor, speaker, space, room, run, segment, destination, final }
}

describe("Grid transcript ordinary encrypted history", () => {
  test("original anchor links to its selected child in first live delivery and history", async () => {
    const live: Update[] = []
    const delivery = spyOn(RealtimeUpdates, "pushToUser").mockImplementation(async (_userId, events) => { live.push(...events) })
    try {
      const s = await fixture("linked-grid-anchor")
      const expectedEntity: MessageEntity = {
        type: MessageEntity_Type.THREAD, offset: 0n, length: BigInt("Grid transcription".length),
        entity: { oneofKind: "thread", thread: { chatId: BigInt(s.destination.transcriptChatId) } },
      }
      const [stored] = await db.select().from(messages).where(and(eq(messages.chatId, s.destination.destinationParentChatId), eq(messages.messageId, s.destination.originalAnchorId)))
      expect(stored?.entitiesEncrypted).not.toBeNull()
      const history = await getChatHistory({ peerId: peer(s.destination.destinationParentChatId) }, testUtils.functionContext({ userId: s.speaker.id }))
      expect(history.messages[0]?.entities?.entities).toEqual([expectedEntity])
      expect(history.messages[0]?.serviceMessage?.event).toMatchObject({ oneofKind: "gridTranscript", gridTranscript: { kind: GridTranscriptMessageKind.GRID_TRANSCRIPT_STARTED } })
      const liveAnchors = live.flatMap((event) => event.update.oneofKind === "newMessage" && event.update.newMessage.message?.id === BigInt(s.destination.originalAnchorId) ? [event.update.newMessage.message] : [])
      expect(liveAnchors).toHaveLength(2)
      for (const anchor of liveAnchors) expect(anchor.entities?.entities).toEqual([expectedEntity])
    } finally { delivery.mockRestore() }
  })

  test("actual final is encrypted, attributed and quiet in live delivery, history and replay", async () => {
    configureWorker()
    const s = await fixture("quiet-grid-turn")
    await db.insert(dialogs).values({ chatId: s.destination.transcriptChatId, userId: s.speaker.id, spaceId: s.space.id, open: false, archived: true })
    const beforeDialogs = await db.select().from(dialogs).where(eq(dialogs.chatId, s.destination.transcriptChatId))
    const live: Update[] = []
    const delivery = spyOn(RealtimeUpdates, "pushToUser").mockImplementation(async (_userId, events) => { live.push(...events) })
    const push = spyOn(Notifications, "sendToUser").mockResolvedValue(undefined)
    try {
      const response = await s.final()
      expect(response.status).toBe(200)
      const result = await response.json() as { messageId: number }
      await waitForPostCommitHooks()
      const [stored] = await db.select().from(messages).where(and(eq(messages.chatId, s.destination.transcriptChatId), eq(messages.messageId, result.messageId)))
      expect(stored).toMatchObject({ fromId: s.actor.id, text: null, countsAsUnread: false, hasLink: false, entitiesEncrypted: null, actionsEncrypted: null })
      expect(stored?.textEncrypted).not.toBeNull()
      expect(stored?.systemMessageEncrypted).not.toBeNull()
      const history = await getChatHistory({ peerId: peer(s.destination.transcriptChatId) }, testUtils.functionContext({ userId: s.speaker.id }))
      expect(history.messages[0]?.message).toBe("Transcript · Ben: @all /deploy https://example.test should remain speech")
      expect(history.messages[0]).toMatchObject({ countsAsUnread: false, sendMode: MessageSendMode.MODE_SILENT, mentioned: false })
      expect(history.messages[0]?.serviceMessage?.event).toMatchObject({ oneofKind: "gridTranscript", gridTranscript: { runId: s.run.id, segmentId: s.segment.id, speakerUserId: BigInt(s.speaker.id) } })
      const rows = await db.select().from(updates).where(and(eq(updates.bucket, UpdateBucket.Chat), eq(updates.entityId, s.destination.transcriptChatId)))
      const replay = await Sync.processChatUpdates({ chatId: s.destination.transcriptChatId, peerId: peer(s.destination.transcriptChatId), userId: s.speaker.id, updates: rows })
      const replayed = replay.updates.find((update) => update.update.oneofKind === "newMessage")
      expect(replayed?.update).toMatchObject({ oneofKind: "newMessage", newMessage: { message: { countsAsUnread: false, sendMode: MessageSendMode.MODE_SILENT } } })
      const liveMessages = live.filter((update) => update.update.oneofKind === "newMessage")
      expect(liveMessages).toHaveLength(2)
      expect(liveMessages.every((update) =>
        update.update.oneofKind === "newMessage" && update.update.newMessage.message?.countsAsUnread === false,
      )).toBe(true)
      expect(push).not.toHaveBeenCalled()
      expect(await DialogsModel.getUnreadCount(s.destination.transcriptChatId, s.speaker.id)).toBe(0)
      expect(await db.select().from(dialogs).where(eq(dialogs.chatId, s.destination.transcriptChatId))).toEqual(beforeDialogs)
      const [chat] = await db.select().from(chats).where(eq(chats.id, s.destination.transcriptChatId))
      expect(chat?.lastMsgId).toBeNull()
      expect(chat?.messageIdCounter).toBe(1)
      await ChatModel.refreshLastMessageId(s.destination.transcriptChatId)
      expect((await db.select().from(chats).where(eq(chats.id, s.destination.transcriptChatId)))[0]?.lastMsgId).toBeNull()
    } finally { delivery.mockRestore(); push.mockRestore() }
  })

  test("generated rows reject public and direct model edits", async () => {
    const s = await fixture("immutable-grid-turn")
    const inserted = await db.transaction((tx) => insertGridTranscriptMessage(tx, { chatId: s.destination.transcriptChatId, actorUserId: s.actor.id, runId: s.run.id, segmentId: s.segment.id, speakerUserId: s.speaker.id, kind: "turn", text: "original" }))
    await expect(editMessage({ peer: peer(s.destination.transcriptChatId), messageId: BigInt(inserted.message.messageId), text: "changed" }, testUtils.functionContext({ userId: s.actor.id }))).rejects.toThrow()
    await expect(MessageModel.editMessage({ chatId: s.destination.transcriptChatId, messageId: inserted.message.messageId, text: "changed" })).rejects.toThrow()
    expect((await MessageModel.getMessage(inserted.message.messageId, s.destination.transcriptChatId)).text).toBe("Transcript · Ben: original")
  })

  test("a finalized deleted turn keeps its dedup tombstone and does not stop capture or push", async () => {
    configureWorker()
    const s = await fixture("deleted-grid-turn")
    const encryptedHuman = encryptMessage("human discussion")
    const human = await MessageModel.insertMessage({ chatId: s.destination.transcriptChatId, fromId: s.actor.id, date: new Date(), textEncrypted: encryptedHuman.encrypted, textIv: encryptedHuman.iv, textTag: encryptedHuman.authTag })
    const response = await s.final()
    const result = await response.json() as { messageId: number }
    await waitForPostCommitHooks()
    expect((await db.select().from(chats).where(eq(chats.id, s.destination.transcriptChatId)))[0]?.lastMsgId).toBe(human.message.messageId)
    await MessageModel.deleteMessages([BigInt(human.message.messageId)], s.destination.transcriptChatId)
    expect((await db.select().from(chats).where(eq(chats.id, s.destination.transcriptChatId)))[0]?.lastMsgId).toBeNull()
    const push = spyOn(Notifications, "sendToUser").mockResolvedValue(undefined)
    try {
      await deleteMessage({ peer: peer(s.destination.transcriptChatId), messageIds: [BigInt(result.messageId)] }, testUtils.functionContext({ userId: s.actor.id }))
      expect(push).not.toHaveBeenCalled()
      expect((await db.select().from(gridTranscriptionRuns).where(eq(gridTranscriptionRuns.id, s.run.id)))[0]?.state).toBe("active")
      expect((await db.select().from(gridTranscriptionSegments).where(eq(gridTranscriptionSegments.id, s.segment.id)))[0]).toMatchObject({ state: "finalized", messageId: result.messageId })
      expect((await s.final()).status).toBe(200)
      expect(await db.select().from(messages).where(eq(messages.chatId, s.destination.transcriptChatId))).toHaveLength(0)
    } finally { push.mockRestore() }
  })

  test("destructive clear discards pending speech even after ordinary Stop, and retry cannot refill history", async () => {
    configureWorker()
    const s = await fixture("cleared-grid-turn")
    await db.update(gridTranscriptionRuns).set({ state: "stopping", interruptionReason: "user_stop", stopRequestedAt: new Date() }).where(eq(gridTranscriptionRuns.id, s.run.id))
    await clearChatHistory({ peer: peer(s.destination.transcriptChatId), keepLastDays: 0, deleteReplyThreads: false }, { currentUserId: s.actor.id })
    expect((await db.select().from(gridTranscriptionSegments).where(eq(gridTranscriptionSegments.id, s.segment.id)))[0]?.state).toBe("discarded")
    expect((await s.final()).status).toBe(200)
    expect(await db.select().from(messages).where(eq(messages.chatId, s.destination.transcriptChatId))).toHaveLength(0)
  })

  test("clearing stopped history permanently retires the destination even when its anchor survives", async () => {
    const s = await fixture("retired-grid-history")
    await db.update(gridTranscriptionRuns).set({ state: "stopped", interruptionReason: "user_stop" }).where(eq(gridTranscriptionRuns.id, s.run.id))
    expect(await db.transaction((tx) => intactDestination(tx, { ...s.run, state: "stopped", interruptionReason: "user_stop" }))).toBe(true)
    await clearChatHistory({ peer: peer(s.destination.transcriptChatId), keepLastDays: 0, deleteReplyThreads: false }, { currentUserId: s.actor.id })
    const [run] = await db.select().from(gridTranscriptionRuns).where(eq(gridTranscriptionRuns.id, s.run.id))
    expect(run).toMatchObject({ state: "stopped", interruptionReason: "history_cleared" })
    expect(await db.select().from(messages).where(and(eq(messages.chatId, s.destination.destinationParentChatId), eq(messages.messageId, s.destination.originalAnchorId)))).toHaveLength(1)
    expect(await db.transaction((tx) => intactDestination(tx, run!))).toBe(false)
  })

  test("same-private participant replacement atomically retires capture and prevents a pending final", async () => {
    const s = await fixture("replaced-grid-access")
    await updateChatVisibility({ chatId: s.destination.destinationParentChatId, isPublic: false, participants: [s.actor.id] }, testUtils.functionContext({ userId: s.actor.id }))
    const [run] = await db.select().from(gridTranscriptionRuns).where(eq(gridTranscriptionRuns.id, s.run.id))
    expect(run?.interruptionReason).toBe("access_revoked")
    expect((await db.select().from(gridTranscriptionSegments).where(eq(gridTranscriptionSegments.id, s.segment.id)))[0]?.state).toBe("discarded")
    expect(await db.transaction((tx) => intactDestination(tx, run!))).toBe(false)
    await expect(getChatHistory({ peerId: peer(s.destination.transcriptChatId) }, testUtils.functionContext({ userId: s.speaker.id }))).rejects.toThrow()
    expect((await s.final()).status).toBe(200)
    expect(await db.select().from(messages).where(eq(messages.chatId, s.destination.transcriptChatId))).toHaveLength(0)
  })

  test("missing room parent recreates a fresh private thread while retired history stays invalid", async () => {
    const s = await fixture("recreated-grid-parent")
    await clearChatHistory({ peer: peer(s.destination.destinationParentChatId), keepLastDays: 0, deleteReplyThreads: true }, { currentUserId: s.actor.id })
    await deleteChat({ peer: peer(s.destination.destinationParentChatId) }, testUtils.functionContext({ userId: s.actor.id }))
    expect((await db.select().from(gridRooms).where(eq(gridRooms.id, s.room.id)))[0]?.roomThreadId).toBe(s.destination.destinationParentChatId)
    const recreated = await db.transaction((tx) => ensureGridRoomThread(tx, { room: s.room, actorUserId: s.actor.id, participantUserIds: [s.actor.id, s.speaker.id] }))
    expect(recreated).not.toBe(s.destination.destinationParentChatId)
    expect((await db.select().from(chats).where(eq(chats.id, recreated)))[0]).toMatchObject({ spaceId: s.space.id, publicThread: false, parentChatId: null })
    expect((await db.select().from(gridRooms).where(eq(gridRooms.id, s.room.id)))[0]?.roomThreadId).toBe(recreated)
    const [retired] = await db.select().from(gridTranscriptionRuns).where(eq(gridTranscriptionRuns.id, s.run.id))
    expect(await db.transaction((tx) => intactDestination(tx, retired!))).toBe(false)
  })

  test("existing public room parent is rejected instead of being enrolled", async () => {
    const s = await fixture("public-grid-parent")
    await updateChatVisibility({ chatId: s.destination.destinationParentChatId, isPublic: true }, testUtils.functionContext({ userId: s.actor.id }))
    await expect(db.transaction((tx) => ensureGridRoomThread(tx, { room: s.room, actorUserId: s.actor.id, participantUserIds: [s.actor.id, s.speaker.id] }))).rejects.toThrow()
    expect((await db.select().from(gridRooms).where(eq(gridRooms.id, s.room.id)))[0]?.roomThreadId).toBe(s.destination.destinationParentChatId)
  })

  test("anchor deletion waits for child mutation before run fence instead of deadlocking a final", async () => {
    configureWorker()
    const s = await fixture("anchor-grid-turn")
    const childLocked = Promise.withResolvers<void>()
    const release = Promise.withResolvers<void>()
    const childOwner = db.transaction(async (tx) => {
      await tx.select().from(chats).where(eq(chats.id, s.destination.transcriptChatId)).for("update")
      childLocked.resolve()
      await release.promise
      await tx.execute(sql`set local lock_timeout = '1s'`)
      await tx.select().from(gridTranscriptionRuns).where(eq(gridTranscriptionRuns.id, s.run.id)).for("update")
    })
    await childLocked.promise
    const deletion = MessageModel.deleteMessages([BigInt(s.destination.originalAnchorId)], s.destination.destinationParentChatId)
    try {
      // The parent lock proves deletion reached its transaction before allowing
      // the child owner to request the run. A NOWAIT probe avoids timed sleeps.
      for (let attempt = 0; attempt < 100; attempt += 1) {
        let held = false
        try { await db.transaction((tx) => tx.select().from(chats).where(eq(chats.id, s.destination.destinationParentChatId)).for("update", { noWait: true })) }
        catch { held = true }
        if (held) break
        if (attempt === 99) throw new Error("Deletion did not acquire parent chat")
      }
      release.resolve()
      await childOwner
      await deletion
      expect((await db.select().from(gridTranscriptionSegments).where(eq(gridTranscriptionSegments.id, s.segment.id)))[0]?.state).toBe("discarded")
      expect((await s.final()).status).toBe(200)
      expect(await db.select().from(messages).where(eq(messages.chatId, s.destination.transcriptChatId))).toHaveLength(0)
    } finally { release.resolve(); await Promise.allSettled([childOwner, deletion]) }
  })

  test("later occupants inherit earlier transcript history through ordinary cumulative parent grants", async () => {
    const s = await fixture("late-grid-reader")
    const reader = await testUtils.createUser("late-grid-reader@example.test")
    await db.insert(members).values({ spaceId: s.space.id, userId: reader.id, role: "member" })
    await db.transaction((tx) => insertGridTranscriptMessage(tx, { chatId: s.destination.transcriptChatId, actorUserId: s.actor.id, runId: s.run.id, segmentId: s.segment.id, speakerUserId: s.speaker.id, kind: "turn", text: "earlier conversation" }))
    await expect(getChatHistory({ peerId: peer(s.destination.transcriptChatId) }, testUtils.functionContext({ userId: reader.id }))).rejects.toThrow()
    await db.transaction((tx) => grantGridTranscriptUsers(tx, { chatIds: [s.destination.destinationParentChatId], userIds: [reader.id] }))
    const history = await getChatHistory({ peerId: peer(s.destination.transcriptChatId) }, testUtils.functionContext({ userId: reader.id }))
    expect(history.messages[0]?.message).toBe("Transcript · Ben: earlier conversation")
  })
})
