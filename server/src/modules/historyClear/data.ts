import { chatParticipants, chats, dialogs, messages, translations } from "@in/server/db/schema"
import type { DbChat } from "@in/server/db/schema"
import type { Transaction } from "@in/server/db/types"
import { and, desc, eq, inArray, isNull, lt, ne, or, sql } from "drizzle-orm"

export type ClearHistoryOptions = {
  beforeDate?: Date
  deleteReplyThreads: boolean
}

export type ClearChatHistoryInput = ClearHistoryOptions & {
  chatId: number
}

export type ClearSpaceHistoryInput = ClearHistoryOptions & {
  spaceId: number
}

export type ClearHistorySideEffects = {
  deletedChatIds: number[]
  orphanedChatIds: number[]
  detachedChatIds: number[]
  deletedChats: ClearHistoryDeletedChat[]
  detachedAccessLosses: ClearHistoryAccessLoss[]
}

export type ClearChatHistoryResult = ClearHistorySideEffects & {
  lastMsgId: number | null
}

export type ClearSpaceHistoryResult = ClearHistorySideEffects

export type ClearHistoryDeletedChat = {
  chat: DbChat
  userIds: number[]
}

export type ClearHistoryAccessLoss = {
  chatId: number
  userIds: number[]
}

export type ClearHistoryHooks = {
  beforeDeleteChats?: (chats: ClearHistoryDeletedChat[]) => Promise<void>
}

type ThreadDepth = {
  chatId: number
  depth: number
}

type ChatIdRow = {
  chatId: number
}

type ChatRecipientRow = {
  chatId: number
  userId: number
}

type DeleteReplyThreadsResult = {
  chatIds: number[]
  chats: ClearHistoryDeletedChat[]
}

type DeleteSpaceReplyThreadsResult = DeleteReplyThreadsResult & {
  detachedChatIds: number[]
  detachedAccessLosses: ClearHistoryAccessLoss[]
}

type DetachReplyThreadsResult = {
  chatIds: number[]
  accessLosses: ClearHistoryAccessLoss[]
}

export async function clearChatHistoryData(
  tx: Transaction,
  input: ClearChatHistoryInput,
  hooks?: ClearHistoryHooks,
): Promise<ClearChatHistoryResult> {
  let deletedChatIds: number[] = []
  let deletedChats: ClearHistoryDeletedChat[] = []
  let orphanedChatIds: number[] = []

  if (input.deleteReplyThreads) {
    const deleted = await deleteReplyThreadsForClearedChatMessages(tx, input.chatId, input.beforeDate, hooks)
    deletedChatIds = deleted.chatIds
    deletedChats = deleted.chats
  } else {
    orphanedChatIds = await orphanReplyThreadsForClearedChatMessages(tx, input.chatId, input.beforeDate)
  }

  await clearChatLastMsgId(tx, input.chatId)
  await deleteTranslationsForClearedChatMessages(tx, input.chatId, input.beforeDate)
  await deleteMessagesForChat(tx, input.chatId, input.beforeDate)

  return {
    lastMsgId: await refreshChatLastMsgId(tx, input.chatId),
    deletedChatIds,
    orphanedChatIds,
    detachedChatIds: [],
    deletedChats,
    detachedAccessLosses: [],
  }
}

export async function clearSpaceHistoryData(
  tx: Transaction,
  input: ClearSpaceHistoryInput,
  hooks?: ClearHistoryHooks,
): Promise<ClearSpaceHistoryResult> {
  const detachedExternalChats = await detachExternalReplyThreadsForClearedSpaceMessages(
    tx,
    input.spaceId,
    input.beforeDate,
  )
  let detachedChatIds = detachedExternalChats.chatIds
  let detachedAccessLosses = detachedExternalChats.accessLosses
  let deletedChatIds: number[] = []
  let deletedChats: ClearHistoryDeletedChat[] = []
  let orphanedChatIds: number[] = []

  if (input.deleteReplyThreads) {
    const deleted = await deleteReplyThreadsForClearedSpaceMessages(tx, input.spaceId, input.beforeDate, hooks)
    deletedChatIds = deleted.chatIds
    deletedChats = deleted.chats
    detachedChatIds = uniqueNumbers([...detachedChatIds, ...deleted.detachedChatIds])
    detachedAccessLosses = uniqueAccessLosses([...detachedAccessLosses, ...deleted.detachedAccessLosses])
  } else {
    orphanedChatIds = await orphanReplyThreadsForClearedSpaceMessages(tx, input.spaceId, input.beforeDate)
  }

  await clearSpaceChatLastMsgIds(tx, input.spaceId)
  await deleteTranslationsForClearedSpaceMessages(tx, input.spaceId, input.beforeDate)
  await deleteMessagesForSpace(tx, input.spaceId, input.beforeDate)
  await refreshSpaceChatLastMsgIds(tx, input.spaceId)

  return {
    deletedChatIds,
    orphanedChatIds,
    detachedChatIds,
    deletedChats,
    detachedAccessLosses,
  }
}

