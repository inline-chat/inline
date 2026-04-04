import type {
  ChannelMessageActionAdapter,
  ChannelMessageActionName,
  ChannelMessageToolDiscovery,
  ChannelMessageToolSchemaContribution,
} from "openclaw/plugin-sdk/channel-contract"
import type { OpenClawConfig } from "openclaw/plugin-sdk/core"
import {
  InlineSdkClient,
  Method,
  type Chat,
  type Dialog,
  type Message,
  type MessageActions,
  type User,
} from "@inline-chat/realtime-sdk"
import { resolveInlineAccount, resolveInlineToken } from "./accounts.js"
import { isInlineReplyThreadsEnabled } from "./reply-threads.js"
import { uploadInlineMediaFromUrl } from "./media.js"
import { summarizeInlineMessageContent } from "./message-content.js"
import { normalizeInlineTarget } from "./normalize.js"
import { buildInlineUserDisplayName, getSpaceMembersWithUsers } from "./space-members.js"
import {
  createActionGate,
  jsonResult,
  readReactionParams,
  readNumberParam,
  readStringParam,
} from "../openclaw-compat.js"
import { createMessageToolButtonsSchemaCompat } from "../sdk-runtime-compat.js"

type InlineActionGateKey =
  | "send"
  | "reply"
  | "reactions"
  | "read"
  | "search"
  | "edit"
  | "channels"
  | "participants"
  | "delete"
  | "pins"
  | "permissions"

const ACTION_GROUPS: Array<{
  key: InlineActionGateKey
  defaultEnabled: boolean
  actions: ChannelMessageActionName[]
}> = [
  { key: "send", defaultEnabled: true, actions: ["send", "sendAttachment"] },
  { key: "reply", defaultEnabled: true, actions: ["reply", "thread-reply"] },
  { key: "reactions", defaultEnabled: true, actions: ["react", "reactions"] },
  { key: "read", defaultEnabled: true, actions: ["read"] },
  { key: "search", defaultEnabled: true, actions: ["search"] },
  { key: "edit", defaultEnabled: true, actions: ["edit"] },
  {
    key: "channels",
    defaultEnabled: true,
    actions: [
      "channel-info",
      "channel-edit",
      "renameGroup",
      "channel-list",
      "channel-create",
      "channel-delete",
      "channel-move",
      "thread-list",
      "thread-create",
    ],
  },
  {
    key: "participants",
    defaultEnabled: true,
    actions: ["addParticipant", "removeParticipant", "kick", "leaveGroup", "member-info"],
  },
  { key: "delete", defaultEnabled: true, actions: ["delete", "unsend"] },
  { key: "pins", defaultEnabled: true, actions: ["pin", "unpin", "list-pins"] },
  { key: "permissions", defaultEnabled: true, actions: ["permissions"] },
]

const ACTION_TO_GATE_KEY = new Map<ChannelMessageActionName, InlineActionGateKey>()
for (const group of ACTION_GROUPS) {
  for (const action of group.actions) {
    ACTION_TO_GATE_KEY.set(action, group.key)
  }
}

const SUPPORTED_ACTIONS = Array.from(ACTION_TO_GATE_KEY.keys())
const GET_MESSAGES_METHOD =
  typeof (Method as Record<string, unknown>).GET_MESSAGES === "number" &&
  Number.isInteger((Method as Record<string, unknown>).GET_MESSAGES) &&
  ((Method as Record<string, unknown>).GET_MESSAGES as number) > 0
    ? ((Method as Record<string, unknown>).GET_MESSAGES as Method)
    : null
const CREATE_SUBTHREAD_METHOD =
  typeof (Method as Record<string, unknown>).CREATE_SUBTHREAD === "number" &&
  Number.isInteger((Method as Record<string, unknown>).CREATE_SUBTHREAD) &&
  ((Method as Record<string, unknown>).CREATE_SUBTHREAD as number) > 0
    ? ((Method as Record<string, unknown>).CREATE_SUBTHREAD as Method)
    : (43 as Method)

const INLINE_ACTION_MAX_ROWS = 8
const INLINE_ACTION_MAX_PER_ROW = 8

type InlineReplyMarkupButton = {
  text: string
  callback_data: string
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null
}

