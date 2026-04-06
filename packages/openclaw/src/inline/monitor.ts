import { mkdir } from "node:fs/promises"
import path from "node:path"
import {
  DEFAULT_GROUP_HISTORY_LIMIT,
  buildPendingHistoryContextFromMap,
  clearHistoryEntriesIfEnabled,
  createChannelReplyPipelineCompat,
  recordPendingHistoryEntryIfEnabled,
} from "../sdk-runtime-compat.js"
import type { OpenClawConfig } from "openclaw/plugin-sdk/core"
import type { RuntimeEnv } from "openclaw/plugin-sdk/runtime-env"
import { InlineSdkClient, JsonFileStateStore, Method, type Message, type MessageActions } from "@inline-chat/realtime-sdk"
import { resolveInlineToken, type ResolvedInlineAccount } from "./accounts.js"
import { INLINE_FORMATTING_NOTE, buildInlineSystemPrompt } from "./message-formatting.js"
import { resolveInlineGroupRequireMention } from "./policy.js"
import { getInlineRuntime } from "../runtime.js"
import { uploadInlineMediaFromUrl } from "./media.js"
import { summarizeInlineMessageContent } from "./message-content.js"
import {
  isInlineReplyThreadsEnabled,
  loadInlineReplyThreadAnchorMessage,
  loadInlineReplyThreadMetadata,
} from "./reply-threads.js"
import { resolveInlineCompatNativeCommandMenu } from "./command-menu-compat.js"
import {
  logInboundDrop,
  resolveChannelMediaMaxBytes,
  resolveControlCommandGate,
  resolveMentionGatingWithBypass,
} from "../openclaw-compat.js"

const CHANNEL_ID = "inline" as const

type InlineMonitorHandle = {
  stop: () => Promise<void>
  done: Promise<void>
}

type StatusSink = (patch: { lastInboundAt?: number; lastOutboundAt?: number; lastError?: string }) => void

type CachedChatInfo = {
  kind: "direct" | "group"
  title: string | null
}

type SenderProfile = {
  name?: string
  username?: string
}

type HistoryContext = {
  historyText: string | null
  attachmentText: string | null
  entityText: string | null
  inboundHistory: InlinePendingHistoryEntry[]
  repliedToBot: boolean
  replyToSenderId: string | null
}

type InlineInboundMediaInfo = {
  path: string
  contentType?: string | undefined
}

type InlineEditStreamState = {
  messageId: bigint | null
  accumulatedText: string
  lastPartialText: string
  finalTextAccumulator: string
  failed: boolean
  opChain: Promise<void>
}

type InlinePendingHistoryEntry = {
  sender: string
  body: string
  timestamp?: number
  messageId?: string
}

type InlineReplyThreadContext = {
  childChatId: bigint
  parentChatId: bigint
  parentChatTitle: string | null
  threadLabel: string | null
  anchorMessage: Message | null
}

type InlineDispatchReplyInfo = {
  kind?: string
  reason?: string
}

type InlineHistoryEntryPayload = {
  line: string | null
  attachmentLine: string | null
  entityLine: string | null
  inboundEntry: InlinePendingHistoryEntry | null
}

const DEFAULT_DM_HISTORY_LIMIT = 6
const HISTORY_LINE_MAX_CHARS = 280
const URL_LIKE_PATTERN = /https?:\/\/\S+/i
const BOT_MESSAGE_CACHE_LIMIT = 500
const REACTION_TARGET_LOOKUP_LIMIT = 8
const REPLY_TARGET_LOOKUP_LIMIT = 8
const ATTACHMENT_CONTEXT_LIMIT = 6
const DEFAULT_INLINE_MEDIA_MAX_BYTES = 300 * 1024 * 1024
const EMPTY_RESPONSE_FALLBACK = "No response generated. Please try again."
const GET_MESSAGES_METHOD =
  typeof (Method as Record<string, unknown>).GET_MESSAGES === "number" &&
  Number.isInteger((Method as Record<string, unknown>).GET_MESSAGES) &&
  ((Method as Record<string, unknown>).GET_MESSAGES as number) > 0
    ? ((Method as Record<string, unknown>).GET_MESSAGES as Method)
    : null

function normalizeAllowEntry(raw: string): string {
  return raw.trim().replace(/^inline:/i, "").replace(/^user:/i, "")
}

function normalizeAllowlist(entries: Array<string | number> | undefined): string[] {
  return (entries ?? [])
    .map((entry) => normalizeAllowEntry(String(entry)))
    .map((entry) => entry.trim())
    .filter(Boolean)
}

function allowlistMatch(params: { allowFrom: string[]; senderId: string }): boolean {
  if (params.allowFrom.some((entry) => entry === "*")) return true
  return params.allowFrom.some((entry) => entry === params.senderId)
}

async function resolveChatInfo(
  client: InlineSdkClient,
  cache: Map<bigint, CachedChatInfo>,
  chatId: bigint,
): Promise<CachedChatInfo> {
  const existing = cache.get(chatId)
  if (existing) return existing

  const result = await client.getChat({ chatId })
  const peerKind = result.peer?.type.oneofKind
  const kind: CachedChatInfo["kind"] = peerKind === "user" ? "direct" : "group"
  const title = result.title?.trim() || null
  const info: CachedChatInfo = { kind, title }
  cache.set(chatId, info)
  return info
}

function normalizeInlineUsername(raw: string | undefined): string | undefined {
  const trimmed = raw?.trim()
  if (!trimmed) return undefined
  return trimmed.startsWith("@") ? trimmed.slice(1) : trimmed
}

function normalizeInlineCommandBody(raw: string, botUsername: string | undefined): string {
  const normalized = raw.trim()
  const normalizedBotUsername = botUsername?.trim().toLowerCase()
  const mentionMatch = normalizedBotUsername ? normalized.match(/^\/([^\s@]+)@([^\s]+)(.*)$/) : null
  if (mentionMatch) {
    const [, command, targetUsername, suffix] = mentionMatch
    if (targetUsername?.toLowerCase() === normalizedBotUsername) {
      return `/${command}${suffix ?? ""}`
    }
  }
  return normalized
}

function callbackDataToBase64(data: Uint8Array): string {
  return Buffer.from(data).toString("base64")
}

function callbackDataToUtf8(data: Uint8Array): string | undefined {
  try {
    const decoded = new TextDecoder("utf-8", { fatal: true }).decode(data).trim()
    return decoded || undefined
  } catch {
    return undefined
  }
}

type InlineReplyMarkupButton = {
  text: string
  callback_data: string
}

const INLINE_ACTION_MAX_ROWS = 8
const INLINE_ACTION_MAX_PER_ROW = 8

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null
}

function normalizeReplyMarkupButtons(raw: unknown): InlineReplyMarkupButton[][] {
  return normalizeReplyMarkupButtonsWith(raw)
}

function mapInlineModelPickerCallbackToCommand(raw: string): string | undefined {
  const trimmed = raw.trim()
  if (!trimmed) return undefined

  if (trimmed === "mdl_prov" || trimmed === "mdl_back") {
    return "/models"
  }

  const listMatch = trimmed.match(/^mdl_list_([a-z0-9_-]+)_(\d+)$/i)
  if (listMatch?.[1] && listMatch[2]) {
    const provider = listMatch[1].trim()
    const page = Number.parseInt(listMatch[2], 10)
    if (provider && Number.isFinite(page) && page > 0) {
      return `/models ${provider} ${String(page)}`
    }
  }

  const standardSelectionMatch = trimmed.match(/^mdl_sel_(.+)$/)
  if (standardSelectionMatch?.[1]?.trim()) {
    return `/model ${standardSelectionMatch[1].trim()}`
  }

  const compactSelectionMatch = trimmed.match(/^mdl_sel\/(.+)$/)
  if (compactSelectionMatch?.[1]?.trim()) {
    return `/model ${compactSelectionMatch[1].trim()}`
  }

  return undefined
}

function normalizeInlineActionCallbackData(raw: string): string {
  const trimmed = raw.trim()
  if (!trimmed) return ""
  return mapInlineModelPickerCallbackToCommand(trimmed) ?? trimmed
}

