import { registerPostCommitHook } from "@in/server/db/commitHooks"
import { UpdatesModel } from "@in/server/db/models/updates"
import { chats, chatParticipants, dialogs, gridRooms, members, messages, users, userNotDeleted, UpdateBucket, type DbChat } from "@in/server/db/schema"
import type { Transaction } from "@in/server/db/types"
import { AccessGuardsCache } from "@in/server/modules/authorization/accessGuardsCache"
import { getEffectiveChatAccessUserIds, getRootChatIdsForAccessEvents } from "@in/server/modules/authorization/chatAccessProjection"
import { publishAccessChanged } from "@in/server/modules/cache/cluster"
import { chatTitleFields } from "@in/server/modules/encryption/chatTitleStorage"
import { encryptBinary } from "@in/server/modules/encryption/encryption"
import { publishDurableReference } from "@in/server/modules/internalMessaging/durable"
import { allocateThreadNumber } from "@in/server/modules/threadNumbers"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { pushChatCatchupHintsBestEffort, pushParticipantUserUpdateBestEffort } from "@in/server/modules/updates/participantLiveUpdates"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { GridTranscriptMessageKind, MessageEntities, MessageEntity_Type } from "@inline-chat/protocol/core"
import { and, eq, inArray } from "drizzle-orm"
import { insertGridTranscriptMessage } from "./messages"

/** Called under the Grid mutation/Space owner; caller supplies current roster. */
export async function ensureGridRoomThread(tx: Transaction, input: {
  room: { id: number; spaceId: number; title: string | null; roomThreadId?: number | null }
  actorUserId: number
  participantUserIds: number[]
}): Promise<number> {
  const [room] = await tx.select().from(gridRooms).where(eq(gridRooms.id, input.room.id)).for("update").limit(1)
  if (!room || room.spaceId !== input.room.spaceId) throw RealtimeRpcError.BadRequest()
  let chatId = room.roomThreadId
  if (chatId !== null) {
    const [existing] = await tx.select().from(chats).where(eq(chats.id, chatId)).for("update").limit(1)
    if (existing && !isGridPrivateParent(existing, room.spaceId)) throw RealtimeRpcError.BadRequest()
    if (!existing) chatId = null
  }
  if (chatId === null) {
    const chat = await createPrivateGridChat(tx, {
      spaceId: room.spaceId,
      actorUserId: input.actorUserId,
      title: room.title ?? "Grid room",
    })
    chatId = chat.id
    await tx.update(gridRooms).set({ roomThreadId: chatId }).where(eq(gridRooms.id, room.id))
  }
  await grantGridTranscriptUsers(tx, { chatIds: [chatId], userIds: input.participantUserIds })
  return chatId
}

export async function createGridTranscriptDestination(tx: Transaction, input: {
  roomChatId: number
  spaceId: number
  actorUserId: number
  participantUserIds: number[]
  title: string
  runId: string
}): Promise<{ transcriptChatId: number; destinationParentChatId: number; originalAnchorId: number }> {
  const [parent] = await tx.select().from(chats).where(eq(chats.id, input.roomChatId)).for("update").limit(1)
  if (!parent || !isGridPrivateParent(parent, input.spaceId)) throw RealtimeRpcError.BadRequest()
  await grantGridTranscriptUsers(tx, { chatIds: [parent.id], userIds: input.participantUserIds })
  const anchorText = "Grid transcription"
  const anchor = await insertGridTranscriptMessage(tx, {
    chatId: parent.id,
    actorUserId: input.actorUserId,
    runId: input.runId,
    segmentId: "anchor",
    kind: GridTranscriptMessageKind.GRID_TRANSCRIPT_STARTED,
    text: anchorText,
  })
  const child = await createPrivateGridChat(tx, {
    spaceId: input.spaceId,
    actorUserId: input.actorUserId,
    title: input.title,
    parentChatId: parent.id,
    parentMessageId: anchor.message.messageId,
  })
  const encryptedEntities = encryptBinary(MessageEntities.toBinary({ entities: [{
    type: MessageEntity_Type.THREAD,
    offset: 0n,
    length: BigInt(anchorText.length),
    entity: { oneofKind: "thread", thread: { chatId: BigInt(child.id) } },
  }] }))
  const entitiesFields = {
    entitiesEncrypted: encryptedEntities.encrypted,
    entitiesIv: encryptedEntities.iv,
    entitiesTag: encryptedEntities.authTag,
  }
  await tx.update(messages).set(entitiesFields).where(eq(messages.globalId, anchor.message.globalId))
  // The newMessage commit hook captures this result. Fill navigation before
  // commit so live delivery and history both have the child on their first row.
  Object.assign(anchor.message, entitiesFields)
  // Parent membership supplies cumulative history. Keep only the initiator's
  // closed, hidden child dialog; generated turns cannot open anyone's inbox.
  await tx.insert(dialogs).values({
    chatId: child.id,
    userId: input.actorUserId,
    spaceId: input.spaceId,
    open: false,
    chatListHidden: true,
  }).onConflictDoNothing()
  return { transcriptChatId: child.id, destinationParentChatId: parent.id, originalAnchorId: anchor.message.messageId }
}

