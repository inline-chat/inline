import { DEFAULT_GROUP_HISTORY_LIMIT } from "../sdk-runtime-compat.js"
import type { OpenClawConfig } from "openclaw/plugin-sdk/core"
import { DialogFollowMode, InlineSdkClient, Method, type Message } from "@inline-chat/realtime-sdk"
import { summarizeInlineMessageContent } from "./message-content.js"
import { InlineSenderProfileCache } from "./sender-profile-cache.js"
import { loadInlineReplyThreadAnchorMessage, loadInlineReplyThreadMetadata } from "./reply-threads.js"
import { rememberInlineReplyThreadRoute, type InlineReplyThreadRouteRecord } from "./thread-routes.js"
import { INLINE_JOIN_MENTION_LOOKBACK_SECONDS } from "./thread-freshness.js"
import { CHANNEL_ID, buildChatPeer } from "./monitor-shared.js"
import { buildInlineInboundBodyText } from "./monitor-media.js"

export type CachedChatInfo = {
  kind: "direct" | "group"
  title: string | null
  peerUserId?: bigint | null
  parentChatId?: bigint | null
  parentMessageId?: bigint | null
  lastMsgId?: bigint | null
  dialogFollowMode?: DialogFollowMode | null
}

type SenderProfileLookup = Pick<InlineSenderProfileCache, "get">

type HistoryContext = {
  historyText: string | null
  attachmentText: string | null
  entityText: string | null
  inboundHistory: InlinePendingHistoryEntry[]
  repliedToBot: boolean
  replyToSenderId: string | null
}

export type InlinePendingHistoryEntry = {
  sender: string
  body: string
  timestamp?: number
  messageId?: string
}

type InlineChannelStructuredContextEntry = {
  label: string
  source: typeof CHANNEL_ID
  type: string
  payload: Record<string, unknown>
}

export type InlineReplyThreadContext = {
  childChatId: bigint
  parentChatId: bigint
  parentChatKind: CachedChatInfo["kind"]
  parentPeerUserId?: bigint | null
  parentChatTitle: string | null
  parentMessageId: bigint | null
  threadLabel: string | null
  anchorMessage: Message | null
}

type InlineHistoryEntryPayload = {
  line: string | null
  attachmentLine: string | null
  entityLine: string | null
  inboundEntry: InlinePendingHistoryEntry | null
}

const DEFAULT_DM_HISTORY_LIMIT = 6
const HISTORY_LINE_MAX_CHARS = 280
const REPLY_THREAD_LABEL_MAX_CHARS = 72
const URL_LIKE_PATTERN = /https?:\/\/\S+/i
const BOT_MESSAGE_CACHE_LIMIT = 500
const REACTION_TARGET_LOOKUP_LIMIT = 8
export const REPLY_TARGET_LOOKUP_LIMIT = 8
const ATTACHMENT_CONTEXT_LIMIT = 6
const GET_MESSAGES_METHOD =
  typeof (Method as Record<string, unknown>).GET_MESSAGES === "number" &&
  Number.isInteger((Method as Record<string, unknown>).GET_MESSAGES) &&
  ((Method as Record<string, unknown>).GET_MESSAGES as number) > 0
    ? ((Method as Record<string, unknown>).GET_MESSAGES as Method)
    : null

export async function resolveChatInfo(
  client: InlineSdkClient,
  cache: Map<bigint, CachedChatInfo>,
  chatId: bigint,
): Promise<CachedChatInfo> {
  const existing = cache.get(chatId)
  if (existing) return existing

  const result = await client.getChat({ chatId })
  const peerType = result.peer?.type
  const kind: CachedChatInfo["kind"] = peerType?.oneofKind === "user" ? "direct" : "group"
  const peerUserId = peerType?.oneofKind === "user" ? peerType.user.userId : null
  const title = result.title?.trim() || null
  const info: CachedChatInfo = {
    kind,
    title,
    ...(peerUserId != null ? { peerUserId } : {}),
    ...(result.parentChatId != null ? { parentChatId: result.parentChatId } : {}),
    ...(result.parentMessageId != null ? { parentMessageId: result.parentMessageId } : {}),
    ...(result.lastMsgId != null ? { lastMsgId: result.lastMsgId } : {}),
    ...(result.dialogFollowMode != null ? { dialogFollowMode: result.dialogFollowMode } : {}),
  }
  cache.set(chatId, info)
  return info
}