function normalizeReplyMarkupButtonsWith(
  raw: unknown,
  options?: { mapCallbackData?: (value: string) => string },
): InlineReplyMarkupButton[][] {
  if (!Array.isArray(raw)) return []

  const rows: InlineReplyMarkupButton[][] = []
  for (const candidateRow of raw) {
    if (!Array.isArray(candidateRow)) continue
    const row: InlineReplyMarkupButton[] = []
    for (const candidateButton of candidateRow) {
      if (!isRecord(candidateButton)) continue
      const text = typeof candidateButton.text === "string" ? candidateButton.text.trim() : ""
      const callbackDataRaw =
        typeof candidateButton.callback_data === "string" ? candidateButton.callback_data.trim() : ""
      const callbackData = options?.mapCallbackData ? options.mapCallbackData(callbackDataRaw) : callbackDataRaw
      if (!text || !callbackData) continue
      row.push({ text, callback_data: callbackData })
      if (row.length >= INLINE_ACTION_MAX_PER_ROW) break
    }
    if (row.length === 0) continue
    rows.push(row)
    if (rows.length >= INLINE_ACTION_MAX_ROWS) break
  }

  return rows
}

function resolveInlineReplyActions(payload: Record<string, unknown>): MessageActions | undefined {
  const channelData = isRecord(payload.channelData) ? payload.channelData : undefined
  const inlineData = channelData && isRecord(channelData.inline) ? channelData.inline : undefined
  const telegramData = channelData && isRecord(channelData.telegram) ? channelData.telegram : undefined

  let rawButtons: unknown = undefined
  let hasExplicitButtons = false
  let mapCallbackData: ((value: string) => string) | undefined

  if (inlineData && Object.prototype.hasOwnProperty.call(inlineData, "buttons")) {
    rawButtons = inlineData.buttons
    hasExplicitButtons = true
  } else if (telegramData && Object.prototype.hasOwnProperty.call(telegramData, "buttons")) {
    rawButtons = telegramData.buttons
    hasExplicitButtons = true
    mapCallbackData = normalizeInlineActionCallbackData
  } else if (Object.prototype.hasOwnProperty.call(payload, "buttons")) {
    rawButtons = payload.buttons
    hasExplicitButtons = true
  }

  if (!hasExplicitButtons) return undefined

  const rows = normalizeReplyMarkupButtonsWith(rawButtons, {
    ...(mapCallbackData ? { mapCallbackData } : {}),
  })
  return {
    rows: rows.map((row, rowIndex) => ({
      actions: row.map((button, buttonIndex) => ({
        actionId: `btn_${rowIndex + 1}_${buttonIndex + 1}`,
        text: button.text,
        action: {
          oneofKind: "callback",
          callback: {
            data: new TextEncoder().encode(button.callback_data),
          },
        },
      })),
    })),
  }
}

async function answerInlineMessageAction(client: InlineSdkClient, interactionId: bigint): Promise<void> {
  const withAnswer = client as InlineSdkClient & {
    answerMessageAction?: (params: { interactionId: bigint }) => Promise<void>
    invokeUncheckedRaw?: (
      method: Method,
      input?: { oneofKind?: string; answerMessageAction?: { interactionId: bigint } },
    ) => Promise<unknown>
  }

  if (typeof withAnswer.answerMessageAction === "function") {
    await withAnswer.answerMessageAction({ interactionId })
    return
  }

  const answerMethod = (Method as Record<string, unknown>)["ANSWER_MESSAGE_ACTION"]
  if (typeof answerMethod === "number" && typeof withAnswer.invokeUncheckedRaw === "function") {
    await withAnswer.invokeUncheckedRaw(answerMethod as Method, {
      oneofKind: "answerMessageAction",
      answerMessageAction: { interactionId },
    })
  }
}

function resolveCallbackCommandBodyFromActionData(params: {
  data: Uint8Array
  botUsername?: string
}): string | undefined {
  const decoded = callbackDataToUtf8(params.data)
  if (!decoded) return undefined
  const normalized = normalizeInlineActionCallbackData(decoded)
  if (!normalized.startsWith("/")) return undefined
  return normalizeInlineCommandBody(normalized, params.botUsername)
}

function shouldUseTelegramSurfaceForModelCommands(commandBody: string): boolean {
  const normalized = commandBody.trim().toLowerCase()
  return normalized === "/model" || normalized.startsWith("/model ") || normalized === "/models" || normalized.startsWith("/models ")
}

function buildInlineSenderName(params: {
  firstName: string | undefined
  lastName: string | undefined
}): string | undefined {
  const name = [params.firstName, params.lastName].filter(Boolean).join(" ").trim()
  return name || undefined
}

function resolveInlineSystemPrompt(params: {
  account: ResolvedInlineAccount
  groupId?: string
}): string {
  const groupPrompt = params.groupId
    ? params.account.config.groups?.[params.groupId]?.systemPrompt?.trim()
    : undefined
  return [buildInlineSystemPrompt(params.account.config.systemPrompt), groupPrompt]
    .filter((entry): entry is string => Boolean(entry))
    .join("\n\n")
}

