import { db } from "@in/server/db"
import { ModelError } from "@in/server/db/models/_errors"
import { MessageModel } from "@in/server/db/models/messages"
import type { UpdateSeqAndDate } from "@in/server/db/models/updates"
import { chats, messages, threadGraphLinks, type DbChat, type DbThreadGraphLink } from "@in/server/db/schema"
import { insertThreadBacklinkSystemMessage } from "@in/server/modules/systemMessages"
import { MessageEntity_Type, type InputPeer, type MessageEntities, type Update } from "@inline-chat/protocol/core"
import { and, eq, inArray, isNull, not, sql } from "drizzle-orm"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { getUpdateGroupFromInputPeer } from "@in/server/modules/updates"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { RealtimeUpdates } from "@in/server/realtime/message"

type GraphScope =
  | {
      type: "space"
      id: number
    }
  | {
      type: "user"
      id: number
    }

type SourceChat = Pick<DbChat, "id" | "spaceId" | "createdBy" | "title">

export type MaterializeReplyThreadInput = {
  replyThread: Pick<DbChat, "id" | "parentChatId" | "parentMessageId">
  parentChat?: SourceChat
  parentMessageGlobalId?: bigint | null
}

type MaterializeThreadLinkInput = {
  sourceChat: SourceChat
  sourceMessageGlobalId: bigint
  sourceMessageId: number
  sourceMessageFromId?: number
  sourceMessageRevision: number
  entityIndex: number
  targetChatId: number
  linkTextHmac?: Buffer | null
  targetTitleHmac?: Buffer | null
}

export type ReplaceMessageThreadLinksInput = {
  sourceChat?: SourceChat
  sourceChatId: number
  sourceMessageGlobalId: bigint
  sourceMessageId: number
  sourceMessageFromId?: number
  sourceMessageRevision: number
  entities?: MessageEntities | null
}

type ResolvedThreadEntity = {
  entityIndex: number
  targetChatId: number
}

type BacklinkMessageRef = {
  chatId: number
  messageId: bigint
}

type DeleteBacklinkMessagesOptions = {
  currentUserId?: number
}

export function graphScopeFromChat(chat: SourceChat): GraphScope {
  if (chat.spaceId !== null) {
    return { type: "space", id: chat.spaceId }
  }

  if (chat.createdBy !== null) {
    return { type: "user", id: chat.createdBy }
  }

  throw new Error(`Cannot resolve graph scope for chat ${chat.id}`)
}

export async function replaceMessageThreadLinks(input: ReplaceMessageThreadLinksInput): Promise<DbThreadGraphLink[]> {
  const entities = resolvedThreadEntities(input.entities)
  if (entities.length === 0) {
    await deactivateRemovedThreadLinks({
      sourceMessageGlobalId: input.sourceMessageGlobalId,
      sourceMessageFromId: input.sourceMessageFromId,
      keepDedupeKeys: [],
    })
    return []
  }

  const sourceChat = input.sourceChat ?? (await getChat(input.sourceChatId))
  if (!sourceChat) {
    return []
  }

  const actorUserId = input.sourceMessageFromId ?? (await getMessageSenderId(input.sourceMessageGlobalId))
  if (actorUserId === null) {
    await deactivateRemovedThreadLinks({
      sourceMessageGlobalId: input.sourceMessageGlobalId,
      keepDedupeKeys: [],
    })
    return []
  }

  const materializedEntities = await materializableThreadEntities({ entities, actorUserId })

  await deactivateRemovedThreadLinks({
    sourceMessageGlobalId: input.sourceMessageGlobalId,
    sourceMessageFromId: actorUserId ?? undefined,
    keepDedupeKeys: materializedEntities.map((entity) =>
      threadLinkDedupeKey(input.sourceMessageGlobalId, entity.entityIndex, entity.targetChatId),
    ),
  })

  const rows: DbThreadGraphLink[] = []

  for (const entity of materializedEntities) {
    const row = await materializeThreadLink({
      sourceChat,
      sourceMessageGlobalId: input.sourceMessageGlobalId,
      sourceMessageId: input.sourceMessageId,
      sourceMessageFromId: actorUserId,
      sourceMessageRevision: input.sourceMessageRevision,
      entityIndex: entity.entityIndex,
      targetChatId: entity.targetChatId,
    })

    if (row) {
      rows.push(row)
    }
  }

  return rows
}