export async function insertGridTranscriptContinuationLink(tx: Transaction, input: {
  roomChatId: number
  transcriptChatId: number
  actorUserId: number
  runId: string
  title: string
}): Promise<number> {
  const title = input.title.trim() || "Grid transcription"
  const prefix = "Continue transcript: "
  const result = await insertGridTranscriptMessage(tx, {
    chatId: input.roomChatId,
    actorUserId: input.actorUserId,
    runId: input.runId,
    segmentId: "link",
    kind: GridTranscriptMessageKind.GRID_TRANSCRIPT_LINK,
    text: `${prefix}${title}`,
    entities: { entities: [{
      type: MessageEntity_Type.THREAD,
      offset: BigInt(prefix.length),
      length: BigInt(title.length),
      entity: { oneofKind: "thread", thread: { chatId: BigInt(input.transcriptChatId) } },
    }] },
  })
  return result.message.messageId
}

/**
 * Ordinary cumulative private-parent enrollment; existing dialogs stay closed
 * or archived. Only committed grants update caches/live discovery. Grid/Space
 * authorization is owned by the caller, and membership is rechecked here.
 */
export async function grantGridTranscriptUsers(tx: Transaction, input: { chatIds: number[]; userIds: number[] }): Promise<void> {
  const chatIds = Array.from(new Set(input.chatIds)).sort((a, b) => a - b)
  const userIds = Array.from(new Set(input.userIds)).sort((a, b) => a - b)
  if (chatIds.length === 0 || userIds.length === 0) return
  const chatRows = await tx.select().from(chats).where(inArray(chats.id, chatIds)).orderBy(chats.id).for("update")
  if (chatRows.length !== chatIds.length) throw RealtimeRpcError.ChatIdInvalid()
  const rootIds = await getRootChatIdsForAccessEvents(tx, chatIds)
  const accessBefore = await getEffectiveChatAccessUserIds(tx, rootIds, { userIds })
  for (const chat of chatRows) {
    if (chat.spaceId === null || !isGridPrivateParent(chat, chat.spaceId)) throw RealtimeRpcError.BadRequest()
    const eligible = await tx.select({ userId: members.userId }).from(members)
      .innerJoin(users, eq(users.id, members.userId))
      .where(and(eq(members.spaceId, chat.spaceId), inArray(members.userId, userIds), userNotDeleted()))
    if (eligible.length !== userIds.length) throw RealtimeRpcError.BadRequest()
    const inserted = await tx.insert(chatParticipants).values(userIds.map((userId) => ({ chatId: chat.id, userId })))
      .onConflictDoNothing().returning()
    await tx.insert(dialogs).values(userIds.map((userId) => ({
      chatId: chat.id, userId, spaceId: chat.spaceId, open: false,
    }))).onConflictDoNothing()
    let frontier = chat.updateSeq ?? 0
    for (const participant of inserted) {
      const update = await UpdatesModel.insertUpdate(tx, {
        update: { oneofKind: "participantAdd", participantAdd: {
          chatId: BigInt(chat.id),
          participant: { userId: BigInt(participant.userId), date: encodeDateStrict(participant.date) },
        } },
        bucket: UpdateBucket.Chat,
        entity: { id: chat.id, updateSeq: frontier },
      })
      frontier = update.seq
      await tx.update(chats).set({ updateSeq: update.seq, lastUpdateDate: update.date }).where(eq(chats.id, chat.id))
    }
    if (inserted.length > 0) {
      registerPostCommitHook(tx, Symbol("grid-thread-access"), { run: async () => {
        publishAccessChanged({ kind: "chat", chatId: chat.id })
        for (const participant of inserted) AccessGuardsCache.setChatParticipant(chat.id, participant.userId)
        publishDurableReference({ bucket: { kind: "chat", chatId: chat.id }, frontier })
        await pushChatCatchupHintsBestEffort({ chatId: chat.id, currentUserId: inserted[0]!.userId, updateSeq: frontier })
      } })
    }
  }
  const accessAfter = await getEffectiveChatAccessUserIds(tx, rootIds, { userIds })
  const gained = rootIds.flatMap((chatId) => userIds.filter((userId) =>
    !accessBefore.get(chatId)?.has(userId) && accessAfter.get(chatId)?.has(userId),
  ).map((userId) => ({ chatId, userId })))
  const accessUpdates = await UserBucketUpdates.enqueueMany(gained.map(({ chatId, userId }) => ({
    userId, update: { oneofKind: "userAddedToChat", userAddedToChat: { chatId: BigInt(chatId) } },
  })), { tx })
  if (gained.length > 0) registerPostCommitHook(tx, Symbol("grid-thread-discovery"), { run: async () => {
    await Promise.all(gained.map(({ chatId, userId }, index) => {
      const update = accessUpdates[index]!
      return pushParticipantUserUpdateBestEffort(userId, {
        seq: update.seq, date: encodeDateStrict(update.date),
        update: { oneofKind: "userAddedToChat", userAddedToChat: { chatId: BigInt(chatId) } },
      })
    }))
  } })
}