export function rewriteNumericMentionsToUsernames(text: string, senderProfilesById: SenderProfileLookup): string {
  if (!text.includes("@")) return text
  return text.replace(/(^|[^\w])@([0-9]+)\b/g, (full, prefix: string, userId: string) => {
    const username = senderProfilesById.get(userId)?.username
    if (!username) return full
    return `${prefix}@${username}`
  })
}

function rememberBotMessageId(cache: Map<string, string[]>, chatId: bigint, messageId: bigint): void {
  const key = String(chatId)
  const list = cache.get(key) ?? []
  const nextId = String(messageId)
  if (!list.includes(nextId)) list.push(nextId)
  if (list.length > BOT_MESSAGE_CACHE_LIMIT) {
    list.splice(0, list.length - BOT_MESSAGE_CACHE_LIMIT)
  }
  cache.set(key, list)
}

export function rememberInlineBotDelivery(params: {
  botMessageIdsByChat: Map<string, string[]>
  chatId: bigint
  messageId: bigint
  accountId: string
  agentId: string
  inlineAgentId?: string
  replyThreadContext?: InlineReplyThreadContext | null
}): void {
  rememberBotMessageId(params.botMessageIdsByChat, params.chatId, params.messageId)
  if (!params.replyThreadContext || params.chatId !== params.replyThreadContext.childChatId) return
  rememberInlineReplyThreadRoute({
    accountId: params.accountId,
    parentChatId: params.replyThreadContext.parentChatId,
    threadId: params.replyThreadContext.childChatId,
    parentMessageId: params.replyThreadContext.parentMessageId,
    threadLabel: params.replyThreadContext.threadLabel,
    agentId: params.agentId,
    ...(params.inlineAgentId ? { inlineAgentId: params.inlineAgentId } : {}),
  })
}

function hasBotMessageId(cache: Map<string, string[]>, chatId: bigint, messageId: bigint): boolean {
  const key = String(chatId)
  return (cache.get(key) ?? []).includes(String(messageId))
}

function rememberBotMessagesFromList(params: {
  messages: Message[]
  meId: bigint
  chatId: bigint
  botMessageIdsByChat: Map<string, string[]>
}): void {
  for (const item of params.messages) {
    if (item.fromId === params.meId) {
      rememberBotMessageId(params.botMessageIdsByChat, params.chatId, item.id)
    }
  }
}

async function loadChatHistoryMessages(params: {
  client: InlineSdkClient
  chatId: bigint
  limit: number
  offsetId?: bigint
}): Promise<Message[] | null> {
  const result = await params.client.invokeRaw(Method.GET_CHAT_HISTORY, {
    oneofKind: "getChatHistory",
    getChatHistory: {
      peerId: buildChatPeer(params.chatId),
      ...(params.offsetId != null ? { offsetId: params.offsetId } : {}),
      limit: params.limit,
    },
  })
  if (result.oneofKind !== "getChatHistory") {
    return null
  }
  return result.getChatHistory.messages ?? []
}

export async function loadInlineJoinWindowMessages(params: {
  client: InlineSdkClient
  chatId: bigint
  participantDate: bigint
}): Promise<Message[] | null> {
  const cutoff = params.participantDate - INLINE_JOIN_MENTION_LOOKBACK_SECONDS
  const messages = new Map<string, Message>()
  let offsetId: bigint | undefined

  for (;;) {
    const page = await loadChatHistoryMessages({
      client: params.client,
      chatId: params.chatId,
      limit: 100,
      ...(offsetId != null ? { offsetId } : {}),
    })
    if (!page) return null
    if (page.length === 0) break

    let oldest: Message | undefined
    let added = 0
    for (const message of page) {
      const key = `${String(message.id)}:${String(message.date ?? 0n)}`
      if (!messages.has(key)) {
        messages.set(key, message)
        added += 1
      }
      if (!oldest || message.date < oldest.date || (message.date === oldest.date && message.id < oldest.id)) {
        oldest = message
      }
    }
    if (!oldest || oldest.date < cutoff || page.length < 100 || added === 0) break
    offsetId = oldest.id
  }

  return [...messages.values()]
}