async function clearChatLastMsgId(tx: Transaction, chatId: number): Promise<void> {
  await tx.update(chats).set({ lastMsgId: null }).where(eq(chats.id, chatId))
}

async function clearSpaceChatLastMsgIds(tx: Transaction, spaceId: number): Promise<void> {
  await tx.update(chats).set({ lastMsgId: null }).where(eq(chats.spaceId, spaceId))
}

async function refreshChatLastMsgId(tx: Transaction, chatId: number): Promise<number | null> {
  const [latestMessage] = await tx
    .select({ messageId: messages.messageId })
    .from(messages)
    .where(eq(messages.chatId, chatId))
    .orderBy(desc(messages.messageId))
    .limit(1)

  const lastMsgId = latestMessage?.messageId ?? null
  await tx.update(chats).set({ lastMsgId }).where(eq(chats.id, chatId))
  return lastMsgId
}

async function deleteMessagesForChat(tx: Transaction, chatId: number, beforeDate: Date | undefined): Promise<void> {
  const predicate = beforeDate
    ? and(eq(messages.chatId, chatId), lt(messages.date, beforeDate))
    : eq(messages.chatId, chatId)

  await tx.delete(messages).where(predicate)
}

async function deleteTranslationsForClearedChatMessages(
  tx: Transaction,
  chatId: number,
  beforeDate: Date | undefined,
): Promise<void> {
  if (!beforeDate) {
    await tx.delete(translations).where(eq(translations.chatId, chatId))
    return
  }

  await tx.execute(sql`
    delete from message_translations t
    using messages m
    where t.chat_id = ${chatId}
      and t.chat_id = m.chat_id
      and t.message_id = m.message_id
      and m."date" < ${beforeDate.toISOString()}
  `)
}

async function deleteReplyThreadsForClearedChatMessages(
  tx: Transaction,
  chatId: number,
  beforeDate: Date | undefined,
  hooks: ClearHistoryHooks | undefined,
): Promise<DeleteReplyThreadsResult> {
  const depths = await getChatReplyThreadDepths(tx, chatId, beforeDate)
  if (depths.length === 0) {
    return { chatIds: [], chats: [] }
  }

  const deletedChats = await getDeletedChats(tx, depths.map((row) => row.chatId))
  await hooks?.beforeDeleteChats?.(deletedChats)
  await deleteChatsByDepth(tx, depths)
  return {
    chatIds: depths.map((row) => row.chatId),
    chats: deletedChats,
  }
}

async function getChatReplyThreadDepths(
  tx: Transaction,
  chatId: number,
  beforeDate: Date | undefined,
): Promise<ThreadDepth[]> {
  const parentMessageClause = beforeDate
    ? sql`
        and exists (
          select 1
          from messages m
          where m.chat_id = ${chatId}
            and m.message_id = c.parent_message_id
            ${messageBeforeDateClause(beforeDate)}
        )
      `
    : sql``

  return await tx.execute<ThreadDepth>(sql`
    with recursive threads as (
      select c.id as "chatId", 1::int as "depth"
      from chats c
      where c.parent_chat_id = ${chatId}
        and c.parent_message_id is not null
        ${parentMessageClause}

      union all

      select c.id as "chatId", threads."depth" + 1
      from chats c
      join threads on c.parent_chat_id = threads."chatId"
    )
    select "chatId", max("depth")::int as "depth"
    from threads
    group by "chatId"
    order by "depth" desc, "chatId" desc
  `)
}