export async function deleteBacklinkMessagesForSourceMessages(input: {
  chatId: number
  messageIds: bigint[]
  currentUserId?: number
}): Promise<void> {
  await deleteBacklinkMessages(await getBacklinkMessagesForSourceMessages(input), {
    currentUserId: input.currentUserId,
  })
}

export async function getBacklinkMessagesForSourceMessages(input: {
  chatId: number
  messageIds: bigint[]
}): Promise<BacklinkMessageRef[]> {
  const messageIds = Array.from(
    new Set(
      input.messageIds
        .map((messageId) => Number(messageId))
        .filter((messageId) => Number.isSafeInteger(messageId) && messageId > 0),
    ),
  )

  if (messageIds.length === 0) {
    return []
  }

  const rows = await db
    .select({
      backlinkChatId: messages.chatId,
      backlinkMessageId: messages.messageId,
    })
    .from(threadGraphLinks)
    .leftJoin(messages, eq(threadGraphLinks.backlinkMessageGlobalId, messages.globalId))
    .where(
      and(
        eq(threadGraphLinks.kind, "thread_link"),
        eq(threadGraphLinks.fromChatId, input.chatId),
        inArray(threadGraphLinks.fromMessageId, messageIds),
        isNull(threadGraphLinks.deletedAt),
      ),
    )

  return backlinkRefsFromRows(rows)
}

export async function getBacklinkMessagesForSourceChat(input: { chatId: number }): Promise<BacklinkMessageRef[]> {
  const rows = await db
    .select({
      backlinkChatId: messages.chatId,
      backlinkMessageId: messages.messageId,
    })
    .from(threadGraphLinks)
    .leftJoin(messages, eq(threadGraphLinks.backlinkMessageGlobalId, messages.globalId))
    .where(
      and(
        eq(threadGraphLinks.kind, "thread_link"),
        eq(threadGraphLinks.fromChatId, input.chatId),
        isNull(threadGraphLinks.deletedAt),
      ),
    )

  return backlinkRefsFromRows(rows)
}

export async function getBacklinkMessagesForClearedChatMessages(input: {
  chatId: number
  beforeDate?: Date
}): Promise<BacklinkMessageRef[]> {
  const filters = [
    eq(threadGraphLinks.kind, "thread_link"),
    eq(threadGraphLinks.fromChatId, input.chatId),
    isNull(threadGraphLinks.deletedAt),
  ]

  if (input.beforeDate) {
    filters.push(sourceMessageBeforeDateFilter(input.beforeDate))
  }

  const rows = await db
    .select({
      backlinkChatId: messages.chatId,
      backlinkMessageId: messages.messageId,
    })
    .from(threadGraphLinks)
    .leftJoin(messages, eq(threadGraphLinks.backlinkMessageGlobalId, messages.globalId))
    .where(and(...filters))

  return backlinkRefsFromRows(rows)
}

export async function getBacklinkMessagesForClearedSpaceMessages(input: {
  spaceId: number
  beforeDate?: Date
}): Promise<BacklinkMessageRef[]> {
  const filters = [
    eq(threadGraphLinks.kind, "thread_link"),
    isNull(threadGraphLinks.deletedAt),
    sql`exists (
      select 1
      from chats source_chat
      where source_chat.id = ${threadGraphLinks.fromChatId}
        and source_chat.space_id = ${input.spaceId}
    )`,
  ]

  if (input.beforeDate) {
    filters.push(sourceMessageBeforeDateFilter(input.beforeDate))
  }

  const rows = await db
    .select({
      backlinkChatId: messages.chatId,
      backlinkMessageId: messages.messageId,
    })
    .from(threadGraphLinks)
    .leftJoin(messages, eq(threadGraphLinks.backlinkMessageGlobalId, messages.globalId))
    .where(and(...filters))

  return backlinkRefsFromRows(rows)
}

