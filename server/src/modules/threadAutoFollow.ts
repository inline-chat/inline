import { and, eq, inArray, isNull, lt, ne } from "drizzle-orm"
import { MessageEntity_Type, type MessageEntities } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { chats, messages, users, type DbChat } from "@in/server/db/schema"
import { getChatById, getReplyThreadAnchorSenderId, isReplyThread } from "@in/server/modules/subthreads"

export const FRESH_NORMAL_THREAD_MESSAGE_ID_LIMIT = 15

type ThreadFollowChat = Pick<DbChat, "type">
type ThreadAutoFollowChat = Pick<DbChat, "id" | "type" | "parentChatId" | "parentMessageId" | "conversationStarted">

export function canUseThreadFollowMode(chat: ThreadFollowChat): boolean {
  return chat.type === "thread"
}

export function shouldAutoFollowThreadMessage(
  chat: ThreadAutoFollowChat,
  newMessageId: number | null | undefined,
): boolean {
  if (!canUseThreadFollowMode(chat)) {
    return false
  }

  if (isReplyThread(chat)) {
    return true
  }

  return isFreshNormalThreadByNewMessageId(newMessageId)
}

export function isFreshNormalThreadByNewMessageId(newMessageId: number | null | undefined): boolean {
  // Message ids are per-chat, so the newly inserted id is a cheap proxy for thread size.
  // Keep this centralized so we can later swap in a better "fresh thread" signal without changing send flow.
  return (
    typeof newMessageId === "number" &&
    Number.isSafeInteger(newMessageId) &&
    newMessageId > 0 &&
    newMessageId <= FRESH_NORMAL_THREAD_MESSAGE_ID_LIMIT
  )
}

/**
 * Claims the thread's first conversational message. Exactly one sender wins, even when two
 * first messages race; system messages never call this, and deleting the opener later doesn't
 * reopen the claim.
 */
async function claimThreadOpener(chat: ThreadAutoFollowChat): Promise<boolean> {
  if (!canUseThreadFollowMode(chat) || chat.conversationStarted) {
    return false
  }

  const claimed = await db
    .update(chats)
    .set({ conversationStarted: true })
    .where(and(eq(chats.id, chat.id), eq(chats.conversationStarted, false)))
    .returning({ id: chats.id })
  return claimed.length > 0
}

/**
 * Users a message is addressed to for following: the run of mentions it starts with, or every
 * mention when it doesn't start with one. Bot commands run once and never assign a follower.
 */
export function getAddressedUserIds(text: string | undefined, entities: MessageEntities | undefined): Set<number> {
  const addressed = new Set<number>()
  if (!entities) {
    return addressed
  }

  const mentions: { offset: number; end: number; userId: number }[] = []
  for (const entity of entities.entities) {
    if (entity.type !== MessageEntity_Type.MENTION || entity.entity.oneofKind !== "mention") {
      continue
    }
    const userId = Number(entity.entity.mention.userId)
    if (!Number.isSafeInteger(userId) || userId <= 0) {
      continue
    }
    const offset = Number(entity.offset)
    mentions.push({ offset, end: offset + Number(entity.length), userId })
  }
  mentions.sort((a, b) => a.offset - b.offset)

  const source = text ?? ""
  const leading: number[] = []
  let cursor = source.length - source.trimStart().length
  for (const mention of mentions) {
    if (mention.offset !== cursor) {
      break
    }
    leading.push(mention.userId)
    const rest = source.slice(mention.end)
    cursor = mention.end + (rest.length - rest.replace(/^[\s,]+/, "").length)
  }

  for (const userId of leading.length > 0 ? leading : mentions.map((mention) => mention.userId)) {
    addressed.add(userId)
  }
  return addressed
}

/** A message carrying a bot command is a one-off control, not the start of a conversation. */
export function isBotCommandMessage(entities: MessageEntities | undefined): boolean {
  return entities?.entities.some((entity) => entity.type === MessageEntity_Type.BOT_COMMAND) ?? false
}

/**
 * Whether someone else wrote in the chat before this message. In a thread no ordinary message has
 * opened yet, that earlier message was a command, so a bot writing now is answering it.
 */
async function hasEarlierMessageFromOthers(chatId: number, senderId: number, messageId: number): Promise<boolean> {
  const [row] = await db
    .select({ messageId: messages.messageId })
    .from(messages)
    .where(
      and(
        eq(messages.chatId, chatId),
        lt(messages.messageId, messageId),
        ne(messages.fromId, senderId),
        isNull(messages.systemMessageEncrypted),
      ),
    )
    .limit(1)
  return row !== undefined
}

async function getBotUserIds(userIds: Iterable<number>): Promise<Set<number>> {
  const ids = Array.from(new Set(userIds))
  if (ids.length === 0) {
    return new Set()
  }

  const rows = await db
    .select({ id: users.id })
    .from(users)
    .where(and(inArray(users.id, ids), eq(users.bot, true)))
  return new Set(rows.map((row) => row.id))
}

async function getBotDmPeerId(chat: ThreadAutoFollowChat, currentUserId: number): Promise<number | undefined> {
  if (chat.parentChatId == null) {
    return undefined
  }

  const parent = await getChatById(chat.parentChatId)
  if (parent?.type !== "private" || parent.minUserId == null || parent.maxUserId == null) {
    return undefined
  }

  return parent.minUserId === currentUserId ? parent.maxUserId : parent.minUserId
}