async function deleteReplyThreadsForClearedSpaceMessages(
  tx: Transaction,
  spaceId: number,
  beforeDate: Date | undefined,
  hooks: ClearHistoryHooks | undefined,
): Promise<DeleteSpaceReplyThreadsResult> {
  const depths = await getSpaceReplyThreadDepths(tx, spaceId, beforeDate)
  if (depths.length === 0) {
    return { chatIds: [], chats: [], detachedChatIds: [], detachedAccessLosses: [] }
  }

  const chatIds = depths.map((row) => row.chatId)
  const deletedChats = await getDeletedChats(tx, chatIds)
  const detached = await detachExternalReplyThreadsForDeletedSpaceChats(tx, spaceId, chatIds)
  await hooks?.beforeDeleteChats?.(deletedChats)
  await deleteChatsByDepth(tx, depths)
  return {
    chatIds,
    chats: deletedChats,
    detachedChatIds: detached.chatIds,
    detachedAccessLosses: detached.accessLosses,
  }
}

async function getSpaceReplyThreadDepths(
  tx: Transaction,
  spaceId: number,
  beforeDate: Date | undefined,
): Promise<ThreadDepth[]> {
  const parentMessageClause = beforeDate
    ? sql`
        and exists (
          select 1
          from messages m
          where m.chat_id = child.parent_chat_id
            and m.message_id = child.parent_message_id
            ${messageBeforeDateClause(beforeDate)}
        )
      `
    : sql``

  return await tx.execute<ThreadDepth>(sql`
    with recursive threads as (
      select child.id as "chatId", 1::int as "depth"
      from chats child
      where child.space_id = ${spaceId}
        and child.parent_chat_id is not null
        and child.parent_message_id is not null
        and exists (
          select 1
          from chats parent
          where parent.id = child.parent_chat_id
            and parent.space_id = ${spaceId}
        )
        ${parentMessageClause}

      union all

      select c.id as "chatId", threads."depth" + 1
      from chats c
      join threads on c.parent_chat_id = threads."chatId"
      where c.space_id = ${spaceId}
    )
    select "chatId", max("depth")::int as "depth"
    from threads
    group by "chatId"
    order by "depth" desc, "chatId" desc
  `)
}

async function deleteChatsByDepth(tx: Transaction, depths: ThreadDepth[]): Promise<void> {
  for (const { chatId } of depths) {
    await tx
      .update(chats)
      .set({
        parentChatId: null,
        parentMessageId: null,
      })
      .where(eq(chats.parentChatId, chatId))
    await tx.delete(translations).where(eq(translations.chatId, chatId))
    await tx.delete(chatParticipants).where(eq(chatParticipants.chatId, chatId))
    await tx.delete(dialogs).where(eq(dialogs.chatId, chatId))
    await tx.delete(chats).where(eq(chats.id, chatId))
  }
}

async function getDeletedChats(tx: Transaction, chatIds: number[]): Promise<ClearHistoryDeletedChat[]> {
  const uniqueChatIds = Array.from(new Set(chatIds))
  if (uniqueChatIds.length === 0) {
    return []
  }

  const chatRows = await tx.select().from(chats).where(inArray(chats.id, uniqueChatIds))
  const recipientRows = await getChatRecipientRows(tx, uniqueChatIds)

  const chatsById = new Map(chatRows.map((chat) => [chat.id, chat]))
  const userIdsByChatId = new Map<number, number[]>()
  for (const row of recipientRows) {
    const userIds = userIdsByChatId.get(row.chatId) ?? []
    userIds.push(row.userId)
    userIdsByChatId.set(row.chatId, userIds)
  }

  return uniqueChatIds
    .map((chatId) => {
      const chat = chatsById.get(chatId)
      if (!chat) {
        return undefined
      }

      return {
        chat,
        userIds: userIdsByChatId.get(chatId) ?? [],
      }
    })
    .filter((row): row is ClearHistoryDeletedChat => Boolean(row))
}