export async function materializeReplyThreadLink(
  input: MaterializeReplyThreadInput,
): Promise<DbThreadGraphLink | null> {
  if (input.replyThread.parentChatId === null || input.replyThread.parentMessageId === null) {
    return null
  }

  const parentChat = input.parentChat ?? (await getChat(input.replyThread.parentChatId))
  if (!parentChat) {
    return null
  }

  const parentMessageGlobalId =
    input.parentMessageGlobalId ??
    (await getMessageGlobalId({
      chatId: input.replyThread.parentChatId,
      messageId: input.replyThread.parentMessageId,
    }))

  const scope = graphScopeFromChat(parentChat)
  const now = new Date()

  const [row] = await db
    .insert(threadGraphLinks)
    .values({
      dedupeKey: `reply_thread:${input.replyThread.id}`,
      kind: "reply_thread",
      scopeType: scope.type,
      scopeId: scope.id,
      fromChatId: input.replyThread.parentChatId,
      fromMessageGlobalId: parentMessageGlobalId,
      fromMessageId: input.replyThread.parentMessageId,
      fromMessageRevision: null,
      entityIndex: null,
      toChatId: input.replyThread.id,
      backlinkMessageGlobalId: null,
      deletedAt: null,
      updatedAt: now,
    })
    .onConflictDoUpdate({
      target: threadGraphLinks.dedupeKey,
      set: {
        scopeType: scope.type,
        scopeId: scope.id,
        fromChatId: input.replyThread.parentChatId,
        fromMessageGlobalId: parentMessageGlobalId,
        fromMessageId: input.replyThread.parentMessageId,
        toChatId: input.replyThread.id,
        deletedAt: null,
        updatedAt: now,
      },
    })
    .returning()

  return row ?? null
}

export async function materializeThreadLink(input: MaterializeThreadLinkInput): Promise<DbThreadGraphLink | null> {
  const actorUserId = input.sourceMessageFromId ?? (await getMessageSenderId(input.sourceMessageGlobalId))
  if (!actorUserId) {
    return null
  }

  const targetChat = await getFullChat(input.targetChatId)
  if (!targetChat || !(await canAccessGraphTarget(targetChat, actorUserId))) {
    return null
  }

  const scope = graphScopeFromChat(input.sourceChat)
  const now = new Date()
  const dedupeKey = threadLinkDedupeKey(input.sourceMessageGlobalId, input.entityIndex, input.targetChatId)

  const [row] = await db
    .insert(threadGraphLinks)
    .values({
      dedupeKey,
      kind: "thread_link",
      scopeType: scope.type,
      scopeId: scope.id,
      fromChatId: input.sourceChat.id,
      fromMessageGlobalId: input.sourceMessageGlobalId,
      fromMessageId: input.sourceMessageId,
      fromMessageRevision: input.sourceMessageRevision,
      entityIndex: input.entityIndex,
      toChatId: input.targetChatId,
      linkTextHmac: input.linkTextHmac ?? null,
      targetTitleHmac: input.targetTitleHmac ?? null,
      deletedAt: null,
      updatedAt: now,
    })
    .onConflictDoUpdate({
      target: threadGraphLinks.dedupeKey,
      set: {
        scopeType: scope.type,
        scopeId: scope.id,
        fromChatId: input.sourceChat.id,
        fromMessageGlobalId: input.sourceMessageGlobalId,
        fromMessageId: input.sourceMessageId,
        fromMessageRevision: input.sourceMessageRevision,
        entityIndex: input.entityIndex,
        toChatId: input.targetChatId,
        linkTextHmac: input.linkTextHmac ?? null,
        targetTitleHmac: input.targetTitleHmac ?? null,
        deletedAt: null,
        updatedAt: now,
      },
    })
    .returning()

  if (!row) {
    return null
  }

  if (row.backlinkMessageGlobalId !== null) {
    return row
  }

  return (await createBacklinkMessageForLink(row, { ...input, sourceMessageFromId: actorUserId })) ?? row
}