export async function findChatMessageById(params: {
  client: InlineSdkClient
  chatId: bigint
  messageId: bigint
  limit: number
  meId: bigint
  botMessageIdsByChat: Map<string, string[]>
}): Promise<Message | null> {
  const directResult =
    GET_MESSAGES_METHOD == null
      ? null
      : await params.client
          .invokeRaw(GET_MESSAGES_METHOD, {
            oneofKind: "getMessages",
            getMessages: {
              peerId: buildChatPeer(params.chatId),
              messageIds: [params.messageId],
            },
          })
          .catch(() => null)
  if (directResult?.oneofKind === "getMessages") {
    const directMessages = directResult.getMessages.messages ?? []
    rememberBotMessagesFromList({
      messages: directMessages,
      meId: params.meId,
      chatId: params.chatId,
      botMessageIdsByChat: params.botMessageIdsByChat,
    })
    const directTarget = directMessages.find((item) => item.id === params.messageId) ?? null
    if (directTarget) {
      return directTarget
    }
  }

  // Compatibility fallback for older servers without GET_MESSAGES.
  const historyMessages = await loadChatHistoryMessages({
    client: params.client,
    chatId: params.chatId,
    offsetId: params.messageId + 1n,
    limit: params.limit,
  })
  if (!historyMessages) {
    return null
  }

  rememberBotMessagesFromList({
    messages: historyMessages,
    meId: params.meId,
    chatId: params.chatId,
    botMessageIdsByChat: params.botMessageIdsByChat,
  })

  return historyMessages.find((item) => item.id === params.messageId) ?? null
}

export async function isReactionTargetBotMessage(params: {
  client: InlineSdkClient
  chatId: bigint
  messageId: bigint
  meId: bigint
  botMessageIdsByChat: Map<string, string[]>
}): Promise<boolean> {
  const target = await findChatMessageById({
    client: params.client,
    chatId: params.chatId,
    messageId: params.messageId,
    limit: REACTION_TARGET_LOOKUP_LIMIT,
    meId: params.meId,
    botMessageIdsByChat: params.botMessageIdsByChat,
  })
  if (!target) {
    return hasBotMessageId(params.botMessageIdsByChat, params.chatId, params.messageId)
  }
  return target.fromId === params.meId
}

export function normalizeHistoryText(raw: string | undefined): string {
  const compact = (raw ?? "").replace(/\s+/g, " ").trim()
  if (!compact) return ""
  if (compact.length <= HISTORY_LINE_MAX_CHARS) return compact
  // Keep full URLs for media/file discoverability in history context.
  if (URL_LIKE_PATTERN.test(compact)) return compact
  return `${compact.slice(0, HISTORY_LINE_MAX_CHARS - 1)}…`
}

export function buildInlineReplyThreadLabel(params: {
  title: string | null | undefined
  anchorMessage: Message | null | undefined
}): string | null {
  const title = params.title?.trim()
  if (title) return title

  if (!params.anchorMessage) return "Re: Message"
  const anchorText = buildInlineInboundBodyText(summarizeInlineMessageContent(params.anchorMessage))
    .replace(/\s+/g, " ")
    .trim()
  if (!anchorText) return "Re: Message"

  return `Re: ${anchorText.slice(0, REPLY_THREAD_LABEL_MAX_CHARS)}`
}

function resolveHistorySenderLabel(params: {
  senderId: bigint
  meId: bigint
  senderProfilesById: SenderProfileLookup
}): string {
  if (params.senderId === params.meId) return "assistant"
  const senderId = String(params.senderId)
  const profile = params.senderProfilesById.get(senderId)
  return resolveInlineSenderLabel({
    senderId,
    senderName: profile?.name,
    senderUsername: profile?.username,
  })
}

export function resolveInlineSenderLabel(params: {
  senderId: string
  senderName?: string | null | undefined
  senderUsername?: string | null | undefined
}): string {
  const senderId = params.senderId.trim()
  const name = params.senderName?.trim()
  const usernameRaw = params.senderUsername?.trim().replace(/^@+/, "")
  const username = usernameRaw ? `@${usernameRaw}` : undefined

  let label = name
  if (name && username) {
    label = `${name} (${username})`
  } else if (!name && username) {
    label = username
  }

  const id = senderId ? `id:${senderId}` : undefined
  const fallback = senderId ? `user:${senderId}` : undefined
  if (label && id) return `${label} ${id}`
  if (label) return label
  return fallback ?? "id:unknown"
}