async function getChatRecipientRows(tx: Transaction, chatIds: number[]): Promise<ChatRecipientRow[]> {
  if (chatIds.length === 0) {
    return []
  }

  const chatIdList = sql.join(chatIds, sql`, `)

  return await tx.execute<ChatRecipientRow>(sql`
    with recursive ancestors as (
      select
        c.id as "chatId",
        c.id as "ancestorId",
        c.parent_chat_id as "parentChatId",
        0::int as "depth"
      from chats c
      where c.id in (${chatIdList})

      union all

      select
        ancestors."chatId",
        parent.id as "ancestorId",
        parent.parent_chat_id as "parentChatId",
        ancestors."depth" + 1
      from ancestors
      join chats parent on parent.id = ancestors."parentChatId"
    ),
    roots as (
      select distinct on ("chatId")
        "chatId",
        "ancestorId" as "rootChatId"
      from ancestors
      order by "chatId", "depth" desc
    ),
    access as (
      select
        cp.chat_id as "chatId",
        cp.user_id as "userId"
      from chat_participants cp
      where cp.chat_id in (${chatIdList})

      union

      select
        r."chatId",
        root.min_user_id as "userId"
      from roots r
      join chats root on root.id = r."rootChatId"
      where root.type = 'private'
        and root.min_user_id is not null

      union

      select
        r."chatId",
        root.max_user_id as "userId"
      from roots r
      join chats root on root.id = r."rootChatId"
      where root.type = 'private'
        and root.max_user_id is not null

      union

      select
        r."chatId",
        m.user_id as "userId"
      from roots r
      join chats root on root.id = r."rootChatId"
      join members m on m.space_id = root.space_id
      where root.type = 'thread'
        and root.space_id is not null
        and root.public_thread is true
        and m.can_access_public_chats is true

      union

      select
        r."chatId",
        cp.user_id as "userId"
      from roots r
      join chats root on root.id = r."rootChatId"
      join chat_participants cp on cp.chat_id = root.id
      where root.type = 'thread'
        and (
          root.space_id is null
          or root.public_thread is distinct from true
        )
    )
    select distinct
      access."chatId",
      access."userId"
    from access
    join users u on u.id = access."userId"
    where u.deleted is distinct from true
    order by access."chatId", access."userId"
  `)
}

async function orphanReplyThreadsForClearedChatMessages(
  tx: Transaction,
  chatId: number,
  beforeDate: Date | undefined,
): Promise<number[]> {
  const parentMessageClause = beforeDate
    ? sql`
        and exists (
          select 1
          from messages m
          where m.chat_id = ${chatId}
            and m.message_id = child.parent_message_id
            ${messageBeforeDateClause(beforeDate)}
        )
      `
    : sql``

  const rows = await tx.execute<ChatIdRow>(sql`
    update chats child
    set parent_message_id = null
    where child.parent_chat_id = ${chatId}
      and child.parent_message_id is not null
      ${parentMessageClause}
    returning child.id as "chatId"
  `)

  return rows.map((row) => row.chatId)
}

async function orphanReplyThreadsForClearedSpaceMessages(
  tx: Transaction,
  spaceId: number,
  beforeDate: Date | undefined,
): Promise<number[]> {
  const parentMessageClause = beforeDate
    ? sql`
        and exists (
          select 1
          from messages m
          where m.chat_id = child.parent_chat_id
            and m.message_id = child.parent_message_id
            ${messageBeforeDateClause(beforeDate)}
        )
      `
    : sql``

  const rows = await tx.execute<ChatIdRow>(sql`
    update chats child
    set parent_message_id = null
    where child.space_id = ${spaceId}
      and child.parent_message_id is not null
      and exists (
        select 1
        from chats parent
          where parent.id = child.parent_chat_id
            and parent.space_id = ${spaceId}
      )
      ${parentMessageClause}
    returning child.id as "chatId"
  `)

  return rows.map((row) => row.chatId)
}

async function detachExternalReplyThreadsForClearedSpaceMessages(
  tx: Transaction,
  spaceId: number,
  beforeDate: Date | undefined,
): Promise<DetachReplyThreadsResult> {
  const parentMessageClause = beforeDate
    ? sql`
        and exists (
          select 1
          from messages m
          where m.chat_id = child.parent_chat_id
            and m.message_id = child.parent_message_id
            ${messageBeforeDateClause(beforeDate)}
        )
      `
    : sql``

  const rows = await tx.execute<ChatIdRow>(sql`
    select child.id as "chatId"
    from chats child
    where child.parent_chat_id is not null
      and child.parent_message_id is not null
      and child.space_id is distinct from ${spaceId}
      and exists (
        select 1
        from chats parent
        where parent.id = child.parent_chat_id
          and parent.space_id = ${spaceId}
      )
      ${parentMessageClause}
    for update of child
  `)

  const chatIds = rows.map((row) => row.chatId)
  if (chatIds.length === 0) {
    return { chatIds: [], accessLosses: [] }
  }

  const beforeAccess = await getChatAccessMap(tx, chatIds)

  await tx
    .update(chats)
    .set({
      parentChatId: null,
      parentMessageId: null,
    })
    .where(inArray(chats.id, chatIds))

  const afterAccess = await getChatAccessMap(tx, chatIds)

  return {
    chatIds,
    accessLosses: getAccessLosses(chatIds, beforeAccess, afterAccess),
  }
}