async function deactivateRemovedThreadLinks(input: {
  sourceMessageGlobalId: bigint
  sourceMessageFromId?: number
  keepDedupeKeys: string[]
}): Promise<void> {
  const filters = [
    eq(threadGraphLinks.kind, "thread_link"),
    eq(threadGraphLinks.fromMessageGlobalId, input.sourceMessageGlobalId),
    isNull(threadGraphLinks.deletedAt),
  ]

  if (input.keepDedupeKeys.length > 0) {
    filters.push(not(inArray(threadGraphLinks.dedupeKey, input.keepDedupeKeys)))
  }

  const rows = await db
    .select({
      id: threadGraphLinks.id,
      backlinkChatId: messages.chatId,
      backlinkMessageId: messages.messageId,
    })
    .from(threadGraphLinks)
    .leftJoin(messages, eq(threadGraphLinks.backlinkMessageGlobalId, messages.globalId))
    .where(and(...filters))

  if (rows.length === 0) {
    return
  }

  await deleteBacklinkMessages(backlinkRefsFromRows(rows), {
    currentUserId: input.sourceMessageFromId,
  })

  await db
    .update(threadGraphLinks)
    .set({
      deletedAt: new Date(),
      backlinkMessageGlobalId: null,
      updatedAt: new Date(),
    })
    .where(inArray(threadGraphLinks.id, rows.map((row) => row.id)))
}

export async function deleteBacklinkMessages(
  rows: BacklinkMessageRef[],
  options: DeleteBacklinkMessagesOptions = {},
): Promise<Update[]> {
  const messageIdsByChatId = new Map<number, bigint[]>()
  const selfUpdates: Update[] = []

  for (const row of rows) {
    const messageIds = messageIdsByChatId.get(row.chatId) ?? []
    messageIds.push(row.messageId)
    messageIdsByChatId.set(row.chatId, messageIds)
  }

  for (const [chatId, messageIds] of messageIdsByChatId) {
    const uniqueMessageIds = Array.from(new Set(messageIds))
    const result = await MessageModel.deleteMessages(uniqueMessageIds, chatId).catch((error) => {
      if (error instanceof ModelError && error.code === ModelError.Codes.MESSAGE_INVALID) {
        return null
      }

      throw error
    })
    if (!result) {
      continue
    }

    if (options.currentUserId !== undefined) {
      selfUpdates.push(
        ...(await pushBacklinkDeleteUpdates({
          chatId,
          messageIds: uniqueMessageIds,
          currentUserId: options.currentUserId,
          update: result.update,
        })),
      )
    }
  }

  return selfUpdates
}

function backlinkRefsFromRows(
  rows: Array<{
    backlinkChatId: number | null
    backlinkMessageId: number | null
  }>,
): BacklinkMessageRef[] {
  const refs: BacklinkMessageRef[] = []

  for (const row of rows) {
    if (row.backlinkChatId === null || row.backlinkMessageId === null) {
      continue
    }

    refs.push({
      chatId: row.backlinkChatId,
      messageId: BigInt(row.backlinkMessageId),
    })
  }

  return refs
}

async function createBacklinkMessageForLink(
  row: DbThreadGraphLink,
  input: MaterializeThreadLinkInput,
): Promise<DbThreadGraphLink | null> {
  const actorUserId = input.sourceMessageFromId ?? (await getMessageSenderId(input.sourceMessageGlobalId))
  if (actorUserId === null) {
    return null
  }

  const backlinkMessage = await insertThreadBacklinkSystemMessage({
    chatId: input.targetChatId,
    actorUserId,
    graphLinkId: row.id,
    sourceChatId: input.sourceChat.id,
    sourceTitle: input.sourceChat.title,
  })

  const [updatedRow] = await db
    .update(threadGraphLinks)
    .set({
      backlinkMessageGlobalId: backlinkMessage.globalId,
      updatedAt: new Date(),
    })
    .where(and(eq(threadGraphLinks.id, row.id), isNull(threadGraphLinks.backlinkMessageGlobalId)))
    .returning()

  if (!updatedRow) {
    await deleteBacklinkMessages(
      [
        {
          chatId: backlinkMessage.chatId,
          messageId: BigInt(backlinkMessage.messageId),
        },
      ],
      { currentUserId: actorUserId },
    )
  }

  return updatedRow ?? null
}