function normalizeReplyMarkupButtons(raw: unknown): InlineReplyMarkupButton[][] {
  if (!Array.isArray(raw)) return []
  const rows: InlineReplyMarkupButton[][] = []
  for (const candidateRow of raw) {
    if (!Array.isArray(candidateRow)) continue
    const row: InlineReplyMarkupButton[] = []
    for (const candidateButton of candidateRow) {
      if (!isRecord(candidateButton)) continue
      const text = typeof candidateButton.text === "string" ? candidateButton.text.trim() : ""
      const callbackData =
        typeof candidateButton.callback_data === "string" ? candidateButton.callback_data.trim() : ""
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

function resolveInlineMessageActionsParam(params: Record<string, unknown>): MessageActions | undefined {
  if (!Object.prototype.hasOwnProperty.call(params, "buttons")) {
    return undefined
  }

  let rawButtons: unknown = params.buttons
  if (typeof rawButtons === "string") {
    const trimmed = rawButtons.trim()
    if (!trimmed) {
      rawButtons = []
    } else {
      try {
        rawButtons = JSON.parse(trimmed) as unknown
      } catch {
        throw new Error("inline action: buttons must be valid JSON")
      }
    }
  }
  if (rawButtons == null) {
    rawButtons = []
  }
  if (!Array.isArray(rawButtons)) {
    throw new Error("inline action: buttons must be an array of button rows")
  }

  const rows = normalizeReplyMarkupButtons(rawButtons)
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

function normalizeChatId(raw: string): string {
  const normalized = normalizeInlineTarget(raw) ?? raw.trim()
  if (!/^[0-9]+$/.test(normalized)) {
    throw new Error(`inline action: invalid chat target "${raw}" (expected numeric chat id)`)
  }
  return normalized
}

function readFlexibleId(params: Record<string, unknown>, key: string): string | undefined {
  const direct = params[key]
  if (typeof direct === "bigint") return direct.toString()
  if (typeof direct === "number") {
    if (!Number.isFinite(direct) || !Number.isInteger(direct)) return undefined
    return String(direct)
  }
  if (typeof direct === "string") {
    const trimmed = direct.trim()
    return trimmed || undefined
  }
  return undefined
}

function readBooleanParam(params: Record<string, unknown>, key: string): boolean | undefined {
  const value = params[key]
  if (typeof value === "boolean") return value
  if (typeof value === "string") {
    const trimmed = value.trim().toLowerCase()
    if (trimmed === "true") return true
    if (trimmed === "false") return false
  }
  return undefined
}

function parseInlineId(raw: unknown, label: string): bigint {
  if (typeof raw === "bigint") {
    if (raw < 0n) {
      throw new Error(`inline action: invalid ${label} "${raw.toString()}"`)
    }
    return raw
  }
  if (typeof raw === "number") {
    if (!Number.isFinite(raw) || !Number.isInteger(raw) || raw < 0) {
      throw new Error(`inline action: invalid ${label} "${String(raw)}"`)
    }
    return BigInt(raw)
  }
  if (typeof raw === "string") {
    const trimmed = raw.trim()
    if (!trimmed) {
      throw new Error(`inline action: missing ${label}`)
    }
    if (!/^[0-9]+$/.test(trimmed)) {
      if (/message/i.test(label)) {
        const prefixed = trimmed.match(/^(?:message|msg)\s*#?\s*([0-9]+)$/i)?.[1]
        if (prefixed) {
          return BigInt(prefixed)
        }
      }
      throw new Error(`inline action: invalid ${label} "${raw}"`)
    }
    return BigInt(trimmed)
  }
  throw new Error(`inline action: missing ${label}`)
}

function resolveReactionMessageId(params: {
  args: Record<string, unknown>
  toolContext?: { currentMessageId?: string | number | null }
}): string | undefined {
  const explicit =
    readFlexibleId(params.args, "messageId") ??
    readStringParam(params.args, "messageId")
  if (explicit) {
    return explicit
  }
  const fromContext = params.toolContext?.currentMessageId
  if (typeof fromContext === "number" && Number.isFinite(fromContext)) {
    return String(Math.trunc(fromContext))
  }
  if (typeof fromContext === "string") {
    const trimmed = fromContext.trim()
    return trimmed || undefined
  }
  return undefined
}

function parseOptionalInlineId(raw: unknown, label: string): bigint | undefined {
  if (raw == null) return undefined
  return parseInlineId(raw, label)
}

function parseInlineIdList(raw: unknown, label: string): bigint[] {
  if (raw == null) return []
  if (Array.isArray(raw)) {
    return raw.map((item) => parseInlineId(item, label))
  }
  if (typeof raw === "string") {
    const trimmed = raw.trim()
    if (!trimmed) return []
    const chunks = trimmed
      .split(",")
      .map((item) => item.trim())
      .filter(Boolean)
    if (chunks.length <= 1) {
      return [parseInlineId(trimmed, label)]
    }
    return chunks.map((item) => parseInlineId(item, label))
  }
  return [parseInlineId(raw, label)]
}

function parseInlineIdListFromParams(params: Record<string, unknown>, key: string): bigint[] {
  const direct = params[key]
  if (direct != null) {
    return parseInlineIdList(direct, key)
  }
  return []
}

function parseInlineListValue(raw: unknown, label: string): string[] {
  if (raw == null) return []
  if (Array.isArray(raw)) {
    return raw.flatMap((entry) => parseInlineListValue(entry, label))
  }
  if (typeof raw === "bigint") return [raw.toString()]
  if (typeof raw === "number") {
    if (!Number.isFinite(raw) || !Number.isInteger(raw) || raw < 0) {
      throw new Error(`inline action: invalid ${label} "${String(raw)}"`)
    }
    return [String(raw)]
  }
  if (typeof raw === "string") {
    const trimmed = raw.trim()
    if (!trimmed) return []
    return trimmed
      .split(",")
      .map((entry) => entry.trim())
      .filter(Boolean)
  }
  throw new Error(`inline action: invalid ${label}`)
}

function parseInlineListValuesFromParams(params: Record<string, unknown>, keys: string[]): string[] {
  const entries = keys.flatMap((key) => parseInlineListValue(params[key], key))
  return Array.from(new Set(entries.map((entry) => entry.trim()).filter(Boolean)))
}

function resolveInlineOutboundMediaInputs(params: Record<string, unknown>): string[] {
  const plural = parseInlineListValuesFromParams(params, [
    "mediaUrls",
    "attachmentUrls",
    "filePaths",
    "paths",
    "files",
  ])
  const single = parseInlineListValuesFromParams(params, [
    "mediaUrl",
    "attachmentUrl",
    "url",
    "media",
    "filePath",
    "path",
    "file",
  ])
  return Array.from(new Set([...plural, ...single]))
}

function normalizeInlineUserLookupToken(raw: string): string {
  return raw
    .trim()
    .replace(/^inline:/i, "")
    .replace(/^user:/i, "")
    .replace(/^@/, "")
    .trim()
}

function parseInlineIdIfNumericToken(raw: string): bigint | undefined {
  const normalized = normalizeInlineUserLookupToken(raw)
  if (!/^[0-9]+$/.test(normalized)) return undefined
  return BigInt(normalized)
}

function buildInlineUserHaystack(user: User): string {
  return [
    String(user.id),
    buildInlineUserDisplayName(user),
    user.firstName ?? "",
    user.lastName ?? "",
    user.username ?? "",
  ]
    .join("\n")
    .toLowerCase()
}

function resolveInlineUsersByToken(params: { users: User[]; token: string }): User[] {
  const normalized = normalizeInlineUserLookupToken(params.token)
  if (!normalized) return []
  const lowered = normalized.toLowerCase()

  const numericId = parseInlineIdIfNumericToken(normalized)
  if (numericId != null) {
    return params.users.filter((user) => user.id === numericId)
  }

  const byUsername = params.users.filter((user) => (user.username ?? "").trim().toLowerCase() === lowered)
  if (byUsername.length > 0) {
    return byUsername
  }

  const byExactName = params.users.filter(
    (user) => buildInlineUserDisplayName(user).trim().toLowerCase() === lowered,
  )
  if (byExactName.length > 0) {
    return byExactName
  }

  return params.users.filter((user) => buildInlineUserHaystack(user).includes(lowered))
}

async function fetchInlineUsersForResolution(client: InlineSdkClient): Promise<User[]> {
  const result = await client.invokeRaw(Method.GET_CHATS, {
    oneofKind: "getChats",
    getChats: {},
  })
  if (result.oneofKind !== "getChats") {
    throw new Error(`inline action: expected getChats result, got ${String(result.oneofKind)}`)
  }
  return result.getChats.users ?? []
}

async function resolveInlineUserIdsFromParams(params: {
  client: InlineSdkClient
  values: string[]
  label: string
}): Promise<bigint[]> {
  if (params.values.length === 0) return []

  const resolved: bigint[] = []
  const unresolved: string[] = []
  for (const value of params.values) {
    const numericId = parseInlineIdIfNumericToken(value)
    if (numericId != null) {
      resolved.push(numericId)
      continue
    }
    unresolved.push(value)
  }

  if (unresolved.length > 0) {
    const users = await fetchInlineUsersForResolution(params.client)
    for (const token of unresolved) {
      const matches = resolveInlineUsersByToken({ users, token })
      if (matches.length === 0) {
        throw new Error(`inline action: could not resolve ${params.label} "${token}"`)
      }
      if (matches.length > 1) {
        throw new Error(`inline action: ambiguous ${params.label} "${token}"`)
      }
      const match = matches[0]
      if (!match) {
        throw new Error(`inline action: could not resolve ${params.label} "${token}"`)
      }
      resolved.push(match.id)
    }
  }

  return Array.from(new Set(resolved.map((id) => id.toString()))).map((id) => BigInt(id))
}

function resolveChatIdFromParams(params: Record<string, unknown>): bigint {
  const raw =
    readFlexibleId(params, "chatId") ??
    readFlexibleId(params, "channelId") ??
    readFlexibleId(params, "to") ??
    readStringParam(params, "to")
  if (!raw) {
    throw new Error("inline action requires chatId/channelId/to")
  }
  return BigInt(normalizeChatId(raw))
}

function resolveMessageSendTargetFromParams(params: Record<string, unknown>): {
  target: string
  chatId?: bigint
  userId?: bigint
} {
  const explicitUserIdRaw = readFlexibleId(params, "userId") ?? readStringParam(params, "userId")
  if (explicitUserIdRaw) {
    const userId = parseInlineId(explicitUserIdRaw, "userId")
    return {
      target: `user:${String(userId)}`,
      userId,
    }
  }

  const rawTarget = readFlexibleId(params, "to") ?? readStringParam(params, "to")
  if (rawTarget) {
    const normalized = normalizeInlineTarget(rawTarget) ?? rawTarget.trim()
    const userMatch = normalized.match(/^user:([0-9]+)$/i)
    if (userMatch?.[1]) {
      return {
        target: `user:${userMatch[1]}`,
        userId: BigInt(userMatch[1]),
      }
    }
    if (!/^[0-9]+$/.test(normalized)) {
      throw new Error(`inline action: invalid target "${rawTarget}"`)
    }
    return {
      target: normalized,
      chatId: BigInt(normalized),
    }
  }

  const rawChatId =
    readFlexibleId(params, "chatId") ??
    readStringParam(params, "chatId") ??
    readFlexibleId(params, "channelId") ??
    readStringParam(params, "channelId")
  if (!rawChatId) {
    throw new Error("inline action requires to/chatId/channelId/userId")
  }

  const normalized = normalizeInlineTarget(rawChatId) ?? rawChatId.trim()
  const userMatch = normalized.match(/^user:([0-9]+)$/i)
  if (userMatch?.[1]) {
    return {
      target: `user:${userMatch[1]}`,
      userId: BigInt(userMatch[1]),
    }
  }
  if (!/^[0-9]+$/.test(normalized)) {
    throw new Error(`inline action: invalid target "${rawChatId}"`)
  }
  return {
    target: normalized,
    chatId: BigInt(normalized),
  }
}

function buildChatPeer(chatId: bigint) {
  return {
    type: {
      oneofKind: "chat" as const,
      chat: { chatId },
    },
  }
}

function mapMessage(message: {
  id: bigint
  fromId: bigint
  date: bigint
  message?: string
  out?: boolean
  replyToMsgId?: bigint
  media?: Message["media"]
  attachments?: Message["attachments"]
  entities?: Message["entities"]
  reactions?: {
    reactions?: Array<{
      emoji?: string
      userId: bigint
      messageId: bigint
      chatId: bigint
      date: bigint
    }>
  }
}) {
  const content = summarizeInlineMessageContent(message as Message)
  const reactions = (message.reactions?.reactions ?? []).map((reaction) => ({
    emoji: reaction.emoji ?? "",
    userId: String(reaction.userId),
    messageId: String(reaction.messageId),
    chatId: String(reaction.chatId),
    date: Number(reaction.date) * 1000,
  }))

  return {
    id: String(message.id),
    fromId: String(message.fromId),
    date: Number(message.date) * 1000,
    text: content.text,
    rawText: content.rawText,
    attachmentText: content.attachmentText,
    entityText: content.entityText,
    out: Boolean(message.out),
    replyToId: message.replyToMsgId != null ? String(message.replyToMsgId) : undefined,
    attachmentUrls: content.attachmentUrls,
    links: content.links,
    media: content.media,
    attachments: content.attachments,
    entities: content.entities,
    reactions,
  }
}

function mapChatEntry(params: {
  chat: Chat
  dialogByChatId: Map<string, Dialog>
  usersById: Map<string, User>
}) {
  const dialog = params.dialogByChatId.get(String(params.chat.id))
  const peer = params.chat.peerId?.type
  let peerUser: User | null = null
  if (peer?.oneofKind === "user") {
    peerUser = params.usersById.get(String(peer.user.userId)) ?? null
  }

  return {
    id: String(params.chat.id),
    title: params.chat.title,
    spaceId: params.chat.spaceId != null ? String(params.chat.spaceId) : null,
    isPublic: params.chat.isPublic ?? false,
    createdBy: params.chat.createdBy != null ? String(params.chat.createdBy) : null,
    date: params.chat.date != null ? Number(params.chat.date) * 1000 : null,
    unreadCount: dialog?.unreadCount ?? 0,
    archived: Boolean(dialog?.archived),
    pinned: Boolean(dialog?.pinned),
    peer:
      peer?.oneofKind === "user"
        ? {
            kind: "user",
            id: String(peer.user.userId),
            username: peerUser?.username ?? null,
            name: peerUser ? buildInlineUserDisplayName(peerUser) : null,
          }
        : peer?.oneofKind === "chat"
          ? { kind: "chat", id: String(peer.chat.chatId) }
          : null,
  }
}

async function loadMessageReactions(params: {
  client: InlineSdkClient
  chatId: bigint
  messageId: bigint
}): Promise<Array<{ emoji: string; count: number; userIds: string[] }>> {
  const target = await findMessageById({
    client: params.client,
    chatId: params.chatId,
    messageId: params.messageId,
  })
  if (!target) {
    return []
  }

  const byEmoji = new Map<string, { emoji: string; count: number; userIds: string[] }>()
  for (const reaction of target.reactions?.reactions ?? []) {
    const emoji = reaction.emoji ?? ""
    if (!emoji) continue
    const existing = byEmoji.get(emoji)
    if (existing) {
      existing.count += 1
      existing.userIds.push(String(reaction.userId))
      continue
    }
    byEmoji.set(emoji, {
      emoji,
      count: 1,
      userIds: [String(reaction.userId)],
    })
  }
  return Array.from(byEmoji.values())
}

function getErrorMessage(error: unknown): string {
  if (error instanceof Error) return error.message
  if (typeof error === "string") return error
  if (error && typeof error === "object" && "message" in error && typeof error.message === "string") {
    return error.message
  }
  return String(error)
}

function isDuplicateReactionError(error: unknown): boolean {
  const text = getErrorMessage(error).toLowerCase()
  return (
    text.includes("unique_reaction_per_emoji") ||
    (text.includes("duplicate") && text.includes("reaction")) ||
    text.includes("duplicate key value violates unique constraint")
  )
}

async function reactionAlreadyExists(params: {
  client: InlineSdkClient
  chatId: bigint
  messageId: bigint
  emoji: string
}): Promise<boolean> {
  const me = await params.client.getMe().catch(() => null)
  if (!me?.userId) return false
  const myId = String(me.userId)
  const reactions = await loadMessageReactions(params).catch(() => [])
  return reactions.some((reaction) => reaction.emoji === params.emoji && reaction.userIds.includes(myId))
}

async function findMessageById(params: {
  client: InlineSdkClient
  chatId: bigint
  messageId: bigint
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
    return (directResult.getMessages.messages ?? []).find((message) => message.id === params.messageId) ?? null
  }

  const result = await params.client.invokeRaw(Method.GET_CHAT_HISTORY, {
    oneofKind: "getChatHistory",
    getChatHistory: {
      peerId: buildChatPeer(params.chatId),
      offsetId: params.messageId + 1n,
      limit: 8,
    },
  })
  if (result.oneofKind !== "getChatHistory") {
    throw new Error(`inline action: expected getChatHistory result, got ${String(result.oneofKind)}`)
  }
  return (result.getChatHistory.messages ?? []).find((message) => message.id === params.messageId) ?? null
}

async function withInlineClient<T>(params: {
  cfg: OpenClawConfig
  accountId: string | null | undefined
  fn: (client: InlineSdkClient) => Promise<T>
}): Promise<T> {
  const account = resolveInlineAccount({ cfg: params.cfg, accountId: params.accountId ?? null })
  if (!account.configured || !account.baseUrl) {
    throw new Error(`Inline not configured for account "${account.accountId}" (missing token or baseUrl)`)
  }
  const token = await resolveInlineToken(account)
  const client = new InlineSdkClient({
    baseUrl: account.baseUrl,
    token,
  })
  await client.connect()
  try {
    return await params.fn(client)
  } finally {
    await client.close().catch(() => {})
  }
}

function toJsonSafe(value: unknown): unknown {
  if (typeof value === "bigint") return value.toString()
  if (Array.isArray(value)) return value.map((item) => toJsonSafe(item))
  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {}
    for (const [key, current] of Object.entries(value as Record<string, unknown>)) {
      out[key] = toJsonSafe(current)
    }
    return out
  }
  return value
}

function buildDialogMap(dialogs: Dialog[]): Map<string, Dialog> {
  const map = new Map<string, Dialog>()
  for (const dialog of dialogs) {
    const chatId = dialog.chatId
    if (chatId != null) {
      map.set(String(chatId), dialog)
      continue
    }
    const peer = dialog.peer?.type
    if (peer?.oneofKind === "chat") {
      map.set(String(peer.chat.chatId), dialog)
    }
  }
  return map
}

function buildUserMap(users: User[]): Map<string, User> {
  const map = new Map<string, User>()
  for (const user of users) {
    map.set(String(user.id), user)
  }
  return map
}

async function resolveSpaceIdFromParams(params: {
  client: InlineSdkClient
  action: string
  rawParams: Record<string, unknown>
}): Promise<bigint> {
  const directSpaceId = parseOptionalInlineId(
    readFlexibleId(params.rawParams, "spaceId") ??
      readFlexibleId(params.rawParams, "space") ??
      readStringParam(params.rawParams, "spaceId"),
    "spaceId",
  )
  if (directSpaceId != null) return directSpaceId

  const chatTarget =
    readFlexibleId(params.rawParams, "chatId") ??
    readFlexibleId(params.rawParams, "channelId") ??
    readFlexibleId(params.rawParams, "to") ??
    readStringParam(params.rawParams, "to")
  if (!chatTarget) {
    throw new Error(`inline action: ${params.action} requires spaceId (or a chat target in a space)`)
  }

  const chatId = BigInt(normalizeChatId(chatTarget))
  const chatResult = await params.client.invokeRaw(Method.GET_CHAT, {
    oneofKind: "getChat",
    getChat: { peerId: buildChatPeer(chatId) },
  })
  if (chatResult.oneofKind !== "getChat") {
    throw new Error(`inline action: expected getChat result, got ${String(chatResult.oneofKind)}`)
  }

  const inferredSpaceId = chatResult.getChat.chat?.spaceId ?? chatResult.getChat.dialog?.spaceId
  if (inferredSpaceId == null) {
    throw new Error(`inline action: ${params.action} requires a spaceId or a chat that belongs to a space`)
  }
  return inferredSpaceId
}

function listAllActions(): ChannelMessageActionName[] {
  const out = new Set<ChannelMessageActionName>()
  for (const group of ACTION_GROUPS) {
    for (const action of group.actions) {
      out.add(action)
    }
  }
  return Array.from(out)
}

function listEnabledInlineActions(cfg: OpenClawConfig): ChannelMessageActionName[] {
  const account = resolveInlineAccount({ cfg, accountId: null })
  if (!account.enabled || !account.configured) return []

  const gate = createActionGate((account.config.actions ?? {}) as Record<string, boolean | undefined>)
  const actions = new Set<ChannelMessageActionName>()
  for (const group of ACTION_GROUPS) {
    if (!gate(group.key, group.defaultEnabled)) continue
    for (const action of group.actions) {
      actions.add(action)
    }
  }
  return Array.from(actions)
}

function supportsInlineMessageButtons(actions: readonly ChannelMessageActionName[]): boolean {
  return actions.some((action) => action === "send" || action === "reply" || action === "thread-reply" || action === "edit")
}

function describeInlineMessageTool({
  cfg,
}: Parameters<NonNullable<ChannelMessageActionAdapter["describeMessageTool"]>>[0]): ChannelMessageToolDiscovery {
  const actions = listEnabledInlineActions(cfg)
  if (actions.length === 0) {
    return {
      actions: [],
      capabilities: [],
      schema: null,
    }
  }

  const buttonsEnabled = supportsInlineMessageButtons(actions)
  const capabilities: Array<"interactive" | "buttons"> = buttonsEnabled ? ["interactive", "buttons"] : []
  const schema: ChannelMessageToolSchemaContribution[] = buttonsEnabled
    ? [
        {
          properties: {
            buttons: createMessageToolButtonsSchemaCompat() as unknown as ChannelMessageToolSchemaContribution["properties"][string],
          },
        },
      ]
    : []

  return {
    actions,
    capabilities,
    schema,
  }
}

function isActionEnabled(params: {
  cfg: OpenClawConfig
  accountId?: string | null
  action: ChannelMessageActionName
}): boolean {
  const key = ACTION_TO_GATE_KEY.get(params.action)
  if (!key) return false
  const group = ACTION_GROUPS.find((item) => item.key === key)
  if (!group) return false
  const account = resolveInlineAccount({
    cfg: params.cfg,
    accountId: params.accountId ?? null,
  })
  const gate = createActionGate((account.config.actions ?? {}) as Record<string, boolean | undefined>)
  return gate(key, group.defaultEnabled)
}

type LegacyInlineMessageActionAdapter = {
  listActions?: (params: { cfg: OpenClawConfig }) => ChannelMessageActionName[]
  supportsButtons?: (params: { cfg: OpenClawConfig }) => boolean
  supportsCards?: (params: { cfg: OpenClawConfig }) => boolean
}

export const inlineMessageActions = {
  describeMessageTool: describeInlineMessageTool,
  listActions: ({ cfg }: { cfg: OpenClawConfig }) => listEnabledInlineActions(cfg),
  supportsButtons: ({ cfg }: { cfg: OpenClawConfig }) =>
    supportsInlineMessageButtons(listEnabledInlineActions(cfg)),
  supportsCards: () => false,
  supportsAction: ({ action }) => SUPPORTED_ACTIONS.includes(action),
  extractToolSend: ({ args }) => {
    const action = typeof args.action === "string" ? args.action.trim() : ""
    if (action !== "sendMessage") return null
    const to = typeof args.to === "string" ? args.to.trim() : ""
    if (!to) return null
    const normalized = normalizeInlineTarget(to) ?? to
    if (!/^(user:)?[0-9]+$/i.test(normalized)) return null
    return { to: normalized }
  },
  handleAction: async ({ action, params, cfg, accountId, toolContext }) => {
    if (!SUPPORTED_ACTIONS.includes(action)) {
      throw new Error(`Action ${action} is not supported for provider inline.`)
    }
    if (!isActionEnabled({ cfg, accountId: accountId ?? null, action })) {
      if (action === "react") {
        return jsonResult({
          ok: false,
          reason: "disabled",
          hint: "Inline reactions are disabled via channels.inline.actions.reactions. Do not retry.",
        })
      }
      throw new Error(`inline action: ${action} is disabled by channels.inline.actions`)
    }

    const normalizedAction: ChannelMessageActionName = action

    if (normalizedAction === "send" || normalizedAction === "sendAttachment") {
      const parseMarkdown =
        resolveInlineAccount({ cfg, accountId: accountId ?? null }).config.parseMarkdown ?? true
      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client) => {
          const target = resolveMessageSendTargetFromParams(params)
          const actions = resolveInlineMessageActionsParam(params)
          const sendTarget =
            target.chatId != null ? { chatId: target.chatId } : target.userId != null ? { userId: target.userId } : null
          if (!sendTarget) {
            throw new Error("inline action: missing message target")
          }
          const mediaSources = resolveInlineOutboundMediaInputs(params)
          const text =
            readStringParam(params, "message") ??
            readStringParam(params, "text") ??
            readStringParam(params, "caption") ??
            ""
          const replyToMsgId = parseOptionalInlineId(
            readFlexibleId(params, "messageId") ??
              readFlexibleId(params, "replyTo") ??
              readFlexibleId(params, "replyToId") ??
              readStringParam(params, "messageId") ??
              readStringParam(params, "replyTo") ??
              readStringParam(params, "replyToId"),
            "messageId",
          )

          if (normalizedAction === "sendAttachment" && mediaSources.length === 0) {
            throw new Error("inline action: sendAttachment requires media/file input")
          }

          if (mediaSources.length === 0) {
            const message =
              readStringParam(params, "message") ??
              readStringParam(params, "text", { required: true, allowEmpty: true })
            const sent = await client.sendMessage({
              ...sendTarget,
              text: message,
              ...(actions !== undefined ? { actions } : {}),
              ...(replyToMsgId != null ? { replyToMsgId } : {}),
              parseMarkdown,
            })
            return jsonResult({
              ok: true,
              target: target.target,
              messageId: sent.messageId != null ? String(sent.messageId) : null,
              replyToId: replyToMsgId != null ? String(replyToMsgId) : null,
            })
          }

          let lastSent: { messageId?: bigint | null } | null = null
          for (let index = 0; index < mediaSources.length; index += 1) {
            const mediaUrl = mediaSources[index]
            if (!mediaUrl) continue
            const media = await uploadInlineMediaFromUrl({
              client,
              cfg,
              accountId: accountId ?? null,
              mediaUrl,
            })
            lastSent = await client.sendMessage({
              ...sendTarget,
              ...(index === 0 && text ? { text } : {}),
              media,
              ...(index === 0 && actions !== undefined ? { actions } : {}),
              ...(index === 0 && replyToMsgId != null ? { replyToMsgId } : {}),
              ...(index === 0 && text ? { parseMarkdown } : {}),
            })
          }
          return jsonResult({
            ok: true,
            target: target.target,
            messageId: lastSent?.messageId != null ? String(lastSent.messageId) : null,
            ...(mediaSources.length === 1 ? { mediaUrl: mediaSources[0] } : { mediaUrls: mediaSources }),
            replyToId: replyToMsgId != null ? String(replyToMsgId) : null,
          })
        },
      })
    }

    if (normalizedAction === "reply" || normalizedAction === "thread-reply") {
      const parseMarkdown =
        resolveInlineAccount({ cfg, accountId: accountId ?? null }).config.parseMarkdown ?? true
      const replyThreadsEnabled =
        normalizedAction === "thread-reply" &&
        isInlineReplyThreadsEnabled({ cfg, accountId: accountId ?? null })
      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client) => {
          const actions = resolveInlineMessageActionsParam(params)
          if (replyThreadsEnabled) {
            const rawThreadId =
              readFlexibleId(params, "threadId") ??
              readStringParam(params, "threadId")
            if (!rawThreadId) {
              throw new Error(
                "inline thread-reply: threadId is required when reply threads are enabled",
              )
            }
            const chatId = parseInlineId(rawThreadId, "threadId")
            const replyToMsgId = parseOptionalInlineId(
              readFlexibleId(params, "messageId") ??
                readFlexibleId(params, "replyTo") ??
                readFlexibleId(params, "replyToId") ??
                readStringParam(params, "messageId") ??
                readStringParam(params, "replyTo") ??
                readStringParam(params, "replyToId"),
              "messageId",
            )
            const text =
              readStringParam(params, "message") ??
              readStringParam(params, "text", { required: true, allowEmpty: true })
            const sent = await client.sendMessage({
              chatId,
              text,
              ...(actions !== undefined ? { actions } : {}),
              ...(replyToMsgId != null ? { replyToMsgId } : {}),
              parseMarkdown,
            })
            return jsonResult({
              ok: true,
              chatId: String(chatId),
              threadId: String(chatId),
              messageId: sent.messageId != null ? String(sent.messageId) : null,
              replyToId: replyToMsgId != null ? String(replyToMsgId) : null,
            })
          }
          const replyParams =
            normalizedAction === "thread-reply" &&
            params.threadId != null &&
            params.to == null &&
            params.chatId == null &&
            params.channelId == null
              ? { ...params, to: params.threadId }
              : params
          const chatId = resolveChatIdFromParams(replyParams)
          const replyToMsgId = parseInlineId(
            readFlexibleId(replyParams, "messageId") ??
              readFlexibleId(replyParams, "replyTo") ??
              readFlexibleId(replyParams, "replyToId") ??
              readStringParam(replyParams, "messageId") ??
              readStringParam(replyParams, "replyTo") ??
              readStringParam(replyParams, "replyToId", { required: true }),
            "messageId",
          )
          const text =
            readStringParam(replyParams, "message") ??
            readStringParam(replyParams, "text", { required: true, allowEmpty: true })
          const sent = await client.sendMessage({
            chatId,
            text,
            ...(actions !== undefined ? { actions } : {}),
            replyToMsgId,
            parseMarkdown,
          })
          return jsonResult({
            ok: true,
            chatId: String(chatId),
            messageId: sent.messageId != null ? String(sent.messageId) : null,
            replyToId: String(replyToMsgId),
          })
        },
      })
    }

    if (normalizedAction === "react") {
      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client) => {
          const chatId = resolveChatIdFromParams(params)
          const rawMessageId = resolveReactionMessageId(
            toolContext != null
              ? { args: params, toolContext }
              : { args: params },
          )
          if (!rawMessageId) {
            return jsonResult({
              ok: false,
              reason: "missing_message_id",
              hint: "Inline reaction requires a valid messageId (or inbound context fallback). Do not retry.",
            })
          }
          let messageId: bigint
          try {
            messageId = parseInlineId(rawMessageId, "messageId")
          } catch {
            return jsonResult({
              ok: false,
              reason: "missing_message_id",
              hint: "Inline reaction requires a valid messageId (or inbound context fallback). Do not retry.",
            })
          }
          const { emoji, remove, isEmpty } = readReactionParams(params, {
            removeErrorMessage: "Emoji is required to remove an Inline reaction.",
          })
          if (isEmpty) {
            throw new Error("inline action: react requires emoji")
          }

          if (remove) {
            try {
              const result = await client.invokeRaw(Method.DELETE_REACTION, {
                oneofKind: "deleteReaction",
                deleteReaction: {
                  emoji,
                  peerId: buildChatPeer(chatId),
                  messageId,
                },
              })
              if (result.oneofKind !== "deleteReaction") {
                throw new Error(
                  `inline action: expected deleteReaction result, got ${String(result.oneofKind)}`,
                )
              }
            } catch {
              return jsonResult({
                ok: false,
                reason: "error",
                emoji,
                remove: true,
                hint: "Reaction failed. Do not retry.",
              })
            }
          } else {
            if (
              await reactionAlreadyExists({
                client,
                chatId,
                messageId,
                emoji,
              })
            ) {
              return jsonResult({
                ok: true,
                chatId: String(chatId),
                messageId: String(messageId),
                emoji,
                remove: false,
                alreadyPresent: true,
              })
            }

            try {
              const result = await client.invokeRaw(Method.ADD_REACTION, {
                oneofKind: "addReaction",
                addReaction: {
                  emoji,
                  messageId,
                  peerId: buildChatPeer(chatId),
                },
              })
              if (result.oneofKind !== "addReaction") {
                throw new Error(
                  `inline action: expected addReaction result, got ${String(result.oneofKind)}`,
                )
              }
            } catch (error) {
              if (!isDuplicateReactionError(error)) {
                return jsonResult({
                  ok: false,
                  reason: "error",
                  emoji,
                  hint: "Reaction failed. Do not retry.",
                })
              }
              return jsonResult({
                ok: true,
                chatId: String(chatId),
                messageId: String(messageId),
                emoji,
                remove: false,
                alreadyPresent: true,
              })
            }
          }

          return jsonResult({
            ok: true,
            chatId: String(chatId),
            messageId: String(messageId),
            emoji,
            remove,
          })
        },
      })
    }

    if (normalizedAction === "reactions") {
      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client) => {
          const chatId = resolveChatIdFromParams(params)
          const messageId = parseInlineId(
            readFlexibleId(params, "messageId") ??
              readStringParam(params, "messageId", { required: true }),
            "messageId",
          )
          const reactions = await loadMessageReactions({
            client,
            chatId,
            messageId,
          })
          return jsonResult({
            ok: true,
            chatId: String(chatId),
            messageId: String(messageId),
            reactions,
          })
        },
      })
    }

    if (normalizedAction === "read") {
      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client) => {
          const chatId = resolveChatIdFromParams(params)
          const limit = Math.max(1, Math.min(100, readNumberParam(params, "limit", { integer: true }) ?? 20))
          const offsetId = parseOptionalInlineId(
            readFlexibleId(params, "offsetId") ?? readFlexibleId(params, "before"),
            "offsetId",
          )
          const result = await client.invokeRaw(Method.GET_CHAT_HISTORY, {
            oneofKind: "getChatHistory",
            getChatHistory: {
              peerId: buildChatPeer(chatId),
              ...(offsetId != null ? { offsetId } : {}),
              limit,
            },
          })
          if (result.oneofKind !== "getChatHistory") {
            throw new Error(
              `inline action: expected getChatHistory result, got ${String(result.oneofKind)}`,
            )
          }
          return jsonResult(
            toJsonSafe({
              ok: true,
              chatId: String(chatId),
              messages: (result.getChatHistory.messages ?? []).map((message) => mapMessage(message)),
            }),
          )
        },
      })
    }

    if (normalizedAction === "search") {
      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client) => {
          const chatId = resolveChatIdFromParams(params)
          const query =
            readStringParam(params, "query") ??
            readStringParam(params, "q") ??
            readStringParam(params, "message", { required: true })
          const limit = Math.max(1, Math.min(100, readNumberParam(params, "limit", { integer: true }) ?? 20))
          const offsetId = parseOptionalInlineId(readFlexibleId(params, "offsetId"), "offsetId")
          const result = await client.invokeRaw(Method.SEARCH_MESSAGES, {
            oneofKind: "searchMessages",
            searchMessages: {
              peerId: buildChatPeer(chatId),
              queries: [query],
              limit,
              ...(offsetId != null ? { offsetId } : {}),
            },
          })
          if (result.oneofKind !== "searchMessages") {
            throw new Error(
              `inline action: expected searchMessages result, got ${String(result.oneofKind)}`,
            )
          }
          return jsonResult(
            toJsonSafe({
              ok: true,
              chatId: String(chatId),
              query,
              messages: (result.searchMessages.messages ?? []).map((message) => mapMessage(message)),
            }),
          )
        },
      })
    }

    if (normalizedAction === "edit") {
      const parseMarkdown =
        resolveInlineAccount({ cfg, accountId: accountId ?? null }).config.parseMarkdown ?? true
      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client) => {
          const chatId = resolveChatIdFromParams(params)
          const actions = resolveInlineMessageActionsParam(params)
          const messageId = parseInlineId(
            readFlexibleId(params, "messageId") ??
              readStringParam(params, "messageId", { required: true }),
            "messageId",
          )
          const text = readStringParam(params, "message", { required: true, allowEmpty: true })
          const result = await client.invokeRaw(Method.EDIT_MESSAGE, {
            oneofKind: "editMessage",
            editMessage: {
              messageId,
              peerId: buildChatPeer(chatId),
              text,
              ...(actions !== undefined ? { actions } : {}),
              parseMarkdown,
            },
          })
          if (result.oneofKind !== "editMessage") {
            throw new Error(`inline action: expected editMessage result, got ${String(result.oneofKind)}`)
          }
          return jsonResult(
            toJsonSafe({ ok: true, chatId: String(chatId), messageId: String(messageId), text, parseMarkdown }),
          )
        },
      })
    }

    if (normalizedAction === "channel-info") {
      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client) => {
          const chatId = resolveChatIdFromParams(params)
          const result = await client.invokeRaw(Method.GET_CHAT, {
            oneofKind: "getChat",
            getChat: { peerId: buildChatPeer(chatId) },
          })
          if (result.oneofKind !== "getChat") {
            throw new Error(`inline action: expected getChat result, got ${String(result.oneofKind)}`)
          }
          return jsonResult(
            toJsonSafe({
              ok: true,
              chatId: String(chatId),
              chat: result.getChat.chat ?? null,
              dialog: result.getChat.dialog ?? null,
              pinnedMessageIds: (result.getChat.pinnedMessageIds ?? []).map((id) => String(id)),
            }),
          )
        },
      })
    }

    if (normalizedAction === "channel-edit" || normalizedAction === "renameGroup") {
      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client) => {
          const chatId = resolveChatIdFromParams(params)
          const title =
            readStringParam(params, "title") ??
            readStringParam(params, "name") ??
            readStringParam(params, "threadName") ??
            readStringParam(params, "message", { required: true })
          const result = await client.invokeRaw(Method.UPDATE_CHAT_INFO, {
            oneofKind: "updateChatInfo",
            updateChatInfo: {
              chatId,
              title,
            },
          })
          if (result.oneofKind !== "updateChatInfo") {
            throw new Error(
              `inline action: expected updateChatInfo result, got ${String(result.oneofKind)}`,
            )
          }
          return jsonResult(
            toJsonSafe({
              ok: true,
              chatId: String(chatId),
              title,
              chat: result.updateChatInfo.chat ?? null,
            }),
          )
        },
      })
    }

    if (normalizedAction === "channel-list" || normalizedAction === "thread-list") {
      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client) => {
          const query =
            readStringParam(params, "query") ??
            readStringParam(params, "q") ??
            undefined
          const limit = Math.max(1, Math.min(200, readNumberParam(params, "limit", { integer: true }) ?? 50))
          const result = await client.invokeRaw(Method.GET_CHATS, {
            oneofKind: "getChats",
            getChats: {},
          })
          if (result.oneofKind !== "getChats") {
            throw new Error(`inline action: expected getChats result, got ${String(result.oneofKind)}`)
          }

          const dialogByChatId = buildDialogMap(result.getChats.dialogs ?? [])
          const usersById = buildUserMap(result.getChats.users ?? [])
          const entries = (result.getChats.chats ?? []).map((chat) =>
            mapChatEntry({ chat, dialogByChatId, usersById }),
          )

          const normalizedQuery = query?.trim().toLowerCase() ?? ""
          const filtered = normalizedQuery
            ? entries.filter((entry) => {
                const haystack = [
                  entry.id,
                  entry.title,
                  entry.peer?.kind === "user" ? entry.peer.username ?? "" : "",
                  entry.peer?.kind === "user" ? entry.peer.name ?? "" : "",
                ]
                  .join("\n")
                  .toLowerCase()
                return haystack.includes(normalizedQuery)
              })
            : entries

          return jsonResult(
            toJsonSafe({
              ok: true,
              query: query ?? null,
              count: filtered.length,
              chats: filtered.slice(0, limit),
            }),
          )
        },
      })
    }

    if (normalizedAction === "channel-create" || normalizedAction === "thread-create") {
      const replyThreadsEnabled =
        normalizedAction === "thread-create" &&
        isInlineReplyThreadsEnabled({ cfg, accountId: accountId ?? null })
      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client) => {
          const title =
            readStringParam(params, "title") ??
            readStringParam(params, "name") ??
            readStringParam(params, "threadName") ??
            readStringParam(params, "message", { required: true })
          const description = readStringParam(params, "description")
          const emoji = readStringParam(params, "emoji")
          const spaceId = parseOptionalInlineId(
            readFlexibleId(params, "spaceId") ?? readFlexibleId(params, "space"),
            "spaceId",
          )
          const isPublic = readBooleanParam(params, "isPublic") ?? false
          const participantRefs = parseInlineListValuesFromParams(params, [
            "participants",
            "participantIds",
            "participantId",
            "participant",
            "userIds",
            "userId",
          ])
          const dedupedParticipants = await resolveInlineUserIdsFromParams({
            client,
            values: participantRefs,
            label: "participant",
          })

          if (replyThreadsEnabled) {
            const parentChatId = resolveChatIdFromParams(params)
            const parentMessageId = parseOptionalInlineId(
              readFlexibleId(params, "parentMessageId") ??
                readFlexibleId(params, "messageId") ??
                readFlexibleId(params, "replyTo") ??
                readFlexibleId(params, "replyToId") ??
                readStringParam(params, "parentMessageId") ??
                readStringParam(params, "messageId") ??
                readStringParam(params, "replyTo") ??
                readStringParam(params, "replyToId"),
              "parentMessageId",
            )

            const result = await client.invokeRaw(CREATE_SUBTHREAD_METHOD, {
              oneofKind: "createSubthread",
              createSubthread: {
                parentChatId,
                ...(parentMessageId != null ? { parentMessageId } : {}),
                title,
                ...(description ? { description } : {}),
                ...(emoji ? { emoji } : {}),
                participants: dedupedParticipants.map((userId) => ({ userId })),
              },
            })
            if (result.oneofKind !== "createSubthread") {
              throw new Error(
                `inline action: expected createSubthread result, got ${String(result.oneofKind)}`,
              )
            }
            return jsonResult(
              toJsonSafe({
                ok: true,
                title,
                parentChatId: String(parentChatId),
                parentMessageId: parentMessageId != null ? String(parentMessageId) : null,
                chat: result.createSubthread.chat ?? null,
                dialog: result.createSubthread.dialog ?? null,
                anchorMessage: result.createSubthread.anchorMessage ?? null,
              }),
            )
          }

          const result = await client.invokeRaw(Method.CREATE_CHAT, {
            oneofKind: "createChat",
            createChat: {
              title,
              ...(spaceId != null ? { spaceId } : {}),
              ...(description ? { description } : {}),
              ...(emoji ? { emoji } : {}),
              isPublic,
              participants: isPublic ? [] : dedupedParticipants.map((userId) => ({ userId })),
            },
          })
          if (result.oneofKind !== "createChat") {
            throw new Error(`inline action: expected createChat result, got ${String(result.oneofKind)}`)
          }
          return jsonResult(
            toJsonSafe({
              ok: true,
              title,
              spaceId: spaceId != null ? String(spaceId) : null,
              isPublic,
              participants: dedupedParticipants.map((id) => String(id)),
              chat: result.createChat.chat ?? null,
              dialog: result.createChat.dialog ?? null,
            }),
          )
        },
      })
    }

    if (normalizedAction === "channel-delete") {
      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client) => {
          const chatId = resolveChatIdFromParams(params)
          const result = await client.invokeRaw(Method.DELETE_CHAT, {
            oneofKind: "deleteChat",
            deleteChat: {
              peerId: buildChatPeer(chatId),
            },
          })
          if (result.oneofKind !== "deleteChat") {
            throw new Error(`inline action: expected deleteChat result, got ${String(result.oneofKind)}`)
          }
          return jsonResult({
            ok: true,
            chatId: String(chatId),
          })
        },
      })
    }

    if (normalizedAction === "channel-move") {
      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client) => {
          const chatId = resolveChatIdFromParams(params)
          const rawSpace = readStringParam(params, "spaceId") ?? readStringParam(params, "toSpaceId")
          const normalizedSpace = rawSpace?.trim().toLowerCase()
          const moveToHome =
            normalizedSpace === "" ||
            normalizedSpace === "home" ||
            normalizedSpace === "none" ||
            normalizedSpace === "null"
          const parsedSpace = moveToHome
            ? undefined
            : parseOptionalInlineId(
                readFlexibleId(params, "spaceId") ?? readFlexibleId(params, "toSpaceId"),
                "spaceId",
              )
          const result = await client.invokeRaw(Method.MOVE_THREAD, {
            oneofKind: "moveThread",
            moveThread: {
              chatId,
              ...(parsedSpace != null ? { spaceId: parsedSpace } : {}),
            },
          })
          if (result.oneofKind !== "moveThread") {
            throw new Error(`inline action: expected moveThread result, got ${String(result.oneofKind)}`)
          }
          return jsonResult(
            toJsonSafe({
              ok: true,
              chatId: String(chatId),
              spaceId: parsedSpace != null ? String(parsedSpace) : null,
              chat: result.moveThread.chat ?? null,
            }),
          )
        },
      })
    }

    if (normalizedAction === "addParticipant") {
      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client) => {
          const chatId = resolveChatIdFromParams(params)
          const participantRefs = parseInlineListValuesFromParams(params, [
            "userId",
            "participant",
            "participantId",
            "memberId",
          ])
          if (participantRefs.length === 0) {
            readStringParam(params, "userId", { required: true })
          }
          const participantIds = await resolveInlineUserIdsFromParams({
            client,
            values: participantRefs,
            label: "user",
          })
          if (participantIds.length === 0) {
            throw new Error("inline action: missing user")
          }
          if (participantIds.length > 1) {
            throw new Error("inline action: addParticipant accepts exactly one user")
          }
          const userId = participantIds[0]
          if (!userId) {
            throw new Error("inline action: missing user")
          }
          const result = await client.invokeRaw(Method.ADD_CHAT_PARTICIPANT, {
            oneofKind: "addChatParticipant",
            addChatParticipant: {
              chatId,
              userId,
            },
          })
          if (result.oneofKind !== "addChatParticipant") {
            throw new Error(
              `inline action: expected addChatParticipant result, got ${String(result.oneofKind)}`,
            )
          }
          return jsonResult(
            toJsonSafe({
              ok: true,
              chatId: String(chatId),
              userId: String(userId),
              participant: result.addChatParticipant.participant ?? null,
            }),
          )
        },
      })
    }

    if (normalizedAction === "removeParticipant" || normalizedAction === "kick") {
      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client) => {
          const chatId = resolveChatIdFromParams(params)
          const participantRefs = parseInlineListValuesFromParams(params, [
            "userId",
            "participant",
            "participantId",
            "memberId",
          ])
          if (participantRefs.length === 0) {
            readStringParam(params, "userId", { required: true })
          }
          const participantIds = await resolveInlineUserIdsFromParams({
            client,
            values: participantRefs,
            label: "user",
          })
          if (participantIds.length === 0) {
            throw new Error("inline action: missing user")
          }
          if (participantIds.length > 1) {
            throw new Error("inline action: removeParticipant accepts exactly one user")
          }
          const userId = participantIds[0]
          if (!userId) {
            throw new Error("inline action: missing user")
          }
          const result = await client.invokeRaw(Method.REMOVE_CHAT_PARTICIPANT, {
            oneofKind: "removeChatParticipant",
            removeChatParticipant: {
              chatId,
              userId,
            },
          })
          if (result.oneofKind !== "removeChatParticipant") {
            throw new Error(
              `inline action: expected removeChatParticipant result, got ${String(result.oneofKind)}`,
            )
          }
          return jsonResult({
            ok: true,
            chatId: String(chatId),
            userId: String(userId),
          })
        },
      })
    }

    if (normalizedAction === "leaveGroup") {
      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client) => {
          const chatId = resolveChatIdFromParams(params)
          const me = await client.getMe()
          const userId = me.userId
          const result = await client.invokeRaw(Method.REMOVE_CHAT_PARTICIPANT, {
            oneofKind: "removeChatParticipant",
            removeChatParticipant: {
              chatId,
              userId,
            },
          })
          if (result.oneofKind !== "removeChatParticipant") {
            throw new Error(
              `inline action: expected removeChatParticipant result, got ${String(result.oneofKind)}`,
            )
          }
          return jsonResult({
            ok: true,
            chatId: String(chatId),
            userId: String(userId),
            left: true,
          })
        },
      })
    }

    if (normalizedAction === "member-info") {
      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client) => {
          const chatId = resolveChatIdFromParams(params)
          const userId = parseInlineId(
            readFlexibleId(params, "userId") ??
              readStringParam(params, "userId", { required: true }),
            "userId",
          )
          const result = await client.invokeRaw(Method.GET_CHAT_PARTICIPANTS, {
            oneofKind: "getChatParticipants",
            getChatParticipants: { chatId },
          })
          if (result.oneofKind !== "getChatParticipants") {
            throw new Error(
              `inline action: expected getChatParticipants result, got ${String(result.oneofKind)}`,
            )
          }
          const user =
            (result.getChatParticipants.users ?? []).find((candidate) => candidate.id === userId) ?? null
          const participant =
            (result.getChatParticipants.participants ?? []).find(
              (candidate) => candidate.userId === userId,
            ) ?? null
          return jsonResult(
            toJsonSafe({
              ok: true,
              chatId: String(chatId),
              userId: String(userId),
              user,
              participant,
            }),
          )
        },
      })
    }

    if (normalizedAction === "delete" || normalizedAction === "unsend") {
      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client) => {
          const chatId = resolveChatIdFromParams(params)
          const messageIds = [
            ...parseInlineIdListFromParams(params, "messageIds"),
            ...parseInlineIdListFromParams(params, "messages"),
            ...parseInlineIdListFromParams(params, "ids"),
          ]
          if (messageIds.length === 0) {
            messageIds.push(
              parseInlineId(
                readFlexibleId(params, "messageId") ??
                  readStringParam(params, "messageId", { required: true }),
                "messageId",
              ),
            )
          }

          const deduped = Array.from(new Set(messageIds.map((id) => id.toString()))).map((id) => BigInt(id))

          const result = await client.invokeRaw(Method.DELETE_MESSAGES, {
            oneofKind: "deleteMessages",
            deleteMessages: {
              peerId: buildChatPeer(chatId),
              messageIds: deduped,
            },
          })
          if (result.oneofKind !== "deleteMessages") {
            throw new Error(
              `inline action: expected deleteMessages result, got ${String(result.oneofKind)}`,
            )
          }
          return jsonResult({
            ok: true,
            chatId: String(chatId),
            messageIds: deduped.map((id) => String(id)),
          })
        },
      })
    }

    if (normalizedAction === "pin" || normalizedAction === "unpin") {
      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client) => {
          const chatId = resolveChatIdFromParams(params)
          const messageId = parseInlineId(
            readFlexibleId(params, "messageId") ??
              readStringParam(params, "messageId", { required: true }),
            "messageId",
          )
          const unpin =
            normalizedAction === "unpin" || readBooleanParam(params, "unpin") === true
          const result = await client.invokeRaw(Method.PIN_MESSAGE, {
            oneofKind: "pinMessage",
            pinMessage: {
              peerId: buildChatPeer(chatId),
              messageId,
              unpin,
            },
          })
          if (result.oneofKind !== "pinMessage") {
            throw new Error(`inline action: expected pinMessage result, got ${String(result.oneofKind)}`)
          }
          return jsonResult({
            ok: true,
            chatId: String(chatId),
            messageId: String(messageId),
            unpin,
          })
        },
      })
    }

    if (normalizedAction === "list-pins") {
      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client) => {
          const chatId = resolveChatIdFromParams(params)
          const result = await client.invokeRaw(Method.GET_CHAT, {
            oneofKind: "getChat",
            getChat: { peerId: buildChatPeer(chatId) },
          })
          if (result.oneofKind !== "getChat") {
            throw new Error(`inline action: expected getChat result, got ${String(result.oneofKind)}`)
          }

          const pinnedMessageIds = (result.getChat.pinnedMessageIds ?? []).map((id) => String(id))
          return jsonResult({
            ok: true,
            chatId: String(chatId),
            pinnedMessageIds,
          })
        },
      })
    }

    if (normalizedAction === "permissions") {
      return await withInlineClient({
        cfg,
        accountId,
        fn: async (client) => {
          const chatId = resolveChatIdFromParams(params)
          const spaceId = await resolveSpaceIdFromParams({
            client,
            action: "permissions",
            rawParams: params,
          })

          const userIdRaw =
            readFlexibleId(params, "userId") ??
            readFlexibleId(params, "memberId") ??
            readStringParam(params, "userId")
          const userId = userIdRaw ? parseInlineId(userIdRaw, "userId") : undefined
          const roleValue = readStringParam(params, "role")?.trim().toLowerCase()
          const canAccessPublicChats = readBooleanParam(params, "canAccessPublicChats")

          if (userId != null && roleValue) {
            const role =
              roleValue === "admin"
                ? { role: { oneofKind: "admin" as const, admin: {} } }
                : roleValue === "member"
                  ? {
                      role: {
                        oneofKind: "member" as const,
                        member: {
                          canAccessPublicChats: canAccessPublicChats ?? true,
                        },
                      },
                    }
                  : null
            if (!role) {
              throw new Error("inline action: role must be \"admin\" or \"member\"")
            }

            const updateResult = await client.invokeRaw(Method.UPDATE_MEMBER_ACCESS, {
              oneofKind: "updateMemberAccess",
              updateMemberAccess: {
                spaceId,
                userId,
                role,
              },
            })
            if (updateResult.oneofKind !== "updateMemberAccess") {
              throw new Error(
                `inline action: expected updateMemberAccess result, got ${String(updateResult.oneofKind)}`,
              )
            }
          }

          const members = await getSpaceMembersWithUsers({
            client,
            spaceId,
          })

          const filteredMembers =
            userId != null ? members.filter((member) => member.userId === String(userId)) : members

          return jsonResult(
            toJsonSafe({
              ok: true,
              chatId: String(chatId),
              spaceId: String(spaceId),
              members: filteredMembers,
            }),
          )
        },
      })
    }

    throw new Error(`Action ${action} is not supported for provider inline.`)
  },
} satisfies ChannelMessageActionAdapter & LegacyInlineMessageActionAdapter

export const inlineSupportedActions = listAllActions()