export function resolveInlineDirectSenderName(params: {
  profileName: string | null | undefined
  chatTitle: string | null | undefined
  senderId: string
}): string | undefined {
  const profileName = params.profileName?.trim()
  if (profileName) return profileName
  const chatTitle = params.chatTitle?.trim()
  if (!chatTitle || chatTitle === `user:${params.senderId}` || chatTitle === params.senderId) return undefined
  return chatTitle
}

export function resolveInlineConversationLabel(params: {
  isGroup: boolean
  groupTitle?: string | null
  groupId: string
  senderLabel: string
}): string {
  if (!params.isGroup) return params.senderLabel
  const title = params.groupTitle?.trim()
  return title ? `${title} id:${params.groupId}` : `group:${params.groupId}`
}

export function resolveHistoryLimit(params: {
  cfg: OpenClawConfig
  isGroup: boolean
  historyLimit: number | undefined
  dmHistoryLimit: number | undefined
}): number {
  if (params.isGroup) {
    return Math.max(0, params.historyLimit ?? params.cfg.messages?.groupChat?.historyLimit ?? DEFAULT_GROUP_HISTORY_LIMIT)
  }
  return Math.max(0, params.dmHistoryLimit ?? params.historyLimit ?? DEFAULT_DM_HISTORY_LIMIT)
}

function historyEntryDedupeKey(entry: InlinePendingHistoryEntry): string {
  if (entry.messageId) return `id:${entry.messageId}:ts:${entry.timestamp ?? "unknown"}`
  return `ts:${entry.timestamp ?? "unknown"}:${entry.sender}:${entry.body}`
}

export function mergeInboundHistoryEntries(params: {
  historyContextEntries: InlinePendingHistoryEntry[]
  pendingEntries: InlinePendingHistoryEntry[]
  limit: number
}): Array<{ sender: string; body: string; timestamp?: number }> {
  if (params.limit <= 0) return []

  const deduped: InlinePendingHistoryEntry[] = []
  const seen = new Set<string>()
  for (const entry of [...params.historyContextEntries, ...params.pendingEntries]) {
    const key = historyEntryDedupeKey(entry)
    if (seen.has(key)) continue
    seen.add(key)
    deduped.push(entry)
  }

  return deduped.slice(-params.limit).map((entry) => ({
    sender: entry.sender,
    body: entry.body,
    ...(entry.timestamp != null ? { timestamp: entry.timestamp } : {}),
  }))
}

function buildInlineHistoryEntryPayload(params: {
  message: Message
  senderProfilesById: SenderProfileLookup
  meId: bigint
  syntheticMessageId?: string
}): InlineHistoryEntryPayload {
  const content = summarizeInlineMessageContent(params.message)
  const text = normalizeHistoryText(content.text)
  if (!text) {
    return {
      line: null,
      attachmentLine: null,
      entityLine: null,
      inboundEntry: null,
    }
  }

  const label = resolveHistorySenderLabel({
    senderId: params.message.fromId,
    meId: params.meId,
    senderProfilesById: params.senderProfilesById,
  })
  const replySuffix = params.message.replyToMsgId != null ? ` ->${String(params.message.replyToMsgId)}` : ""
  const messageId = params.syntheticMessageId ?? String(params.message.id)
  // A top-level message the bot answered in a reply thread still looks unanswered
  // in the parent chat's history, so say where its answer went.
  const threadNote = params.message.replies?.recentReplierUserIds?.some((id) => id === params.meId)
    ? " [you answered this in its reply thread]"
    : ""
  const attachmentText = normalizeHistoryText(content.attachmentText)
  const entityText = normalizeHistoryText(content.entityText)

  return {
    line: `#${String(params.message.id)}${replySuffix} ${label}: ${text}${threadNote}`,
    attachmentLine: attachmentText ? `#${String(params.message.id)}${replySuffix} ${label}: ${attachmentText}` : null,
    entityLine: entityText ? `#${String(params.message.id)}${replySuffix} ${label}: ${entityText}` : null,
    inboundEntry: {
      sender: label,
      body: `${text}${threadNote}`,
      ...(params.message.date != null ? { timestamp: Number(params.message.date) * 1000 } : {}),
      messageId,
    },
  }
}