export function isGridPrivateParent(chat: DbChat, spaceId: number): boolean {
  return chat.type === "thread" && chat.spaceId === spaceId && chat.publicThread === false && chat.parentChatId === null
}

async function createPrivateGridChat(tx: Transaction, input: {
  spaceId: number
  actorUserId: number
  title: string
  parentChatId?: number
  parentMessageId?: number
}): Promise<DbChat> {
  const threadNumber = await allocateThreadNumber(tx, { type: "space", id: input.spaceId })
  const [chat] = await tx.insert(chats).values({
    type: "thread", spaceId: input.spaceId, createdBy: input.actorUserId, publicThread: false,
    ...chatTitleFields(input.title, { spaceId: input.spaceId, createdBy: input.actorUserId }),
    isUntitled: false, threadNumber,
    parentChatId: input.parentChatId ?? null, parentMessageId: input.parentMessageId ?? null,
  }).returning()
  if (!chat) throw RealtimeRpcError.InternalError()
  const update = await UpdatesModel.insertUpdate(tx, {
    update: { oneofKind: "newChat", newChat: { chatId: BigInt(chat.id) } }, bucket: UpdateBucket.Chat, entity: chat,
  })
  const [updated] = await tx.update(chats).set({ updateSeq: update.seq, lastUpdateDate: update.date })
    .where(eq(chats.id, chat.id)).returning()
  if (!updated) throw RealtimeRpcError.InternalError()
  registerPostCommitHook(tx, Symbol("grid-thread-created"), { run: async () => {
    publishDurableReference({ bucket: { kind: "chat", chatId: chat.id }, frontier: update.seq })
  } })
  return updated
}