async function detachExternalReplyThreadsForDeletedSpaceChats(
  tx: Transaction,
  spaceId: number,
  deletedChatIds: number[],
): Promise<DetachReplyThreadsResult> {
  if (deletedChatIds.length === 0) {
    return { chatIds: [], accessLosses: [] }
  }

  const rows = await tx
    .select({ chatId: chats.id })
    .from(chats)
    .where(
      and(
        inArray(chats.parentChatId, deletedChatIds),
        or(isNull(chats.spaceId), ne(chats.spaceId, spaceId)),
      ),
    )
    .for("update")

  const chatIds = rows.map((row) => row.chatId)
  if (chatIds.length === 0) {
    return { chatIds: [], accessLosses: [] }
  }

  const beforeAccess = await getChatAccessMap(tx, chatIds)

  await tx
    .update(chats)
    .set({
      parentChatId: null,
      parentMessageId: null,
    })
    .where(inArray(chats.id, chatIds))

  const afterAccess = await getChatAccessMap(tx, chatIds)

  return {
    chatIds,
    accessLosses: getAccessLosses(chatIds, beforeAccess, afterAccess),
  }
}

async function getChatAccessMap(tx: Transaction, chatIds: number[]): Promise<Map<number, Set<number>>> {
  const rows = await getChatRecipientRows(tx, chatIds)
  const result = new Map<number, Set<number>>()

  for (const chatId of chatIds) {
    result.set(chatId, new Set())
  }

  for (const row of rows) {
    const userIds = result.get(row.chatId)
    if (userIds) {
      userIds.add(row.userId)
    }
  }

  return result
}

function getAccessLosses(
  chatIds: number[],
  beforeAccess: Map<number, Set<number>>,
  afterAccess: Map<number, Set<number>>,
): ClearHistoryAccessLoss[] {
  const losses: ClearHistoryAccessLoss[] = []

  for (const chatId of chatIds) {
    const beforeUserIds = beforeAccess.get(chatId) ?? new Set<number>()
    const afterUserIds = afterAccess.get(chatId) ?? new Set<number>()
    const removedUserIds = Array.from(beforeUserIds).filter((userId) => !afterUserIds.has(userId))

    if (removedUserIds.length > 0) {
      losses.push({
        chatId,
        userIds: removedUserIds,
      })
    }
  }

  return losses
}

function uniqueNumbers(values: number[]): number[] {
  return Array.from(new Set(values))
}

function uniqueAccessLosses(losses: ClearHistoryAccessLoss[]): ClearHistoryAccessLoss[] {
  const userIdsByChatId = new Map<number, Set<number>>()

  for (const loss of losses) {
    const userIds = userIdsByChatId.get(loss.chatId) ?? new Set<number>()
    for (const userId of loss.userIds) {
      userIds.add(userId)
    }
    userIdsByChatId.set(loss.chatId, userIds)
  }

  return Array.from(userIdsByChatId, ([chatId, userIds]) => ({
    chatId,
    userIds: Array.from(userIds),
  }))
}

async function deleteTranslationsForClearedSpaceMessages(
  tx: Transaction,
  spaceId: number,
  beforeDate: Date | undefined,
): Promise<void> {
  const dateClause = messageBeforeDateClause(beforeDate)

  await tx.execute(sql`
    delete from message_translations t
    using messages m, chats c
    where t.chat_id = m.chat_id
      and t.message_id = m.message_id
      and m.chat_id = c.id
      and c.space_id = ${spaceId}
      ${dateClause}
  `)
}

async function deleteMessagesForSpace(tx: Transaction, spaceId: number, beforeDate: Date | undefined): Promise<void> {
  const dateClause = messageBeforeDateClause(beforeDate)

  await tx.execute(sql`
    delete from messages m
    using chats c
    where m.chat_id = c.id
      and c.space_id = ${spaceId}
      ${dateClause}
  `)
}

async function refreshSpaceChatLastMsgIds(tx: Transaction, spaceId: number): Promise<void> {
  await tx.execute(sql`
    update chats c
    set last_msg_id = (
      select m.message_id
      from messages m
      where m.chat_id = c.id
      order by m.message_id desc
      limit 1
    )
    where c.space_id = ${spaceId}
  `)
}

function messageBeforeDateClause(beforeDate: Date | undefined) {
  return beforeDate ? sql`and m."date" < ${beforeDate.toISOString()}` : sql``
}