function appendInlineHistoryEntry(
  target: {
    lines: string[]
    attachmentLines: string[]
    entityLines: string[]
    inboundHistory: InlinePendingHistoryEntry[]
  },
  entry: InlineHistoryEntryPayload,
): void {
  if (!entry.inboundEntry || !entry.line) return
  target.inboundHistory.push(entry.inboundEntry)
  target.lines.push(entry.line)
  if (entry.attachmentLine) {
    target.attachmentLines.push(entry.attachmentLine)
  }
  if (entry.entityLine) {
    target.entityLines.push(entry.entityLine)
  }
}

function prependLabeledHistoryLine(params: {
  existing: string | null
  heading: string
  line: string | null
}): string | null {
  if (!params.line) return params.existing
  const prefix = `${params.heading}\n`
  const existingBody = params.existing?.startsWith(prefix) ? params.existing.slice(prefix.length) : params.existing
  return existingBody ? `${prefix}${params.line}\n${existingBody}` : `${prefix}${params.line}`
}

function stripLabeledHistoryHeading(text: string | null, heading: string): string | null {
  if (!text) return null
  const prefix = `${heading}\n`
  const body = text.startsWith(prefix) ? text.slice(prefix.length) : text
  return body.trim() || null
}

function prependLabeledHistoryBlock(params: {
  existing: string | null
  heading: string
  block: string | null
}): string | null {
  const block = stripLabeledHistoryHeading(params.block, params.heading)
  if (!block) return params.existing
  const prefix = `${params.heading}\n`
  const existingBody = stripLabeledHistoryHeading(params.existing, params.heading)
  return existingBody ? `${prefix}${block}\n${existingBody}` : `${prefix}${block}`
}

export function prependInlineReplyThreadAnchor(params: {
  historyContext: HistoryContext
  anchorMessage: Message
  parentChatId: bigint
  senderProfilesById: SenderProfileLookup
  meId: bigint
}): HistoryContext {
  const entry = buildInlineHistoryEntryPayload({
    message: params.anchorMessage,
    senderProfilesById: params.senderProfilesById,
    meId: params.meId,
    syntheticMessageId: `anchor:${String(params.parentChatId)}:${String(params.anchorMessage.id)}`,
  })
  if (!entry.inboundEntry || !entry.line) {
    return {
      ...params.historyContext,
    }
  }

  return {
    ...params.historyContext,
    inboundHistory: [entry.inboundEntry, ...params.historyContext.inboundHistory],
    historyText: prependLabeledHistoryLine({
      existing: params.historyContext.historyText,
      heading: "Recent thread messages (oldest -> newest):",
      line: entry.line,
    }),
    attachmentText: prependLabeledHistoryLine({
      existing: params.historyContext.attachmentText,
      heading: "Recent media/attachments:",
      line: entry.attachmentLine,
    }),
    entityText: prependLabeledHistoryLine({
      existing: params.historyContext.entityText,
      heading: "Recent message entities:",
      line: entry.entityLine,
    }),
  }
}

export function prependInlineParentHistoryContext(params: {
  historyContext: HistoryContext
  parentHistoryContext: HistoryContext
}): HistoryContext {
  return {
    ...params.historyContext,
    inboundHistory: [
      ...params.parentHistoryContext.inboundHistory,
      ...params.historyContext.inboundHistory,
    ],
    historyText: prependLabeledHistoryBlock({
      existing: params.historyContext.historyText,
      heading: "Recent thread messages (oldest -> newest):",
      block: params.parentHistoryContext.historyText,
    }),
    attachmentText: prependLabeledHistoryBlock({
      existing: params.historyContext.attachmentText,
      heading: "Recent media/attachments:",
      block: params.parentHistoryContext.attachmentText,
    }),
    entityText: prependLabeledHistoryBlock({
      existing: params.historyContext.entityText,
      heading: "Recent message entities:",
      block: params.parentHistoryContext.entityText,
    }),
  }
}

export function buildInlineChannelStructuredContext(params: {
  currentAttachmentText: string | null
  currentEntityText: string | null
  currentBody: string
  historyAttachmentText: string | null
  historyEntityText: string | null
  actionContext?: InlineChannelStructuredContextEntry
}): InlineChannelStructuredContextEntry[] {
  const entries: InlineChannelStructuredContextEntry[] = []
  const append = (label: string, type: string, summary: string | null) => {
    if (!summary) return
    const normalized = normalizeHistoryText(summary)
    if (!normalized || normalized === params.currentBody) return
    entries.push({
      label,
      source: CHANNEL_ID,
      type,
      payload: { summary: normalized },
    })
  }

  append("Current Inline media/attachments", "current_media_attachments", params.currentAttachmentText)
  append("Current Inline message entities", "current_message_entities", params.currentEntityText)
  append("Recent Inline media/attachments", "recent_media_attachments", params.historyAttachmentText)
  append("Recent Inline message entities", "recent_message_entities", params.historyEntityText)
  if (params.actionContext) entries.push(params.actionContext)
  return entries
}