/**
 * Who starts following a thread when a message is sent.
 *
 * People keep the fresh-thread heuristic. Bots only enter through the thread's opening message,
 * its first message that isn't a bot command:
 * the bots it addresses follow. With no address, the bot it is implicitly for follows: a reply
 * thread's bot anchor author, the one bot in a thread only it and the sender can see, or a bot DM's
 * peer; otherwise a bot that wrote the opener follows its own thread.
 */
export async function resolveThreadAutoFollowUserIds(input: {
  chat: ThreadAutoFollowChat
  currentUserId: number
  eligibleUserIds: ReadonlySet<number>
  newMessageId: number | null | undefined
  addressedUserIds: ReadonlySet<number>
  /** Known when the entry point authenticated the sender; looked up otherwise. */
  senderIsBot?: boolean | undefined
  /** Commands leave the opener for the thread's first ordinary message. */
  isCommand?: boolean | undefined
}): Promise<number[]> {
  const { chat, currentUserId, eligibleUserIds, newMessageId, addressedUserIds } = input
  const humanRuleApplies = shouldAutoFollowThreadMessage(chat, newMessageId)
  const mayOpen = !input.isCommand && canUseThreadFollowMode(chat) && !chat.conversationStarted
  let senderIsBot = input.senderIsBot
  if (mayOpen && senderIsBot === undefined) {
    senderIsBot = (await getBotUserIds([currentUserId])).has(currentUserId)
  }
  // A bot's answer to a command is part of that command, so it doesn't open the thread either;
  // a bot that writes first, like a thread it starts for its own answer, still does.
  const answersCommand =
    mayOpen && senderIsBot === true && typeof newMessageId === "number" &&
    (await hasEarlierMessageFromOthers(chat.id, currentUserId, newMessageId))
  const isOpener = mayOpen && !answersCommand && (await claimThreadOpener(chat))
  if (!humanRuleApplies && !isOpener) {
    return []
  }

  const anchorSenderId = isReplyThread(chat) ? await getReplyThreadAnchorSenderId(chat) : undefined
  const otherMemberId = eligibleUserIds.size === 2 ? Array.from(eligibleUserIds).find((id) => id !== currentUserId) : undefined
  const botUserIds = await getBotUserIds([
    ...(senderIsBot === undefined ? [currentUserId] : []),
    ...addressedUserIds,
    ...(anchorSenderId !== undefined ? [anchorSenderId] : []),
    ...(otherMemberId !== undefined ? [otherMemberId] : []),
  ])
  senderIsBot ??= botUserIds.has(currentUserId)
  const followUserIds = new Set<number>()

  if (humanRuleApplies) {
    if (!senderIsBot) {
      followUserIds.add(currentUserId)
    }
    // The person whose message a reply thread hangs off keeps following it, also when a
    // bot opened the thread to answer them.
    if (anchorSenderId !== undefined && eligibleUserIds.has(anchorSenderId) && !botUserIds.has(anchorSenderId)) {
      followUserIds.add(anchorSenderId)
    }
  }

  if (isOpener) {
    const openerBots = await resolveOpenerBotFollowers({
      chat,
      currentUserId,
      senderIsBot,
      eligibleUserIds,
      addressedUserIds,
      anchorSenderId,
      otherMemberId,
      botUserIds,
    })
    openerBots.forEach((userId) => followUserIds.add(userId))
  }

  return Array.from(followUserIds)
}

async function resolveOpenerBotFollowers(input: {
  chat: ThreadAutoFollowChat
  currentUserId: number
  senderIsBot: boolean
  eligibleUserIds: ReadonlySet<number>
  addressedUserIds: ReadonlySet<number>
  anchorSenderId: number | undefined
  otherMemberId: number | undefined
  botUserIds: ReadonlySet<number>
}): Promise<number[]> {
  const { chat, currentUserId, senderIsBot, eligibleUserIds, addressedUserIds, anchorSenderId, otherMemberId, botUserIds } =
    input
  if (addressedUserIds.size > 0) {
    return Array.from(addressedUserIds).filter(
      (userId) => userId !== currentUserId && botUserIds.has(userId) && eligibleUserIds.has(userId),
    )
  }

  // A reply thread is addressed to its anchor's author.
  if (
    anchorSenderId !== undefined &&
    anchorSenderId !== currentUserId &&
    botUserIds.has(anchorSenderId) &&
    eligibleUserIds.has(anchorSenderId)
  ) {
    return [anchorSenderId]
  }
  // A thread only the sender and one bot can see is a conversation with that bot, like a DM.
  if (!senderIsBot && otherMemberId !== undefined && botUserIds.has(otherMemberId)) {
    return [otherMemberId]
  }
  // A thread under a bot DM keeps that bot after more people join.
  if (chat.parentChatId != null) {
    const dmPeerId = await getBotDmPeerId(chat, currentUserId)
    if (dmPeerId !== undefined && dmPeerId !== currentUserId && eligibleUserIds.has(dmPeerId)) {
      if ((await getBotUserIds([dmPeerId])).has(dmPeerId)) {
        return [dmPeerId]
      }
    }
  }
  return senderIsBot ? [currentUserId] : []
}