async function pushBacklinkDeleteUpdates(input: {
  chatId: number
  messageIds: bigint[]
  currentUserId: number
  update: UpdateSeqAndDate
}): Promise<Update[]> {
  const inputPeer: InputPeer = {
    type: {
      oneofKind: "chat" as const,
      chat: { chatId: BigInt(input.chatId) },
    },
  }
  const updateGroup = await getUpdateGroupFromInputPeer(inputPeer, { currentUserId: input.currentUserId })
  const selfUpdates: Update[] = []

  for (const userId of updateGroup.userIds) {
    const deleteUpdate: Update = {
      update: {
        oneofKind: "deleteMessages",
        deleteMessages: {
          messageIds: input.messageIds,
          peerId: Encoders.peerFromInputPeer({
            inputPeer,
            currentUserId: input.currentUserId,
          }),
        },
      },
      seq: input.update.seq,
      date: encodeDateStrict(input.update.date),
    }

    RealtimeUpdates.pushToUser(userId, [deleteUpdate])
    if (userId === input.currentUserId) {
      selfUpdates.push(deleteUpdate)
    }
  }

  return selfUpdates
}

function resolvedThreadEntities(entities: MessageEntities | null | undefined): ResolvedThreadEntity[] {
  if (!entities || entities.entities.length === 0) {
    return []
  }

  const result: ResolvedThreadEntity[] = []
  entities.entities.forEach((entity, entityIndex) => {
    if (
      entity?.type !== MessageEntity_Type.THREAD ||
      entity.entity.oneofKind !== "thread" ||
      entity.entity.thread.chatId <= 0n
    ) {
      return
    }

    const chatId = Number(entity.entity.thread.chatId)
    if (!Number.isSafeInteger(chatId) || chatId <= 0) {
      return
    }

    result.push({ entityIndex, targetChatId: chatId })
  })

  return result
}

async function getChat(chatId: number): Promise<SourceChat | null> {
  const [chat] = await db
    .select({
      id: chats.id,
      title: chats.title,
      spaceId: chats.spaceId,
      createdBy: chats.createdBy,
    })
    .from(chats)
    .where(eq(chats.id, chatId))
    .limit(1)

  return chat ?? null
}

async function getFullChat(chatId: number): Promise<DbChat | null> {
  const [chat] = await db.select().from(chats).where(eq(chats.id, chatId)).limit(1)
  return chat ?? null
}

async function getChatsByIds(chatIds: number[]): Promise<Map<number, DbChat>> {
  const uniqueIds = Array.from(new Set(chatIds))
  if (uniqueIds.length === 0) {
    return new Map()
  }

  const rows = await db.select().from(chats).where(inArray(chats.id, uniqueIds))
  return new Map(rows.map((row) => [row.id, row]))
}

async function materializableThreadEntities(input: {
  entities: ResolvedThreadEntity[]
  actorUserId: number
}): Promise<ResolvedThreadEntity[]> {
  const targetChats = await getChatsByIds(input.entities.map((entity) => entity.targetChatId))
  const result: ResolvedThreadEntity[] = []

  for (const entity of input.entities) {
    const targetChat = targetChats.get(entity.targetChatId)
    if (!targetChat || !(await canAccessGraphTarget(targetChat, input.actorUserId))) {
      continue
    }

    result.push(entity)
  }

  return result
}

async function canAccessGraphTarget(chat: DbChat, actorUserId: number): Promise<boolean> {
  try {
    await AccessGuards.ensureChatAccess(chat, actorUserId)
    return true
  } catch {
    return false
  }
}

async function getMessageGlobalId(input: { chatId: number; messageId: number }): Promise<bigint | null> {
  const [message] = await db
    .select({ globalId: messages.globalId })
    .from(messages)
    .where(and(eq(messages.chatId, input.chatId), eq(messages.messageId, input.messageId)))
    .limit(1)

  return message?.globalId ?? null
}

async function getMessageSenderId(messageGlobalId: bigint): Promise<number | null> {
  const [message] = await db
    .select({ fromId: messages.fromId })
    .from(messages)
    .where(eq(messages.globalId, messageGlobalId))
    .limit(1)

  return message?.fromId ?? null
}

function threadLinkDedupeKey(sourceMessageGlobalId: bigint, entityIndex: number, targetChatId: number): string {
  return `thread_link:${sourceMessageGlobalId}:${entityIndex}:${targetChatId}`
}

function sourceMessageBeforeDateFilter(beforeDate: Date) {
  return sql`exists (
    select 1
    from messages source_message
    where source_message.global_id = ${threadGraphLinks.fromMessageGlobalId}
      and source_message."date" < ${beforeDate.toISOString()}
  )`
}