export async function resolveInlineInboundReplyThreadContext(params: {
  replyThreadsEnabled: boolean
  client: InlineSdkClient
  chatId: bigint
  chatInfo: CachedChatInfo
  chatCache: Map<bigint, CachedChatInfo>
  useCachedChatMetadata?: boolean
}): Promise<InlineReplyThreadContext | null> {
  if (params.chatInfo.kind === "direct" || !params.replyThreadsEnabled) {
    return null
  }

  const metadata = params.useCachedChatMetadata
    ? params.chatInfo.parentChatId != null
      ? {
          childChatId: params.chatId,
          parentChatId: params.chatInfo.parentChatId,
          parentMessageId: params.chatInfo.parentMessageId ?? null,
          title: params.chatInfo.title ?? null,
        }
      : null
    : await loadInlineReplyThreadMetadata({
        client: params.client,
        chatId: params.chatId,
      })
  if (!metadata) {
    return null
  }

  const parentChatInfo =
    metadata.parentChatId === params.chatId
      ? params.chatInfo
      : await resolveChatInfo(params.client, params.chatCache, metadata.parentChatId)
  const anchorMessage =
    metadata.parentMessageId != null
      ? await loadInlineReplyThreadAnchorMessage({
          client: params.client,
          parentChatId: metadata.parentChatId,
          parentMessageId: metadata.parentMessageId,
        }).catch(() => null)
      : null

  return {
    childChatId: metadata.childChatId,
    parentChatId: metadata.parentChatId,
    parentChatKind: parentChatInfo.kind,
    ...(parentChatInfo.peerUserId != null ? { parentPeerUserId: parentChatInfo.peerUserId } : {}),
    parentChatTitle: parentChatInfo.title ?? null,
    parentMessageId: metadata.parentMessageId,
    threadLabel: buildInlineReplyThreadLabel({
      title: metadata.title ?? params.chatInfo.title ?? null,
      anchorMessage,
    }),
    anchorMessage,
  }
}

function parseCachedInlineId(raw: string | undefined): bigint | null {
  if (!raw || !/^\d+$/.test(raw)) return null
  try {
    return BigInt(raw)
  } catch {
    return null
  }
}

export async function resolveInlineReplyThreadContextFromRoute(params: {
  route: InlineReplyThreadRouteRecord
  client: InlineSdkClient
  chatCache: Map<bigint, CachedChatInfo>
  fallbackParentChatInfo: CachedChatInfo
}): Promise<InlineReplyThreadContext | null> {
  const parentChatId = parseCachedInlineId(params.route.parentChatId)
  const childChatId = parseCachedInlineId(params.route.threadId)
  if (parentChatId == null || childChatId == null) {
    return null
  }
  const parentMessageId = parseCachedInlineId(params.route.parentMessageId)
  const parentChatInfo = await resolveChatInfo(params.client, params.chatCache, parentChatId)
    .catch(() => params.fallbackParentChatInfo)
  const anchorMessage =
    parentMessageId != null
      ? await loadInlineReplyThreadAnchorMessage({
          client: params.client,
          parentChatId,
          parentMessageId,
        }).catch(() => null)
      : null
  const labelSource = params.route.threadLabel ?? params.route.title ?? null

  return {
    childChatId,
    parentChatId,
    parentChatKind: parentChatInfo.kind,
    ...(parentChatInfo.peerUserId != null ? { parentPeerUserId: parentChatInfo.peerUserId } : {}),
    parentChatTitle: parentChatInfo.title ?? params.fallbackParentChatInfo.title,
    parentMessageId,
    threadLabel: buildInlineReplyThreadLabel({
      title: labelSource,
      anchorMessage,
    }),
    anchorMessage,
  }
}