function rewriteNumericMentionsToUsernames(text: string, senderProfilesById: Map<string, SenderProfile>): string {
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

function buildChatPeer(chatId: bigint): {
  type: {
    oneofKind: "chat"
    chat: { chatId: bigint }
  }
} {
  return {
    type: {
      oneofKind: "chat",
      chat: { chatId },
    },
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

async function findChatMessageById(params: {
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

async function isReactionTargetBotMessage(params: {
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

function normalizeHistoryText(raw: string | undefined): string {
  const compact = (raw ?? "").replace(/\s+/g, " ").trim()
  if (!compact) return ""
  if (compact.length <= HISTORY_LINE_MAX_CHARS) return compact
  // Keep full URLs for media/file discoverability in history context.
  if (URL_LIKE_PATTERN.test(compact)) return compact
  return `${compact.slice(0, HISTORY_LINE_MAX_CHARS - 1)}…`
}

function drainCompleteParagraphs(buffer: string): { paragraphs: string[]; rest: string } {
  const paragraphs: string[] = []
  let rest = buffer

  while (rest.length > 0) {
    const breakIndex = rest.indexOf("\n\n")
    if (breakIndex < 0) break
    const paragraph = rest.slice(0, breakIndex).trim()
    if (paragraph) {
      paragraphs.push(paragraph)
    }
    rest = rest.slice(breakIndex).replace(/^\n+/, "")
  }

  return { paragraphs, rest }
}

function appendParagraphText(existing: string, paragraph: string): string {
  const trimmed = paragraph.trim()
  if (!trimmed) return existing
  return existing ? `${existing}\n\n${trimmed}` : trimmed
}

function extractCompleteParagraphText(text: string): string {
  const drained = drainCompleteParagraphs(text)
  return drained.paragraphs.reduce((acc, paragraph) => appendParagraphText(acc, paragraph), "").trim()
}

function resolveHistorySenderLabel(params: {
  senderId: bigint
  meId: bigint
  senderProfilesById: Map<string, SenderProfile>
}): string {
  if (params.senderId === params.meId) return "assistant"
  const senderId = String(params.senderId)
  const profile = params.senderProfilesById.get(senderId)
  if (profile?.username) return `@${profile.username}`
  if (profile?.name) return profile.name
  return `user:${senderId}`
}

function resolveHistoryLimit(params: {
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
  if (entry.messageId) return `id:${entry.messageId}`
  return `ts:${entry.timestamp ?? "unknown"}:${entry.sender}:${entry.body}`
}

function mergeInboundHistoryEntries(params: {
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
  senderProfilesById: Map<string, SenderProfile>
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
  const attachmentText = normalizeHistoryText(content.attachmentText)
  const entityText = normalizeHistoryText(content.entityText)

  return {
    line: `#${String(params.message.id)}${replySuffix} ${label}: ${text}`,
    attachmentLine: attachmentText ? `#${String(params.message.id)}${replySuffix} ${label}: ${attachmentText}` : null,
    entityLine: entityText ? `#${String(params.message.id)}${replySuffix} ${label}: ${entityText}` : null,
    inboundEntry: {
      sender: label,
      body: text,
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

function prependInlineReplyThreadAnchor(params: {
  historyContext: HistoryContext
  anchorMessage: Message
  parentChatId: bigint
  senderProfilesById: Map<string, SenderProfile>
  meId: bigint
}): HistoryContext {
  const entry = buildInlineHistoryEntryPayload({
    message: params.anchorMessage,
    senderProfilesById: params.senderProfilesById,
    meId: params.meId,
    syntheticMessageId: `anchor:${String(params.parentChatId)}:${String(params.anchorMessage.id)}`,
  })
  if (!entry.inboundEntry || !entry.line) {
    return params.historyContext
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

function buildInlineBodyForAgent(params: {
  rawBody: string
  currentAttachmentText: string | null
  currentEntityText: string | null
}): string {
  return (
    [
      params.rawBody,
      params.currentAttachmentText && params.currentAttachmentText !== params.rawBody
        ? `Current media/attachments:\n${params.currentAttachmentText}`
        : null,
      params.currentEntityText ? `Current message entities:\n${params.currentEntityText}` : null,
    ]
      .filter(Boolean)
      .join("\n\n") || params.rawBody
  )
}

function resolveInlineMediaMaxBytes(params: {
  cfg: OpenClawConfig
  account: ResolvedInlineAccount
}): number {
  return (
    resolveChannelMediaMaxBytes({
      cfg: params.cfg,
      accountId: params.account.accountId,
      resolveChannelLimitMb: ({ accountId }) => {
        if (accountId != null && accountId !== params.account.accountId) return undefined
        return params.account.config.mediaMaxMb
      },
    }) ?? DEFAULT_INLINE_MEDIA_MAX_BYTES
  )
}

function buildInlineInboundMediaPayload(media: InlineInboundMediaInfo[]): {
  MediaPath?: string
  MediaType?: string
  MediaUrl?: string
  MediaPaths?: string[]
  MediaUrls?: string[]
  MediaTypes?: string[]
} {
  const first = media[0]
  const mediaPaths = media.map((item) => item.path)
  const firstMediaType = first?.contentType?.trim()
  const mediaTypes = media
    .map((item) => item.contentType?.trim())
    .filter((item): item is string => Boolean(item))

  return {
    ...(first?.path ? { MediaPath: first.path, MediaUrl: first.path } : {}),
    ...(firstMediaType ? { MediaType: firstMediaType } : {}),
    ...(mediaPaths.length > 0 ? { MediaPaths: mediaPaths, MediaUrls: mediaPaths } : {}),
    ...(mediaTypes.length > 0 ? { MediaTypes: mediaTypes } : {}),
  }
}

function buildInlineAttachmentPlaceholder(content: ReturnType<typeof summarizeInlineMessageContent>): string {
  const media = content.media
  if (!media) return ""
  switch (media.kind) {
    case "photo":
      return "<media:image>"
    case "video":
      return "<media:video>"
    case "document":
      return "<media:document>"
    case "voice":
      return "<media:audio>"
    default:
      return ""
  }
}

function buildInlineInboundBodyText(content: ReturnType<typeof summarizeInlineMessageContent>): string {
  const textWithPlaceholder = [content.rawText, buildInlineAttachmentPlaceholder(content)]
    .filter(Boolean)
    .join("\n")
    .trim()
  return textWithPlaceholder || content.text
}

function resolveFilePathHint(params: { sourceUrl: string; preferredName?: string | null | undefined }): string | undefined {
  const preferred = params.preferredName?.trim()
  if (preferred) return preferred

  try {
    const pathname = new URL(params.sourceUrl).pathname
    const base = path.basename(pathname).trim()
    if (base) return base
  } catch {
    // ignore malformed urls and let the media pipeline choose a filename
  }

  return undefined
}

async function resolveInlineInboundMedia(params: {
  core: ReturnType<typeof getInlineRuntime>
  message: Message
  maxBytes: number
  log?: { warn?: (msg: string) => void; debug?: (msg: string) => void } | undefined
}): Promise<InlineInboundMediaInfo[]> {
  const content = summarizeInlineMessageContent(params.message)
  const candidates = new Map<
    string,
    {
      fileName?: string | null
      mimeType?: string | null
    }
  >()

  if (content.media?.url) {
    candidates.set(content.media.url, {
      fileName: content.media.fileName ?? null,
      mimeType: content.media.mimeType ?? null,
    })
  }

  for (const attachment of content.attachments) {
    if (attachment.kind !== "urlPreview" || !attachment.previewImageUrl) continue
    candidates.set(attachment.previewImageUrl, {
      mimeType: null,
    })
  }

  const out: InlineInboundMediaInfo[] = []
  for (const [url, candidate] of candidates.entries()) {
    try {
      const filePathHint = resolveFilePathHint({ sourceUrl: url, preferredName: candidate.fileName })
      const fetched = await params.core.channel.media.fetchRemoteMedia({
        url,
        maxBytes: params.maxBytes,
        ...(filePathHint ? { filePathHint } : {}),
      })
      const saved = await params.core.channel.media.saveMediaBuffer(
        fetched.buffer,
        fetched.contentType ?? candidate.mimeType ?? undefined,
        "inbound",
        params.maxBytes,
        fetched.fileName ?? candidate.fileName ?? undefined,
      )
      const contentType = saved.contentType ?? fetched.contentType ?? candidate.mimeType ?? undefined
      out.push({
        path: saved.path,
        ...(contentType ? { contentType } : {}),
      })
    } catch (err) {
      params.log?.warn?.(`inline: failed to download inbound media ${url}: ${String(err)}`)
    }
  }

  return out
}

async function resolveInlineInboundReplyThreadContext(params: {
  replyThreadsEnabled: boolean
  client: InlineSdkClient
  chatId: bigint
  chatInfo: CachedChatInfo
  chatCache: Map<bigint, CachedChatInfo>
}): Promise<InlineReplyThreadContext | null> {
  if (params.chatInfo.kind === "direct" || !params.replyThreadsEnabled) {
    return null
  }

  const metadata = await loadInlineReplyThreadMetadata({
    client: params.client,
    chatId: params.chatId,
  })
  if (!metadata) {
    return null
  }

  const parentChatInfo =
    metadata.parentChatId === params.chatId
      ? params.chatInfo
      : await resolveChatInfo(params.client, params.chatCache, metadata.parentChatId).catch(() => ({
          kind: "group" as const,
          title: null,
        }))
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
    parentChatTitle: parentChatInfo.title ?? null,
    threadLabel: metadata.title ?? params.chatInfo.title ?? null,
    anchorMessage,
  }
}

async function buildHistoryContext(params: {
  client: InlineSdkClient
  chatId: bigint
  currentMessageId: bigint
  replyToMsgId: bigint | undefined
  senderProfilesById: Map<string, SenderProfile>
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

export async function monitorInlineProvider(params: {
  cfg: OpenClawConfig
  account: ResolvedInlineAccount
  runtime: RuntimeEnv
  abortSignal: AbortSignal
  log?: { info: (msg: string) => void; warn: (msg: string) => void; error: (msg: string) => void; debug?: (msg: string) => void }
  statusSink?: StatusSink
}): Promise<InlineMonitorHandle> {
  const { cfg, account, runtime, abortSignal, log, statusSink } = params
  const core = getInlineRuntime()

  if (!account.configured || !account.baseUrl) {
    throw new Error(`Inline not configured for account "${account.accountId}" (missing baseUrl or token)`)
  }
  const token = await resolveInlineToken(account)

  const stateDir = core.state.resolveStateDir()
  const statePath = path.join(stateDir, "channels", "inline", `${account.accountId}.json`)
  await mkdir(path.dirname(statePath), { recursive: true })

  const sdkLog = {
    debug: (msg: string) => log?.debug?.(msg),
    info: (msg: string) => log?.info(msg),
    warn: (msg: string) => log?.warn(msg),
    error: (msg: string) => log?.error(msg),
  }

  const client = new InlineSdkClient({
    baseUrl: account.baseUrl,
    token,
    logger: sdkLog,
    state: new JsonFileStateStore(statePath),
  })

  await client.connect(abortSignal)
  const meResult = await client.invokeRaw(Method.GET_ME, {
    oneofKind: "getMe",
    getMe: {},
  })
  if (meResult.oneofKind !== "getMe" || !meResult.getMe.user) {
    throw new Error("inline getMe: missing user")
  }
  const meId = meResult.getMe.user.id
  const botUsername = normalizeInlineUsername(meResult.getMe.user.username)?.toLowerCase()
  log?.info(`[${account.accountId}] inline connected (me=${String(meId)})`)

  const chatCache = new Map<bigint, CachedChatInfo>()
  const senderProfilesById = new Map<string, SenderProfile>()
  const botMessageIdsByChat = new Map<string, string[]>()
  const groupPendingHistories = new Map<string, InlinePendingHistoryEntry[]>()
  const hydratedParticipantChats = new Set<string>()
  const participantFetches = new Map<string, Promise<void>>()
  const inboundMediaMaxBytes = resolveInlineMediaMaxBytes({ cfg, account })

  const hydrateChatParticipants = async (chatId: bigint): Promise<void> => {
    const chatKey = String(chatId)
    if (hydratedParticipantChats.has(chatKey)) return
    const existing = participantFetches.get(chatKey)
    if (existing) return existing

    const run = (async () => {
      const result = await client.invokeRaw(Method.GET_CHAT_PARTICIPANTS, {
        oneofKind: "getChatParticipants",
        getChatParticipants: { chatId },
      })
      if (result.oneofKind !== "getChatParticipants") return

      for (const user of result.getChatParticipants.users ?? []) {
        const userId = String(user.id)
        if (!userId) continue
        const nextName = buildInlineSenderName({ firstName: user.firstName, lastName: user.lastName })
        const nextUsername = normalizeInlineUsername(user.username)
        const previous = senderProfilesById.get(userId)
        const mergedName = nextName ?? previous?.name
        const mergedUsername = nextUsername ?? previous?.username
        senderProfilesById.set(userId, {
          ...(mergedName ? { name: mergedName } : {}),
          ...(mergedUsername ? { username: mergedUsername } : {}),
        })
      }

      hydratedParticipantChats.add(chatKey)
    })()
      .catch((err) => {
        statusSink?.({ lastError: `getChatParticipants failed: ${String(err)}` })
      })
      .finally(() => {
        participantFetches.delete(chatKey)
      })

    participantFetches.set(chatKey, run)
    await run
  }

  const loop = (async () => {
    try {
      for await (const event of client.events()) {
        if (abortSignal.aborted) break
        const rawEvent = event as Record<string, unknown>
        let msg: Message
        let rawBody = ""
        let currentContent: ReturnType<typeof summarizeInlineMessageContent> | null = null
        let currentAttachmentText: string | null = null
        let currentEntityText: string | null = null
        let reactionEvent: { action: "added" | "removed"; emoji: string; targetMessageId: bigint } | null = null
        let inboundChatId: bigint | null = null
        let callbackActionEvent:
          | {
              interactionId: bigint
              actionId: string
              targetMessageId: bigint
              data: Uint8Array
            }
          | null = null

        if (event.kind === "message.new") {
          inboundChatId = event.chatId
          msg = {
            ...event.message,
            chatId: event.chatId,
          } as Message
          currentContent = summarizeInlineMessageContent(msg)
          rawBody = buildInlineInboundBodyText(currentContent)
          currentAttachmentText = currentContent.attachmentText || null
          currentEntityText = currentContent.entityText || null
          if (!rawBody) continue

          // Ignore echoes / our own outbound messages.
          if (msg.out || msg.fromId === meId) continue
        } else if (event.kind === "reaction.add") {
          inboundChatId = event.chatId
          if (event.reaction.userId === meId) continue
          const onBotMessage = await isReactionTargetBotMessage({
            client,
            chatId: event.chatId,
            messageId: event.reaction.messageId,
            meId,
            botMessageIdsByChat,
          }).catch((err) => {
            statusSink?.({ lastError: `getChatHistory (reaction target) failed: ${String(err)}` })
            return false
          })
          if (!onBotMessage) continue

          reactionEvent = {
            action: "added",
            emoji: event.reaction.emoji,
            targetMessageId: event.reaction.messageId,
          }
          msg = {
            id: event.reaction.messageId,
            chatId: event.chatId,
            date: event.date,
            fromId: event.reaction.userId,
            message: "",
            out: false,
            mentioned: false,
            replyToMsgId: event.reaction.messageId,
          } as Message
        } else if (event.kind === "reaction.delete") {
          inboundChatId = event.chatId
          if (event.userId === meId) continue
          const onBotMessage = await isReactionTargetBotMessage({
            client,
            chatId: event.chatId,
            messageId: event.messageId,
            meId,
            botMessageIdsByChat,
          }).catch((err) => {
            statusSink?.({ lastError: `getChatHistory (reaction target) failed: ${String(err)}` })
            return false
          })
          if (!onBotMessage) continue

          reactionEvent = {
            action: "removed",
            emoji: event.emoji,
            targetMessageId: event.messageId,
          }
          msg = {
            id: event.messageId,
            chatId: event.chatId,
            date: event.date,
            fromId: event.userId,
            message: "",
            out: false,
            mentioned: false,
            replyToMsgId: event.messageId,
          } as Message
        } else if (rawEvent["kind"] === "message.action.invoke") {
          const actorUserId = rawEvent["actorUserId"] as bigint | undefined
          const interactionId = rawEvent["interactionId"] as bigint | undefined
          const actionId = rawEvent["actionId"] as string | undefined
          const targetMessageId = rawEvent["messageId"] as bigint | undefined
          const data = rawEvent["data"] as Uint8Array | undefined
          const eventChatId = rawEvent["chatId"] as bigint | undefined
          const eventDate = rawEvent["date"] as bigint | undefined

          if (!actorUserId || !interactionId || !actionId || !targetMessageId || !eventChatId || !eventDate || !data) {
            continue
          }
          inboundChatId = eventChatId

          if (actorUserId === meId) continue

          callbackActionEvent = {
            interactionId,
            actionId,
            targetMessageId,
            data,
          }

          msg = {
            id: targetMessageId,
            chatId: eventChatId,
            date: eventDate,
            fromId: actorUserId,
            message: "",
            out: false,
            mentioned: false,
            replyToMsgId: targetMessageId,
          } as Message
        } else {
          continue
        }

        if (!inboundChatId) continue
        const chatId = inboundChatId
        statusSink?.({ lastInboundAt: Date.now() })

        let chatInfo: CachedChatInfo
        try {
          chatInfo = await resolveChatInfo(client, chatCache, chatId)
        } catch (err) {
          // Default conservative behavior if metadata fetch fails.
          chatInfo = { kind: "group", title: null }
          statusSink?.({ lastError: `getChat failed: ${String(err)}` })
        }

        const isGroup = chatInfo.kind !== "direct"
        const replyThreadsEnabled =
          account.config.capabilities?.replyThreads === true ||
          isInlineReplyThreadsEnabled({ cfg, accountId: account.accountId })
        const replyThreadContext = await resolveInlineInboundReplyThreadContext({
          replyThreadsEnabled,
          client,
          chatId,
          chatInfo,
          chatCache,
        }).catch((err) => {
          statusSink?.({ lastError: `getChat (reply thread) failed: ${String(err)}` })
          return null
        })
        const effectiveChatId = replyThreadContext?.parentChatId ?? chatId
        const effectiveGroupTitle = replyThreadContext?.parentChatTitle ?? chatInfo.title ?? null
        const senderId = String(msg.fromId)
        await hydrateChatParticipants(chatId)
        const senderProfile = senderProfilesById.get(senderId)
        const senderUsername = senderProfile?.username
        const senderName = senderProfile?.name ?? (!isGroup ? chatInfo.title ?? undefined : undefined)
        if (reactionEvent) {
          const actor =
            senderUsername != null && senderUsername.length > 0
              ? `@${senderUsername}`
              : senderName ?? `user:${senderId}`
          const emoji = reactionEvent.emoji.trim() || "a reaction"
          const messageId = String(reactionEvent.targetMessageId)
          if (reactionEvent.action === "added") {
            rawBody = `${actor} reacted with ${emoji} to your message #${messageId}`
          } else {
            rawBody = `${actor} removed ${emoji} from your message #${messageId}`
          }
        } else if (callbackActionEvent) {
          const actor =
            senderUsername != null && senderUsername.length > 0
              ? `@${senderUsername}`
              : senderName ?? `user:${senderId}`
          const payload = {
            type: "inline_message_action_callback",
            interaction_id: String(callbackActionEvent.interactionId),
            actor_user_id: senderId,
            chat_id: String(chatId),
            message_id: String(callbackActionEvent.targetMessageId),
            action_id: callbackActionEvent.actionId,
            data_base64: callbackDataToBase64(callbackActionEvent.data),
            data_utf8: callbackDataToUtf8(callbackActionEvent.data) ?? null,
          }
          rawBody = `${actor} pressed a button on message #${String(callbackActionEvent.targetMessageId)}\n${JSON.stringify(payload)}`
        }

        const dmPolicy = account.config.dmPolicy ?? "pairing"
        const defaultGroupPolicy = cfg.channels?.defaults?.groupPolicy
        const groupPolicy = account.config.groupPolicy ?? defaultGroupPolicy ?? "allowlist"

        const configAllowFrom = normalizeAllowlist(account.config.allowFrom)
        const configGroupAllowFrom = normalizeAllowlist(account.config.groupAllowFrom)
        const storeAllowFrom = await core.channel.pairing
          .readAllowFromStore({
            channel: CHANNEL_ID,
            accountId: account.accountId,
          })
          .catch(() => [])
        const storeAllowList = normalizeAllowlist(storeAllowFrom)

        const effectiveAllowFrom = [...configAllowFrom, ...storeAllowList].filter(Boolean)
        const effectiveGroupAllowFrom = [
          ...(configGroupAllowFrom.length > 0 ? configGroupAllowFrom : configAllowFrom),
          ...storeAllowList,
        ].filter(Boolean)
        const callbackCommandBody = callbackActionEvent
          ? resolveCallbackCommandBodyFromActionData({
              data: callbackActionEvent.data,
              ...(botUsername ? { botUsername } : {}),
            })
          : undefined
        let callbackActionAnswered = false
        const answerCallbackIfNeeded = async () => {
          if (!callbackActionEvent || callbackActionAnswered) return
          await answerInlineMessageAction(client, callbackActionEvent.interactionId)
          callbackActionAnswered = true
        }
        // Temporary rollback: callback-driven workflows send new messages
        // instead of editing the original message in-place.
        const shouldEditCallbackTargetInPlace = false
        const normalizedCommandBody = callbackCommandBody ?? normalizeInlineCommandBody(rawBody, botUsername)

        const allowTextCommands = core.channel.commands.shouldHandleTextCommands({
          cfg,
          surface: CHANNEL_ID,
        })
        const useAccessGroups = cfg.commands?.useAccessGroups !== false
        const allowForCommands = isGroup ? effectiveGroupAllowFrom : effectiveAllowFrom
        const senderAllowedForCommands = allowlistMatch({ allowFrom: allowForCommands, senderId })
        const hasControlCommand = core.channel.text.hasControlCommand(
          callbackCommandBody ?? rawBody,
          cfg,
          botUsername ? { botUsername } : undefined,
        )
        const commandGate = resolveControlCommandGate({
          useAccessGroups,
          authorizers: [{ configured: allowForCommands.length > 0, allowed: senderAllowedForCommands }],
          allowTextCommands,
          hasControlCommand,
        })
        const commandAuthorized = commandGate.commandAuthorized

        if (isGroup) {
          if (groupPolicy === "disabled") {
            log?.info(
              `[${account.accountId}] inline: drop group chat=${String(chatId)} (groupPolicy=disabled)`,
            )
            await answerCallbackIfNeeded().catch((error) => {
              runtime.error?.(`inline callback answer failed: ${String(error)}`)
            })
            continue
          }
          if (groupPolicy === "allowlist") {
            const allowed = allowlistMatch({ allowFrom: effectiveGroupAllowFrom, senderId })
            if (!allowed) {
              log?.info(`[${account.accountId}] inline: drop group sender=${senderId} (groupPolicy=allowlist)`)
              await answerCallbackIfNeeded().catch((error) => {
                runtime.error?.(`inline callback answer failed: ${String(error)}`)
              })
              continue
            }
          }
        } else {
          if (dmPolicy === "disabled") {
            log?.info(`[${account.accountId}] inline: drop DM sender=${senderId} (dmPolicy=disabled)`)
            await answerCallbackIfNeeded().catch((error) => {
              runtime.error?.(`inline callback answer failed: ${String(error)}`)
            })
            continue
          }
          if (dmPolicy !== "open") {
            const allowed = allowlistMatch({ allowFrom: effectiveAllowFrom, senderId })
            if (!allowed) {
              if (dmPolicy === "pairing") {
                const { code, created } = await core.channel.pairing.upsertPairingRequest({
                  channel: CHANNEL_ID,
                  id: senderId,
                  accountId: account.accountId,
                  meta: {},
                  // Pass adapter explicitly to avoid relying on registry lookup for plugin channels.
                  pairingAdapter: { idLabel: "inlineUserId", normalizeAllowEntry },
                })
                if (created) {
                  try {
                    await client.sendMessage({
                      chatId,
                      text: core.channel.pairing.buildPairingReply({
                        channel: CHANNEL_ID,
                        idLine: `Your Inline user id: ${senderId}`,
                        code,
                      }),
                    })
                    statusSink?.({ lastOutboundAt: Date.now() })
                  } catch (err) {
                    runtime.error?.(`inline: pairing reply failed for ${senderId}: ${String(err)}`)
                  }
                }
              }
              log?.info(`[${account.accountId}] inline: drop DM sender=${senderId} (dmPolicy=${dmPolicy})`)
              await answerCallbackIfNeeded().catch((error) => {
                runtime.error?.(`inline callback answer failed: ${String(error)}`)
              })
              continue
            }
          }
        }

        if (isGroup && commandGate.shouldBlock) {
          logInboundDrop({
            log: (m) => runtime.log?.(m),
            channel: CHANNEL_ID,
            reason: "control command (unauthorized)",
            target: senderId,
          })
          await answerCallbackIfNeeded().catch((error) => {
            runtime.error?.(`inline callback answer failed: ${String(error)}`)
          })
          continue
        }

        const route = core.channel.routing.resolveAgentRoute({
          cfg,
          channel: CHANNEL_ID,
          accountId: account.accountId,
          peer: {
            kind: isGroup ? "group" : "direct",
            // DM sessions should be stable per sender. Group sessions should be stable per chat.
            id: isGroup ? String(effectiveChatId) : senderId,
          },
        })

        const mentionRegexes = core.channel.mentions.buildMentionRegexes(cfg, route.agentId)
        const nativeMentioned = typeof msg.mentioned === "boolean" ? msg.mentioned : false
        const patternMentioned = mentionRegexes.length
          ? core.channel.mentions.matchesMentionPatterns(rawBody, mentionRegexes)
          : false
        const wasMentioned = nativeMentioned || patternMentioned
        const messageTimestamp = Number(msg.date) * 1000
        const groupHistoryKey = isGroup
          ? replyThreadContext
            ? `${route.sessionKey}:thread:${String(replyThreadContext.childChatId)}`
            : route.sessionKey
          : null
        const pendingHistorySender = senderUsername ? `@${senderUsername}` : senderName ?? `user:${senderId}`
        const historyLimit = resolveHistoryLimit({
          cfg,
          isGroup,
          historyLimit: account.config.historyLimit,
          dmHistoryLimit: account.config.dmHistoryLimit,
        })
        const historyContext = await buildHistoryContext({
          client,
          chatId,
          currentMessageId: msg.id,
          replyToMsgId: msg.replyToMsgId,
          senderProfilesById,
          meId,
          historyLimit,
          botMessageIdsByChat,
        }).catch((err) => {
          statusSink?.({ lastError: `getChatHistory failed: ${String(err)}` })
          return {
            historyText: null,
            attachmentText: null,
            entityText: null,
            inboundHistory: [],
            repliedToBot: false,
            replyToSenderId: null,
          }
        })
        const effectiveHistoryContext =
          replyThreadContext?.anchorMessage != null
            ? prependInlineReplyThreadAnchor({
                historyContext,
                anchorMessage: replyThreadContext.anchorMessage,
                parentChatId: replyThreadContext.parentChatId,
                senderProfilesById,
                meId,
              })
            : historyContext
        const implicitMention =
          ((reactionEvent != null || callbackActionEvent != null) && isGroup) ||
          (isGroup &&
            (account.config.replyToBotWithoutMention ?? false) &&
            msg.replyToMsgId != null &&
            effectiveHistoryContext.repliedToBot)

        const requireMention = isGroup
          ? resolveInlineGroupRequireMention({
              cfg,
              groupId: String(effectiveChatId),
              accountId: account.accountId,
              requireMentionDefault: account.config.requireMention ?? false,
            })
          : false
        const mentionGate = resolveMentionGatingWithBypass({
          isGroup,
          requireMention,
          canDetectMention: typeof msg.mentioned === "boolean" || mentionRegexes.length > 0,
          wasMentioned,
          implicitMention,
          allowTextCommands,
          hasControlCommand,
          commandAuthorized,
        })
        if (isGroup && mentionGate.shouldSkip) {
          runtime.log?.(`inline: drop group chat ${String(chatId)} (no mention)`)
          const pendingBody =
            normalizeHistoryText(currentContent?.text) ??
            normalizeHistoryText(rawBody)
          recordPendingHistoryEntryIfEnabled({
            historyMap: groupPendingHistories,
            historyKey: groupHistoryKey ?? "",
            limit: historyLimit,
            entry:
              groupHistoryKey && pendingBody
                ? {
                    sender: pendingHistorySender,
                    body: pendingBody,
                    timestamp: messageTimestamp || Date.now(),
                    messageId: String(msg.id),
                  }
                : null,
          })
          await answerCallbackIfNeeded().catch((error) => {
            runtime.error?.(`inline callback answer failed: ${String(error)}`)
          })
          continue
        }

        const parseMarkdown = account.config.parseMarkdown ?? true
        const nativeCommandMenu = resolveInlineCompatNativeCommandMenu(normalizedCommandBody)
        if (nativeCommandMenu) {
          const menuActions = resolveInlineReplyActions({
            channelData: {
              inline: {
                buttons: nativeCommandMenu.buttons,
              },
            },
          })
          const sent = await client.sendMessage({
            chatId,
            text: nativeCommandMenu.title,
            ...(menuActions ? { actions: menuActions } : {}),
          })
          if (sent.messageId != null) {
            rememberBotMessageId(botMessageIdsByChat, chatId, sent.messageId)
          }
          statusSink?.({ lastOutboundAt: Date.now() })
          await answerCallbackIfNeeded().catch((error) => {
            runtime.error?.(`inline callback answer failed: ${String(error)}`)
          })
          continue
        }

        const inboundMedia = reactionEvent
          ? []
          : await resolveInlineInboundMedia({
              core,
              message: msg,
              maxBytes: inboundMediaMaxBytes,
              ...(log ? { log } : {}),
            })

        const timestamp = messageTimestamp
        const fromLabel = isGroup ? `chat:${effectiveGroupTitle ?? String(effectiveChatId)}` : `user:${senderId}`

        const storePath = core.channel.session.resolveStorePath(cfg.session?.store, { agentId: route.agentId })
        const envelopeOptions = core.channel.reply.resolveEnvelopeFormatOptions(cfg)
        const previousTimestamp = core.channel.session.readSessionUpdatedAt({ storePath, sessionKey: route.sessionKey })
        const combinedBody = [
          effectiveHistoryContext.historyText,
          effectiveHistoryContext.attachmentText,
          effectiveHistoryContext.entityText,
          INLINE_FORMATTING_NOTE,
          `Current message:\n${rawBody}`,
          currentAttachmentText && currentAttachmentText !== rawBody
            ? `Current media/attachments:\n${currentAttachmentText}`
            : null,
          currentEntityText ? `Current message entities:\n${currentEntityText}` : null,
        ]
          .filter(Boolean)
          .join("\n\n")
        let body = core.channel.reply.formatAgentEnvelope({
          channel: "Inline",
          from: fromLabel,
          timestamp,
          ...(previousTimestamp != null ? { previousTimestamp } : {}),
          envelope: envelopeOptions,
          body: combinedBody || rawBody,
        })
        if (isGroup && groupHistoryKey) {
          body = buildPendingHistoryContextFromMap({
            historyMap: groupPendingHistories,
            historyKey: groupHistoryKey,
            limit: historyLimit,
            currentMessage: body,
            formatEntry: (entry) =>
              core.channel.reply.formatAgentEnvelope({
                channel: "Inline",
                from: fromLabel,
                ...(entry.timestamp != null ? { timestamp: entry.timestamp } : {}),
                envelope: envelopeOptions,
                body: `${entry.body}${entry.messageId ? ` [id:${entry.messageId} chat:${String(chatId)}]` : ""}`,
              }),
          })
        }
        const inboundHistory =
          isGroup && groupHistoryKey
            ? mergeInboundHistoryEntries({
                historyContextEntries: effectiveHistoryContext.inboundHistory,
                pendingEntries: groupPendingHistories.get(groupHistoryKey) ?? [],
                limit: historyLimit,
              })
            : []
        const bodyForAgent = buildInlineBodyForAgent({
          rawBody,
          currentAttachmentText,
          currentEntityText,
        })
        const effectiveSurface = shouldUseTelegramSurfaceForModelCommands(normalizedCommandBody)
          ? "telegram"
          : CHANNEL_ID
        const systemPrompt = resolveInlineSystemPrompt({
          account,
          ...(isGroup ? { groupId: String(effectiveChatId) } : {}),
        })

        const ctxPayload = core.channel.reply.finalizeInboundContext({
          Body: body,
          BodyForAgent: bodyForAgent,
          ...(isGroup ? { InboundHistory: inboundHistory } : {}),
          RawBody: rawBody,
          CommandBody: normalizedCommandBody,
          From: isGroup ? `inline:chat:${String(effectiveChatId)}` : `inline:${senderId}`,
          To: `inline:${String(effectiveChatId)}`,
          SessionKey: route.sessionKey,
          ...(replyThreadContext ? { ParentSessionKey: route.sessionKey } : {}),
          AccountId: route.accountId,
          ChatType: isGroup ? "group" : "direct",
          ConversationLabel: fromLabel,
          ...(isGroup ? { GroupSubject: effectiveGroupTitle ?? String(effectiveChatId) } : {}),
          SenderId: senderId,
          ...(senderName ? { SenderName: senderName } : {}),
          ...(senderUsername ? { SenderUsername: senderUsername } : {}),
          Provider: CHANNEL_ID,
          Surface: effectiveSurface,
          MessageSid: String(msg.id),
          ...(replyThreadContext ? { MessageThreadId: String(replyThreadContext.childChatId) } : {}),
          ...(replyThreadContext?.threadLabel ? { ThreadLabel: replyThreadContext.threadLabel } : {}),
          ...(msg.replyToMsgId != null ? { ReplyToId: String(msg.replyToMsgId) } : {}),
          ...(effectiveHistoryContext.replyToSenderId != null ? { ReplyToSenderId: effectiveHistoryContext.replyToSenderId } : {}),
          ...(msg.replyToMsgId != null ? { ReplyToWasBot: effectiveHistoryContext.repliedToBot } : {}),
          ...(callbackActionEvent
            ? {
                MessageActionInteractionId: String(callbackActionEvent.interactionId),
                MessageActionId: callbackActionEvent.actionId,
                MessageActionDataBase64: callbackDataToBase64(callbackActionEvent.data),
                ...(callbackDataToUtf8(callbackActionEvent.data)
                  ? { MessageActionDataUtf8: callbackDataToUtf8(callbackActionEvent.data) }
                  : {}),
              }
            : {}),
          ...buildInlineInboundMediaPayload(inboundMedia),
          Timestamp: timestamp || Date.now(),
          WasMentioned: mentionGate.effectiveWasMentioned,
          CommandAuthorized: commandAuthorized,
          GroupSystemPrompt: systemPrompt,
          OriginatingChannel: CHANNEL_ID,
          OriginatingTo: `inline:${String(effectiveChatId)}`,
        })

        await core.channel.session.recordInboundSession({
          storePath,
          sessionKey: ctxPayload.SessionKey ?? route.sessionKey,
          ctx: ctxPayload,
          ...(!isGroup
            ? {
                updateLastRoute: {
                  sessionKey: route.mainSessionKey,
                  channel: CHANNEL_ID,
                  to: `inline:${String(effectiveChatId)}`,
                  accountId: route.accountId,
                },
              }
            : {}),
          onRecordError: (err) => runtime.error?.(`inline: failed updating session meta: ${String(err)}`),
        })

        const replyPipeline = await createChannelReplyPipelineCompat({
          cfg,
          agentId: route.agentId,
          channel: CHANNEL_ID,
          accountId: account.accountId,
          typing: {
            start: () => client.sendTyping({ chatId, typing: true }),
            stop: () => client.sendTyping({ chatId, typing: false }),
            onStartError: (err) => runtime.error?.(`inline typing start failed: ${String(err)}`),
            onStopError: (err) => runtime.error?.(`inline typing stop failed: ${String(err)}`),
          },
        })
        const onModelSelected = replyPipeline.onModelSelected
        const typingCallbacks = replyPipeline.typingCallbacks
        const prefixOptions = {
          ...(replyPipeline.responsePrefix !== undefined
            ? { responsePrefix: replyPipeline.responsePrefix }
            : {}),
          ...(replyPipeline.enableSlackInteractiveReplies !== undefined
            ? { enableSlackInteractiveReplies: replyPipeline.enableSlackInteractiveReplies }
            : {}),
          ...(replyPipeline.responsePrefixContextProvider
            ? {
                responsePrefixContextProvider:
                  replyPipeline.responsePrefixContextProvider as never,
              }
            : {}),
        }

        const streamViaEditMessage = account.config.streamViaEditMessage === true && !shouldEditCallbackTargetInPlace
        const defaultReplyToMsgId = isGroup && msg.replyToMsgId != null ? msg.id : undefined
        const disableBlockStreaming =
          streamViaEditMessage
            ? true
            : typeof account.config.blockStreaming === "boolean"
            ? !account.config.blockStreaming
            : undefined
        const editStreamState: InlineEditStreamState = {
          messageId: null,
          accumulatedText: "",
          lastPartialText: "",
          finalTextAccumulator: "",
          failed: false,
          opChain: Promise.resolve(),
        }
        let finalDeliveredForCurrentAssistantMessage = false
        const resetEditStreamForAssistantMessage = async (): Promise<void> => {
          await editStreamState.opChain
          const hasActiveState =
            editStreamState.messageId != null ||
            editStreamState.accumulatedText.length > 0 ||
            editStreamState.lastPartialText.length > 0 ||
            editStreamState.finalTextAccumulator.length > 0
          if (!hasActiveState) return
          editStreamState.messageId = null
          editStreamState.accumulatedText = ""
          editStreamState.lastPartialText = ""
          editStreamState.finalTextAccumulator = ""
          editStreamState.failed = false
          finalDeliveredForCurrentAssistantMessage = false
        }
        const resetEditStreamOnBoundary = async (): Promise<void> => {
          if (!streamViaEditMessage) return
          await resetEditStreamForAssistantMessage()
        }
        const handlePartialStreamPayload = async (payload: {
          text?: string
          mediaUrls?: string[]
        }): Promise<void> => {
          if (editStreamState.failed) return
          if ((payload.mediaUrls?.length ?? 0) > 0) return
          const partialText = typeof payload.text === "string" ? payload.text : ""
          if (!partialText || partialText === editStreamState.lastPartialText) return
          editStreamState.lastPartialText = partialText

          const nextText = rewriteNumericMentionsToUsernames(
            extractCompleteParagraphText(partialText),
            senderProfilesById,
          ).trim()
          if (!nextText || nextText === editStreamState.accumulatedText) return

          editStreamState.opChain = editStreamState.opChain.then(async () => {
            if (editStreamState.failed) return
            if (!nextText || nextText === editStreamState.accumulatedText) return

            try {
              if (editStreamState.messageId == null) {
                const sent = await client.sendMessage({
                  chatId,
                  text: nextText,
                  ...(defaultReplyToMsgId != null ? { replyToMsgId: defaultReplyToMsgId } : {}),
                  parseMarkdown,
                })
                if (sent.messageId == null) {
                  throw new Error("inline edit stream: sendMessage returned no messageId")
                }
                editStreamState.messageId = sent.messageId
                rememberBotMessageId(botMessageIdsByChat, chatId, sent.messageId)
              } else {
                const result = await client.invokeRaw(Method.EDIT_MESSAGE, {
                  oneofKind: "editMessage",
                  editMessage: {
                    messageId: editStreamState.messageId,
                    peerId: buildChatPeer(chatId),
                    text: nextText,
                    parseMarkdown,
                  },
                })
                if (result.oneofKind !== "editMessage") {
                  throw new Error(
                    `inline edit stream: expected editMessage result, got ${String(result.oneofKind)}`,
                  )
                }
              }
              editStreamState.accumulatedText = nextText
              statusSink?.({ lastOutboundAt: Date.now() })
            } catch (error) {
              editStreamState.failed = true
              runtime.error?.(`inline edit stream failed: ${String(error)}`)
            }
          })
          await editStreamState.opChain
        }
        const replyOptions = {
          ...(onModelSelected ? { onModelSelected: onModelSelected as (ctx: unknown) => void } : {}),
          blockReplyTimeoutMs: 25_000,
          ...(streamViaEditMessage
            ? {
                onAssistantMessageStart: async () => {
                  await resetEditStreamOnBoundary()
                },
              }
            : {}),
          ...(streamViaEditMessage
            ? {
                onPartialReply: async (payload: { text?: string; mediaUrls?: string[] }) => {
                  await handlePartialStreamPayload(payload)
                },
              }
            : {}),
          ...(streamViaEditMessage
            ? {
                onReasoningStream: async (payload: { text?: string; mediaUrls?: string[] }) => {
                  await handlePartialStreamPayload(payload)
                },
              }
            : {}),
          ...(streamViaEditMessage
            ? {
                onReasoningEnd: async () => {
                  await editStreamState.opChain
                },
              }
            : {}),
          ...(streamViaEditMessage
            ? {
                onToolStart: async () => {
                  await resetEditStreamOnBoundary()
                },
              }
            : {}),
          ...(streamViaEditMessage
            ? {
                onCompactionStart: async () => {
                  await resetEditStreamOnBoundary()
                },
              }
            : {}),
          ...(streamViaEditMessage
            ? {
                onCompactionEnd: async () => {
                  await resetEditStreamOnBoundary()
                },
              }
            : {}),
          ...(typeof disableBlockStreaming === "boolean" ? { disableBlockStreaming } : {}),
        }

        try {
          let delivered = false
          let skippedNonSilent = false
          let failedNonSilent = false
          let dispatchError: unknown = null
          try {
            await core.channel.reply.dispatchReplyWithBufferedBlockDispatcher({
            ctx: ctxPayload,
            cfg,
            dispatcherOptions: {
              ...prefixOptions,
              ...(typingCallbacks ? { typingCallbacks } : {}),
              deliver: async (
                payload: {
                  text?: string
                  mediaUrl?: string
                  mediaUrls?: string[]
                  replyToId?: string
                  channelData?: Record<string, unknown>
                },
                info?: InlineDispatchReplyInfo,
              ) => {
                const rawText = payload.text ?? ""
                const mediaList = payload.mediaUrls?.length
                  ? payload.mediaUrls
                  : payload.mediaUrl
                    ? [payload.mediaUrl]
                    : []
                const outboundText = rewriteNumericMentionsToUsernames(rawText, senderProfilesById)
                const outboundActions = resolveInlineReplyActions(payload as Record<string, unknown>)
                const infoKind = typeof info?.kind === "string" ? info.kind : undefined

                let replyToMsgId: bigint | undefined
                if (payload.replyToId != null) {
                  try {
                    replyToMsgId = BigInt(payload.replyToId)
                  } catch {
                    // ignore
                  }
                }
                // Keep reply chains threaded when inbound is a reply in group chats.
                if (replyToMsgId == null && isGroup && msg.replyToMsgId != null) {
                  replyToMsgId = msg.id
                }

                const rememberSent = (messageId: bigint | null) => {
                  if (messageId != null) {
                    rememberBotMessageId(botMessageIdsByChat, chatId, messageId)
                  }
                }

                const sendTextFallback = async (
                  text: string,
                  includeReplyTo: boolean,
                  includeActions: boolean,
                ): Promise<void> => {
                  if (!text.trim()) return
                  const sent = await client.sendMessage({
                    chatId,
                    text,
                    ...(includeReplyTo && replyToMsgId != null ? { replyToMsgId } : {}),
                    ...(includeActions && outboundActions !== undefined ? { actions: outboundActions } : {}),
                    parseMarkdown,
                  })
                  rememberSent(sent.messageId)
                  delivered = true
                }

                const updateStreamedMessage = async (text: string, actions?: MessageActions): Promise<boolean> => {
                  await editStreamState.opChain
                  if (editStreamState.messageId == null) return false
                  const nextText = text.trim()
                  const textForEdit = nextText || editStreamState.accumulatedText
                  if (!textForEdit) return true
                  const shouldSkipTextUpdate =
                    !editStreamState.failed && textForEdit === editStreamState.accumulatedText
                  if (shouldSkipTextUpdate && actions === undefined) return true

                  const result = await client.invokeRaw(Method.EDIT_MESSAGE, {
                    oneofKind: "editMessage",
                    editMessage: {
                      messageId: editStreamState.messageId,
                      peerId: buildChatPeer(chatId),
                      text: textForEdit,
                      parseMarkdown,
                      ...(actions !== undefined ? { actions } : {}),
                    },
                  })
                  if (result.oneofKind !== "editMessage") {
                    throw new Error(
                      `inline edit stream: expected editMessage result, got ${String(result.oneofKind)}`,
                    )
                  }
                  if (!shouldSkipTextUpdate) {
                    editStreamState.accumulatedText = textForEdit
                    editStreamState.lastPartialText = textForEdit
                  }
                  editStreamState.failed = false
                  return true
                }

                if (mediaList.length === 0) {
                  if (
                    streamViaEditMessage &&
                    infoKind === "final" &&
                    finalDeliveredForCurrentAssistantMessage &&
                    editStreamState.messageId != null
                  ) {
                    await resetEditStreamForAssistantMessage()
                  }
                  if (streamViaEditMessage && editStreamState.messageId != null) {
                    if (outboundText.trim()) {
                      editStreamState.finalTextAccumulator += outboundText
                    }
                    if (!editStreamState.finalTextAccumulator.trim() && outboundActions === undefined) {
                      return
                    }
                    await updateStreamedMessage(editStreamState.finalTextAccumulator, outboundActions)
                    delivered = true
                    if (infoKind === "final") {
                      finalDeliveredForCurrentAssistantMessage = true
                    }
                    statusSink?.({ lastOutboundAt: Date.now() })
                    return
                  }
                  if (!outboundText.trim()) return
                  await sendTextFallback(outboundText, true, true)
                  statusSink?.({ lastOutboundAt: Date.now() })
                  return
                }

                if (streamViaEditMessage && editStreamState.messageId != null && outboundText.trim()) {
                  await updateStreamedMessage(outboundText, outboundActions)
                }

                for (let index = 0; index < mediaList.length; index++) {
                  const mediaUrl = mediaList[index]
                  if (!mediaUrl?.trim()) continue
                  const isFirst = index === 0
                  const shouldAttachActionsToMedia =
                    isFirst && (!(streamViaEditMessage && editStreamState.messageId != null) || !outboundText.trim())
                  const caption =
                    isFirst && !(streamViaEditMessage && editStreamState.messageId != null) ? outboundText : ""
                  try {
                    const media = await uploadInlineMediaFromUrl({
                      client,
                      cfg,
                      accountId: account.accountId,
                      mediaUrl,
                    })
                    const sent = await client.sendMessage({
                      chatId,
                      ...(caption ? { text: caption } : {}),
                      media,
                      ...(isFirst && replyToMsgId != null ? { replyToMsgId } : {}),
                      ...(shouldAttachActionsToMedia && outboundActions !== undefined
                        ? { actions: outboundActions }
                        : {}),
                      ...(caption ? { parseMarkdown } : {}),
                    })
                    rememberSent(sent.messageId)
                    delivered = true
                  } catch (error) {
                    runtime.error?.(`inline media upload failed; falling back to url text (${String(error)})`)
                    const fallbackText = caption
                      ? `${caption}\n\nAttachment: ${mediaUrl}`
                      : `Attachment: ${mediaUrl}`
                    await sendTextFallback(fallbackText, isFirst, isFirst)
                  }
                }

                statusSink?.({ lastOutboundAt: Date.now() })
              },
              onSkip: (_payload, info) => {
                if (info?.reason !== "silent") {
                  skippedNonSilent = true
                }
              },
              onError: (err, info) => {
                failedNonSilent = true
                runtime.error?.(`inline ${info?.kind ?? "final"} reply failed: ${String(err)}`)
              },
            },
            replyOptions,
          })
          } catch (error) {
            dispatchError = error
            runtime.error?.(`inline dispatch failed: ${String(error)}`)
          }

          if (!delivered && streamViaEditMessage && editStreamState.messageId != null) {
            delivered = true
          }
          if (!delivered && (dispatchError != null || skippedNonSilent || failedNonSilent)) {
            const fallbackText =
              dispatchError != null
                ? "Something went wrong while processing your request. Please try again."
                : EMPTY_RESPONSE_FALLBACK
            const sent = await client.sendMessage({
              chatId,
              text: fallbackText,
              ...(defaultReplyToMsgId != null ? { replyToMsgId: defaultReplyToMsgId } : {}),
              parseMarkdown,
            })
            if (sent.messageId != null) {
              rememberBotMessageId(botMessageIdsByChat, chatId, sent.messageId)
            }
            statusSink?.({ lastOutboundAt: Date.now() })
          }
        } finally {
          if (callbackActionEvent && !callbackActionAnswered) {
            try {
              await answerCallbackIfNeeded()
            } catch (error) {
              runtime.error?.(`inline callback answer failed: ${String(error)}`)
            }
          }
        }
        if (isGroup && groupHistoryKey) {
          clearHistoryEntriesIfEnabled({
            historyMap: groupPendingHistories,
            historyKey: groupHistoryKey,
            limit: historyLimit,
          })
        }
      }
    } catch (err) {
      statusSink?.({ lastError: String(err) })
      runtime.error?.(`inline monitor loop crashed: ${String(err)}`)
    }
  })()

  let stopPromise: Promise<void> | null = null
  const stop = async () => {
    if (stopPromise) {
      await stopPromise
      return
    }
    stopPromise = (async () => {
      await client.close().catch(() => {})
      await loop.catch(() => {})
    })()
    await stopPromise
  }

  abortSignal.addEventListener(
    "abort",
    () => {
      void stop()
    },
    { once: true },
  )

  return { stop, done: loop.catch(() => {}) }
}