export async function buildReplyThreadParentHistoryContext(params: {
  client: InlineSdkClient
  replyThreadContext: InlineReplyThreadContext
  parentHistoryLimit: number
  senderProfilesById: SenderProfileLookup
  meId: bigint
  botMessageIdsByChat: Map<string, string[]>
}): Promise<HistoryContext | null> {
  if (params.parentHistoryLimit <= 0 || params.replyThreadContext.parentMessageId == null) {
    return null
  }

  return buildHistoryContext({
    client: params.client,
    chatId: params.replyThreadContext.parentChatId,
    currentMessageId: params.replyThreadContext.parentMessageId,
    replyToMsgId: params.replyThreadContext.anchorMessage?.replyToMsgId,
    senderProfilesById: params.senderProfilesById,
    meId: params.meId,
    historyLimit: params.parentHistoryLimit,
    botMessageIdsByChat: params.botMessageIdsByChat,
  })
}

export async function buildHistoryContext(params: {
  client: InlineSdkClient
  chatId: bigint
  currentMessageId: bigint
  replyToMsgId: bigint | undefined
  senderProfilesById: SenderProfileLookup
  meId: bigint
  historyLimit: number
  botMessageIdsByChat: Map<string, string[]>
}): Promise<HistoryContext> {
  const cachedReplyToBot =
    params.replyToMsgId != null &&
    hasBotMessageId(params.botMessageIdsByChat, params.chatId, params.replyToMsgId)
  let repliedToBot = cachedReplyToBot
  let replyToSenderId: string | null = null
  let foundReplyTargetInHistory = false
  const lines: string[] = []
  const attachmentLines: string[] = []
  const entityLines: string[] = []
  const inboundHistory: InlinePendingHistoryEntry[] = []

  if (params.historyLimit > 0) {
    const messages = await loadChatHistoryMessages({
      client: params.client,
      chatId: params.chatId,
      offsetId: params.currentMessageId,
      limit: params.historyLimit,
    })

    if (messages) {
      for (const item of messages) {
        if (item.fromId === params.meId) {
          rememberBotMessageId(params.botMessageIdsByChat, params.chatId, item.id)
        }
      }

      const sortedMessages = messages
        .filter((item) => item.id !== params.currentMessageId)
        .sort((a, b) => {
          const byDate = Number(a.date - b.date)
          if (byDate !== 0) return byDate
          if (a.id === b.id) return 0
          return a.id < b.id ? -1 : 1
        })

      for (const item of sortedMessages) {
        if (params.replyToMsgId != null && item.id === params.replyToMsgId) {
          foundReplyTargetInHistory = true
          replyToSenderId = String(item.fromId)
          repliedToBot = item.fromId === params.meId
        }
        appendInlineHistoryEntry(
          {
            lines,
            attachmentLines,
            entityLines,
            inboundHistory,
          },
          buildInlineHistoryEntryPayload({
            message: item,
            senderProfilesById: params.senderProfilesById,
            meId: params.meId,
          }),
        )
      }
    }
  }

  if (params.replyToMsgId != null && !foundReplyTargetInHistory) {
    const replyTarget = await findChatMessageById({
      client: params.client,
      chatId: params.chatId,
      messageId: params.replyToMsgId,
      limit: REPLY_TARGET_LOOKUP_LIMIT,
      meId: params.meId,
      botMessageIdsByChat: params.botMessageIdsByChat,
    })
    if (replyTarget) {
      replyToSenderId = String(replyTarget.fromId)
      repliedToBot = replyTarget.fromId === params.meId
    } else if (!cachedReplyToBot) {
      repliedToBot = false
    }
  }

  if (!lines.length) {
    return {
      historyText: null,
      attachmentText: attachmentLines.length ? attachmentLines.slice(-ATTACHMENT_CONTEXT_LIMIT).join("\n") : null,
      entityText: entityLines.length ? entityLines.slice(-ATTACHMENT_CONTEXT_LIMIT).join("\n") : null,
      inboundHistory,
      repliedToBot,
      replyToSenderId,
    }
  }
  return {
    historyText: `Recent thread messages (oldest -> newest):\n${lines.join("\n")}`,
    attachmentText: attachmentLines.length
      ? `Recent media/attachments:\n${attachmentLines.slice(-ATTACHMENT_CONTEXT_LIMIT).join("\n")}`
      : null,
    entityText: entityLines.length
      ? `Recent message entities:\n${entityLines.slice(-ATTACHMENT_CONTEXT_LIMIT).join("\n")}`
      : null,
    inboundHistory,
    repliedToBot,
    replyToSenderId,
  }
}
