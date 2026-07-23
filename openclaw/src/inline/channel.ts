import { unlink } from "node:fs/promises"
import path from "node:path"
import {
  buildChannelOutboundSessionRoute,
  buildThreadAwareOutboundSessionRoute,
  type ChannelPlugin,
  type OpenClawConfig,
} from "openclaw/plugin-sdk/core"
import { createChannelMessageAdapterFromOutbound } from "openclaw/plugin-sdk/channel-outbound"
import {
  presentationToInteractiveReply,
  renderMessagePresentationFallbackText,
} from "openclaw/plugin-sdk/interactive-runtime"
import {
  buildDmGroupAccountAllowlistAdapter,
  createFlatAllowlistOverrideResolver,
} from "openclaw/plugin-sdk/allowlist-config-edit"
import { buildTokenChannelStatusSummary } from "openclaw/plugin-sdk/status-helpers"
import {
  InlineSdkClient,
  Method,
  type Chat,
  type Dialog,
  type MessageActions,
  type User,
} from "@inline-chat/realtime-sdk"
import {
  findInlineTokenOwnerAccountId,
  formatDuplicateInlineTokenReason,
  resolveDefaultInlineAccountId,
  inspectInlineAccount,
  resolveInlineEnvToken,
  resolveInlineAccount,
  resolveInlineToken,
  type ResolvedInlineAccount,
} from "./accounts.js"
import { isInlineReplyThreadsEnabled, resolveInlineReplyThreadChatId } from "./reply-threads.js"
import { recordInlineThreadParticipation } from "./thread-participation.js"
import { looksLikeInlineTargetId, normalizeInlineTarget } from "./normalize.js"
import { monitorInlineProvider } from "./monitor.js"
import { sanitizeInlineVisibleText } from "./outbound-sanitize.js"
import {
  buildInlineCommandsListChannelData,
  buildInlineModelBrowseChannelData,
  buildInlineModelsAddProviderChannelData,
  buildInlineModelsListChannelData,
  buildInlineModelsMenuChannelData,
  buildInlineModelsProviderChannelData,
} from "./command-ui.js"
import { inlineDoctor } from "./doctor.js"
import {
  buildInlineInboundFormattingHints,
  sanitizeInlineOutgoingText,
} from "./message-formatting.js"
import { resolveInlineInteractiveTextFallback } from "./interactive-fallback.js"
import { resolveInlineGroupRequireMention, resolveInlineGroupToolPolicy } from "./policy.js"
import {
  inlineMessageActions,
  resolveInlineMessageActionsParam,
  supportsInlineMessageButtonsForConfig,
  supportsInlineReactionsForConfig,
} from "./actions.js"
import { getInlineRuntime } from "../runtime.js"
import {
  DEFAULT_ACCOUNT_ID,
  PAIRING_APPROVED_MESSAGE,
} from "../openclaw-compat.js"
import {
  inlineConfigAdapter,
  inlineConfigSchema,
  inlineMeta,
  normalizeInlineAllowEntry,
} from "./shared.js"
import { uploadInlineMediaFromUrl } from "./media.js"
import { inlineSetupAdapter } from "./setup-core.js"
import { inlineSetupWizard } from "./setup-surface.js"
import { inlineSecrets } from "./secret-contract.js"
import type { InlineProbe } from "./probe.js"
import { probeInlineAccount } from "./probe.js"
import { collectInlineStatusIssues } from "./status-issues.js"
import { inlineSecurityAdapter } from "./security.js"
import {
  buildInlineExecApprovalPendingPayload,
  inlineApprovalCapability,
} from "./approval-native.js"
import { INLINE_DEFAULT_REQUIRE_MENTION } from "./config-schema.js"

const activeMonitors = new Map<string, { stop: () => Promise<void>; done: Promise<void> }>()

function resolveInlineStatePath(accountId: string): string {
  return path.join(getInlineRuntime().state.resolveStateDir(), "channels", "inline", `${accountId}.json`)
}

async function deleteInlineAccountState(accountId: string): Promise<void> {
  try {
    await unlink(resolveInlineStatePath(accountId))
  } catch (error) {
    if ((error as { code?: string }).code !== "ENOENT") {
      throw error
    }
  }
}

function resolveInlineStateIdentity(cfg: OpenClawConfig, accountId: string): string {
  const account = resolveInlineAccount({ cfg, accountId })
  return JSON.stringify({
    baseUrl: account.baseUrl,
    configured: account.configured,
    token: account.token,
    tokenFile: account.tokenFile,
    tokenSource: account.tokenSource,
    tokenConfigured: account.tokenConfigured,
  })
}

function parseInlineId(raw: unknown): bigint | undefined {
  if (raw == null) return undefined
  if (typeof raw === "bigint") return raw
  if (typeof raw === "number") {
    if (!Number.isFinite(raw) || !Number.isInteger(raw) || raw < 0) return undefined
    return BigInt(raw)
  }
  if (typeof raw === "string") {
    const trimmed = raw.trim()
    if (!trimmed) return undefined
    try {
      return BigInt(trimmed)
    } catch {
      return undefined
    }
  }
  return undefined
}

function asRecord(value: unknown): Record<string, unknown> | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return null
  }
  return value as Record<string, unknown>
}

function hasInlineCredentialValue(value: unknown): boolean {
  if (typeof value === "string") {
    return Boolean(value.trim())
  }
  return Boolean(asRecord(value))
}

function clearInlineCredentialFields(record: Record<string, unknown>): { changed: boolean; cleared: boolean } {
  let changed = false
  let cleared = false
  for (const key of ["token", "tokenFile"] as const) {
    if (!Object.hasOwn(record, key)) {
      continue
    }
    const raw = record[key]
    if (hasInlineCredentialValue(raw)) {
      cleared = true
    }
    delete record[key]
    changed = true
  }
  return { changed, cleared }
}

function clearInlineAccountCredentials(params: {
  cfg: OpenClawConfig
  accountId: string
}): { cfg: OpenClawConfig; changed: boolean; cleared: boolean } {
  const channels = asRecord(params.cfg.channels)
  const inline = asRecord(channels?.inline)
  if (!channels || !inline) {
    return { cfg: params.cfg, changed: false, cleared: false }
  }

  const nextInline: Record<string, unknown> = { ...inline }
  let changed = false
  let cleared = false

  if (params.accountId === DEFAULT_ACCOUNT_ID) {
    const base = clearInlineCredentialFields(nextInline)
    changed = changed || base.changed
    cleared = cleared || base.cleared
  }

  const accounts = asRecord(nextInline.accounts)
  if (accounts) {
    const nextAccounts: Record<string, unknown> = { ...accounts }
    const accountEntry = asRecord(nextAccounts[params.accountId])
    if (accountEntry) {
      const nextAccountEntry: Record<string, unknown> = { ...accountEntry }
      const entry = clearInlineCredentialFields(nextAccountEntry)
      if (entry.changed) {
        changed = true
        cleared = cleared || entry.cleared
        if (Object.keys(nextAccountEntry).length > 0) {
          nextAccounts[params.accountId] = nextAccountEntry
        } else {
          delete nextAccounts[params.accountId]
        }
      }
    }
    if (changed) {
      if (Object.keys(nextAccounts).length > 0) {
        nextInline.accounts = nextAccounts
      } else {
        delete nextInline.accounts
      }
    }
  }

  if (!changed) {
    return { cfg: params.cfg, changed: false, cleared: false }
  }

  return {
    cfg: {
      ...params.cfg,
      channels: {
        ...channels,
        inline: nextInline,
      },
    },
    changed: true,
    cleared,
  }
}

type InlineOutboundContext = "sendText" | "sendMedia"

type InlineParsedOutboundTarget = {
  targetId: bigint
  kind: "chat" | "user"
  normalizedNumeric: string
  explicitKind: boolean
  raw: string
}

function parseInlineOutboundTarget(params: {
  raw: string
  context: InlineOutboundContext
}): InlineParsedOutboundTarget {
  let normalizedTarget = params.raw.trim()
  const hadInlinePrefix = /^inline:/i.test(normalizedTarget)
  if (hadInlinePrefix) {
    normalizedTarget = normalizedTarget.replace(/^inline:/i, "").trim()
  }
  if (!normalizedTarget) {
    throw new Error(`inline ${params.context}: missing target`)
  }

  let kind: "chat" | "user" = "chat"
  let explicitKind = false
  if (/^chat:/i.test(normalizedTarget)) {
    kind = "chat"
    explicitKind = true
    normalizedTarget = normalizedTarget.replace(/^chat:/i, "").trim()
  } else if (/^user:/i.test(normalizedTarget)) {
    kind = "user"
    explicitKind = true
    normalizedTarget = normalizedTarget.replace(/^user:/i, "").trim()
  }
  // Session-derived targets are persisted as `inline:<chatId>`.
  // Treat that shape as an explicit chat target so current-chat sends stay stable.
  if (hadInlinePrefix && !explicitKind) {
    explicitKind = true
  }
  // Keep backward compatibility for existing bare numeric ids that
  // historically mapped to chat ids.
  normalizedTarget = normalizeInlineTarget(normalizedTarget) ?? normalizedTarget

  if (!/^[0-9]+$/.test(normalizedTarget)) {
    throw new Error(
      `inline ${params.context}: invalid target "${params.raw}" (expected chat id or user id)`,
    )
  }

  return {
    targetId: BigInt(normalizedTarget),
    kind,
    normalizedNumeric: normalizedTarget,
    explicitKind,
    raw: params.raw,
  }
}

function parseInlineExplicitTarget(raw: string): { to: string; chatType: "direct" | "group" } | null {
  const parsed = parseInlineOutboundTarget({
    raw,
    context: "sendText",
  })
  if (parsed.kind === "user") {
    return { to: `user:${parsed.normalizedNumeric}`, chatType: "direct" }
  }
  return { to: `chat:${parsed.normalizedNumeric}`, chatType: "group" }
}

function resolveInlineOutboundSessionRoute(params: {
  cfg: OpenClawConfig
  agentId: string
  accountId?: string | null
  target: string
  resolvedTarget?: { kind: string }
  replyToId?: string | null
  threadId?: string | number | null
  currentSessionKey?: string | null
}) {
  let parsed: InlineParsedOutboundTarget
  try {
    parsed = parseInlineOutboundTarget({
      raw: params.target,
      context: "sendText",
    })
  } catch {
    return null
  }

  const resolvedKind = params.resolvedTarget?.kind
  const kind =
    !parsed.explicitKind && resolvedKind === "user"
      ? "user"
      : parsed.kind
  const chatType: "direct" | "group" = kind === "user" ? "direct" : "group"
  const peer = {
    kind: chatType,
    id: parsed.normalizedNumeric,
  }
  const route = buildChannelOutboundSessionRoute({
    cfg: params.cfg,
    agentId: params.agentId,
    channel: "inline",
    ...(params.accountId !== undefined ? { accountId: params.accountId } : {}),
    peer,
    chatType,
    from: kind === "user" ? `inline:${parsed.normalizedNumeric}` : `inline:chat:${parsed.normalizedNumeric}`,
    to: kind === "user" ? `user:${parsed.normalizedNumeric}` : `chat:${parsed.normalizedNumeric}`,
  })

  if (
    kind === "user" ||
    !isInlineReplyThreadsEnabled({ cfg: params.cfg, accountId: params.accountId ?? null })
  ) {
    return route
  }

  return buildThreadAwareOutboundSessionRoute({
    route,
    ...(params.threadId !== undefined ? { threadId: params.threadId } : {}),
    ...(params.currentSessionKey !== undefined ? { currentSessionKey: params.currentSessionKey } : {}),
    precedence: ["threadId", "currentSession"],
  })
}

function formatInlineTargetDisplay(params: {
  target: string
  display?: string | undefined
  kind?: string | undefined
}): string {
  const explicit = params.display?.trim()
  if (explicit) {
    return explicit
  }
  let parsed: ReturnType<typeof parseInlineExplicitTarget>
  try {
    parsed = parseInlineExplicitTarget(params.target.trim())
  } catch {
    return params.target.trim()
  }
  if (!parsed) {
    return params.target.trim()
  }
  if (parsed.chatType === "direct" || params.kind === "user") {
    return parsed.to
  }
  return parsed.to
}

function normalizeInlineConversationId(raw: string): string | null {
  const trimmed = raw.trim()
  if (!trimmed) return null
  const withoutProvider = trimmed.replace(/^inline:/i, "").trim()
  if (!withoutProvider) return null
  try {
    const parsed = parseInlineExplicitTarget(withoutProvider)
    if (!parsed) return null
    return `inline:${parsed.to}`
  } catch {
    return null
  }
}

function resolveInlineSessionTarget(params: { id: string }): string | undefined {
  const raw = params.id.trim().replace(/^inline:/i, "").trim()
  if (!raw) return undefined
  const target = /^chat:/i.test(raw) ? raw : `chat:${raw}`
  try {
    return parseInlineExplicitTarget(target)?.to
  } catch {
    return undefined
  }
}

function inlineChatIdFromTarget(target: string): string | undefined {
  const match = target.match(/^chat:(.+)$/i)
  return match?.[1]?.trim() || undefined
}

function resolveInlineSessionConversation(params: {
  rawId: string
}): {
  id: string
  threadId?: string
  baseConversationId?: string
  parentConversationCandidates?: string[]
} | null {
  const raw = params.rawId.trim()
  if (!raw) return null

  const threadMarker = ":thread:"
  const threadIndex = raw.toLowerCase().lastIndexOf(threadMarker)
  const rawBase = threadIndex >= 0 ? raw.slice(0, threadIndex) : raw
  const rawThread = threadIndex >= 0 ? raw.slice(threadIndex + threadMarker.length) : undefined
  const baseTarget = resolveInlineSessionTarget({ id: rawBase })
  const baseId = baseTarget ? inlineChatIdFromTarget(baseTarget) : undefined
  const baseConversationId = rawBase ? normalizeInlineConversationId(rawBase) : null
  if (!baseId || !baseConversationId) {
    return null
  }

  const threadTarget = rawThread ? resolveInlineSessionTarget({ id: rawThread }) : undefined
  const threadId = threadTarget ? inlineChatIdFromTarget(threadTarget) : undefined
  return {
    id: baseId,
    ...(threadId ? { threadId } : {}),
    baseConversationId,
    parentConversationCandidates: threadId ? [baseConversationId] : [],
  }
}

function resolveInlineInboundConversation(params: {
  to?: string
  conversationId?: string
  threadId?: string | number
}): { conversationId?: string; parentConversationId?: string } | null {
  const parent =
    (params.to ? normalizeInlineConversationId(params.to) : null) ??
    (params.conversationId ? normalizeInlineConversationId(params.conversationId) : null)
  const child = params.threadId != null ? normalizeInlineConversationId(String(params.threadId)) : null

  const conversationId = child ?? parent
  if (!conversationId) {
    return null
  }

  return {
    conversationId,
    ...(child && parent && parent !== child ? { parentConversationId: parent } : {}),
  }
}

function resolveInlineConversationRef(params: {
  conversationId: string
  parentConversationId?: string
  threadId?: string | number | null
}): { conversationId: string; parentConversationId?: string } | null {
  const conversation = normalizeInlineConversationId(params.conversationId)
  const explicitParent = params.parentConversationId
    ? normalizeInlineConversationId(params.parentConversationId)
    : null
  const thread = params.threadId != null ? normalizeInlineConversationId(String(params.threadId)) : null
  const conversationId = thread ?? conversation
  if (!conversationId) {
    return null
  }
  const parent = explicitParent ?? (thread && conversation && conversation !== thread ? conversation : null)

  return {
    conversationId,
    ...(parent && parent !== conversationId ? { parentConversationId: parent } : {}),
  }
}

function resolveInlineDeliveryTarget(params: {
  conversationId: string
  parentConversationId?: string
}): { to?: string; threadId?: string } | null {
  const child = resolveInlineSessionTarget({ id: params.conversationId })
  if (!child) return null

  const parent = params.parentConversationId
    ? resolveInlineSessionTarget({ id: params.parentConversationId })
    : undefined
  if (parent && parent !== child) {
    const threadId = inlineChatIdFromTarget(child)
    return {
      to: parent,
      ...(threadId ? { threadId } : {}),
    }
  }
  return { to: child }
}

async function listInlineTargetIds(client: InlineSdkClient): Promise<{ chatIds: Set<string>; userIds: Set<string> }> {
  const result = await client.invokeRaw(Method.GET_CHATS, {
    oneofKind: "getChats",
    getChats: {},
  })
  if (result.oneofKind !== "getChats") {
    throw new Error(`inline target resolve: expected getChats result, got ${String(result.oneofKind)}`)
  }
  return {
    chatIds: new Set((result.getChats.chats ?? []).map((chat) => String(chat.id))),
    userIds: new Set((result.getChats.users ?? []).map((user) => String(user.id))),
  }
}

async function resolveInlineOutboundTarget(params: {
  client: InlineSdkClient
  context: InlineOutboundContext
  target: InlineParsedOutboundTarget
}): Promise<InlineParsedOutboundTarget> {
  const { target } = params
  if (target.explicitKind || target.kind === "user") {
    return target
  }

  let ids: { chatIds: Set<string>; userIds: Set<string> } | null = null
  try {
    ids = await listInlineTargetIds(params.client)
  } catch {
    // Keep legacy chat-target behavior if live lookup is unavailable.
    return target
  }

  const matchesChat = ids.chatIds.has(target.normalizedNumeric)
  const matchesUser = ids.userIds.has(target.normalizedNumeric)
  if (matchesChat && matchesUser) {
    throw new Error(
      `inline ${params.context}: ambiguous numeric target "${target.raw}" matches both chat and user ids. Use chat:${target.normalizedNumeric} or user:${target.normalizedNumeric}.`,
    )
  }
  if (!matchesChat && matchesUser) {
    return {
      ...target,
      kind: "user",
    }
  }
  return target
}

function isChatInvalidError(error: unknown): boolean {
  if (error == null) return false
  const text = error instanceof Error ? error.message : String(error)
  return text.toUpperCase().includes("CHAT_INVALID")
}

function wrapInlineTargetError(params: {
  error: unknown
  context: InlineOutboundContext
  target: InlineParsedOutboundTarget
  resolvedTarget: InlineParsedOutboundTarget
}): Error {
  if (
    isChatInvalidError(params.error) &&
    params.resolvedTarget.kind === "chat" &&
    !params.target.explicitKind
  ) {
    return new Error(
      `inline ${params.context}: target "${params.target.raw}" was sent as chatId ${params.target.normalizedNumeric} and failed with CHAT_INVALID. If this is a user id, use user:${params.target.normalizedNumeric}.`,
      { cause: params.error instanceof Error ? params.error : undefined },
    )
  }
  if (
    isChatInvalidError(params.error) &&
    params.resolvedTarget.kind === "user" &&
    params.target.explicitKind
  ) {
    return new Error(
      `inline ${params.context}: user target "${params.target.raw}" failed with CHAT_INVALID. This usually means no direct chat exists yet for that user.`,
      { cause: params.error instanceof Error ? params.error : undefined },
    )
  }
  return params.error instanceof Error ? params.error : new Error(String(params.error))
}

function buildInlineSendTarget(target: InlineParsedOutboundTarget): { chatId: bigint } | { userId: bigint } {
  if (target.kind === "user") {
    return { userId: target.targetId }
  }
  return { chatId: target.targetId }
}

function resolveInlinePayloadActions(payload: Record<string, unknown>): MessageActions | undefined {
  const channelData = asRecord(payload.channelData)
  const inlineData = asRecord(channelData?.inline)
  const telegramData = asRecord(channelData?.telegram)

  if (Object.hasOwn(inlineData ?? {}, "buttons")) {
    return resolveInlineMessageActionsParam({ buttons: inlineData?.buttons })
  }
  // Compatibility for older OpenClaw command surfaces that emitted Telegram-shaped buttons.
  if (Object.hasOwn(telegramData ?? {}, "buttons")) {
    return resolveInlineMessageActionsParam({ buttons: telegramData?.buttons })
  }
  return resolveInlineMessageActionsParam(payload)
}

function formatInlineResultChatId(target: InlineParsedOutboundTarget): string {
  if (target.kind === "user") {
    return `user:${target.normalizedNumeric}`
  }
  return target.normalizedNumeric
}

function buildInlineDisplayName(params: {
  firstName?: string
  lastName?: string
  username?: string
}): string {
  const explicit = [params.firstName?.trim(), params.lastName?.trim()].filter(Boolean).join(" ")
  if (explicit) return explicit
  const username = params.username?.trim()
  if (username) return `@${username}`
  return "Unknown"
}

function formatInlineCapabilitiesProbeLines(probe: unknown): Array<{ text: string; tone?: "error" | "success" }> {
  const details = probe as InlineProbe | undefined
  if (!details) {
    return []
  }
  if (!details.ok) {
    if (details.error?.trim()) {
      return [{ text: `Probe failed: ${details.error}`, tone: "error" }]
    }
    return [{ text: "Probe failed", tone: "error" }]
  }
  const lines: Array<{ text: string; tone?: "error" | "success" }> = []
  if (details.user) {
    const username = details.user.username ? ` @${details.user.username}` : ""
    const botLabel = details.user.bot ? " [bot]" : ""
    lines.push({
      text: `Identity: ${details.user.name}${username} (${details.user.id})${botLabel}`,
      tone: "success",
    })
  }
  if (details.baseUrl) {
    lines.push({ text: `Base URL: ${details.baseUrl}` })
  }
  return lines
}

function toInlineUserDirectoryEntry(user: User) {
  return {
    kind: "user" as const,
    id: String(user.id),
    name: buildInlineDisplayName(user),
    ...(user.username?.trim() ? { handle: `@${user.username.trim()}` } : {}),
    ...(user.profilePhoto?.cdnUrl ? { avatarUrl: user.profilePhoto.cdnUrl } : {}),
    raw: {
      username: user.username ?? null,
      phoneNumber: user.phoneNumber ?? null,
      bot: user.bot ?? false,
    },
  }
}

function toInlineUserTargetId(userId: string): string {
  return `user:${userId}`
}

function toInlineUserTargetDirectoryEntry(user: User) {
  const base = toInlineUserDirectoryEntry(user)
  return {
    ...base,
    id: toInlineUserTargetId(base.id),
  }
}

function toInlineGroupDirectoryEntry(chat: Chat, dialogByChatId: Map<string, Dialog>) {
  const dialog = dialogByChatId.get(String(chat.id))
  return {
    kind: "group" as const,
    id: String(chat.id),
    name: chat.title,
    raw: {
      spaceId: chat.spaceId != null ? String(chat.spaceId) : null,
      isPublic: chat.isPublic ?? false,
      unreadCount: dialog?.unreadCount ?? 0,
      archived: Boolean(dialog?.archived),
      pinned: Boolean(dialog?.pinned),
    },
  }
}

function matchesInlineQuery(value: string, query: string): boolean {
  if (!query) return true
  return value.toLowerCase().includes(query)
}

function normalizeSearchQuery(query: string | null | undefined): string {
  return query?.trim().toLowerCase() ?? ""
}

function buildDialogMap(dialogs: Dialog[]): Map<string, Dialog> {
  const map = new Map<string, Dialog>()
  for (const dialog of dialogs) {
    if (dialog.chatId != null) {
      map.set(String(dialog.chatId), dialog)
      continue
    }
    const peer = dialog.peer?.type
    if (peer?.oneofKind === "chat") {
      map.set(String(peer.chat.chatId), dialog)
    }
  }
  return map
}

async function withInlineClient<T>(params: {
  cfg: OpenClawConfig
  accountId?: string | null
  fn: (client: InlineSdkClient, account: ResolvedInlineAccount) => Promise<T>
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
    return await params.fn(client, account)
  } finally {
    await client.close().catch(() => {})
  }
}

async function sendTypingInline(params: {
  cfg: OpenClawConfig
  to: string
  accountId?: string | null
  threadId?: string | number | null
  typing: boolean
}): Promise<void> {
  let target: InlineParsedOutboundTarget
  try {
    target = parseInlineOutboundTarget({
      raw: params.to,
      context: "sendText",
    })
  } catch {
    return
  }
  if (target.kind === "user") {
    return
  }
  const chatId = resolveInlineReplyThreadChatId({
    cfg: params.cfg,
    accountId: params.accountId ?? null,
    parentChatId: target.targetId,
    threadId: params.threadId ?? null,
  })
  if (chatId == null) {
    return
  }
  await withInlineClient({
    cfg: params.cfg,
    accountId: params.accountId ?? null,
    fn: async (client) => {
      await client.sendTyping({ chatId, typing: params.typing })
    },
  })
}

function recordInlineOutboundThreadParticipation(params: {
  accountId: string
  parentChatId: bigint
  chatId: bigint | null
  threadId?: string | number | null
}): void {
  if (params.threadId == null || params.chatId == null || params.chatId === params.parentChatId) {
    return
  }
  recordInlineThreadParticipation(params.accountId, params.parentChatId, params.chatId)
}

async function notifyPairingApprovedInline(params: {
  cfg: OpenClawConfig
  id: string
}): Promise<void> {
  const normalizedId = normalizeInlineAllowEntry(params.id)
  if (!normalizedId) return
  let userId: bigint
  try {
    userId = BigInt(normalizedId)
  } catch {
    throw new Error(`inline pairing notify: invalid user id "${params.id}"`)
  }

  const accountId = resolveDefaultInlineAccountId(params.cfg)
  const account = resolveInlineAccount({ cfg: params.cfg, accountId })
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
    await client.sendMessage({
      userId,
      text: PAIRING_APPROVED_MESSAGE,
      parseMarkdown: account.config.parseMarkdown ?? true,
    })
  } finally {
    await client.close().catch(() => {})
  }
}

async function sendMessageInline(params: {
  cfg: OpenClawConfig
  to: string
  text: string
  actions?: MessageActions | undefined
  accountId?: string | null
  replyToId?: string | null
  threadId?: string | number | null
}): Promise<{ messageId: string; chatId: string }> {
  const account = resolveInlineAccount({ cfg: params.cfg, accountId: params.accountId ?? null })
  if (!account.configured || !account.baseUrl) {
    throw new Error(`Inline not configured for account "${account.accountId}" (missing token or baseUrl)`)
  }
  const token = await resolveInlineToken(account)

  const target = parseInlineOutboundTarget({
    raw: params.to,
    context: "sendText",
  })
  const visibleText = sanitizeInlineVisibleText(params.text)
  if (visibleText.shouldSkip) {
    return {
      messageId: "",
      chatId: target.kind === "user" ? `user:${target.normalizedNumeric}` : target.normalizedNumeric,
    }
  }
  const text = sanitizeInlineOutgoingText(visibleText.text)

  const client = new InlineSdkClient({
    baseUrl: account.baseUrl,
    token,
  })

  await client.connect()
  try {
    // Inline "threads" are modeled as chats (chatId). OpenClaw's threadId is not a message id.
    // Only map OpenClaw replyToId -> Inline replyToMsgId.
    const replyToMsgId = parseInlineId(params.replyToId)
    const resolvedTarget = await resolveInlineOutboundTarget({
      client,
      context: "sendText",
      target,
    })
    const effectiveChatId =
      resolvedTarget.kind === "chat"
        ? resolveInlineReplyThreadChatId({
            cfg: params.cfg,
            accountId: account.accountId,
            parentChatId: resolvedTarget.targetId,
            threadId: params.threadId ?? null,
          })
        : null
    const result = await client
      .sendMessage({
        ...(effectiveChatId != null ? { chatId: effectiveChatId } : buildInlineSendTarget(resolvedTarget)),
        text,
        ...(params.actions !== undefined ? { actions: params.actions } : {}),
        ...(replyToMsgId != null ? { replyToMsgId } : {}),
        parseMarkdown: account.config.parseMarkdown ?? true,
      })
      .catch((error: unknown) => {
        throw wrapInlineTargetError({
          error,
          context: "sendText",
          target,
          resolvedTarget,
        })
      })
    const bestEffort =
      result.messageId != null ? String(result.messageId) : BigInt(Date.now()).toString()
    if (resolvedTarget.kind === "chat") {
      recordInlineOutboundThreadParticipation({
        accountId: account.accountId,
        parentChatId: resolvedTarget.targetId,
        chatId: effectiveChatId,
        threadId: params.threadId ?? null,
      })
    }
    return {
      messageId: bestEffort,
      chatId:
        effectiveChatId != null ? String(effectiveChatId) : formatInlineResultChatId(resolvedTarget),
    }
  } finally {
    await client.close().catch(() => {})
  }
}

async function sendMediaInline(params: {
  cfg: OpenClawConfig
  to: string
  text: string
  mediaUrl: string
  actions?: MessageActions | undefined
  accountId?: string | null
  replyToId?: string | null
  threadId?: string | number | null
  mediaAccess?: Parameters<typeof uploadInlineMediaFromUrl>[0]["mediaAccess"]
  mediaLocalRoots?: readonly string[]
  mediaReadFile?: (filePath: string) => Promise<Buffer>
}): Promise<{ messageId: string; chatId: string }> {
  const account = resolveInlineAccount({ cfg: params.cfg, accountId: params.accountId ?? null })
  if (!account.configured || !account.baseUrl) {
    throw new Error(`Inline not configured for account "${account.accountId}" (missing token or baseUrl)`)
  }
  const token = await resolveInlineToken(account)

  const target = parseInlineOutboundTarget({
    raw: params.to,
    context: "sendMedia",
  })
  const replyToMsgId = parseInlineId(params.replyToId)
  const visibleText = sanitizeInlineVisibleText(params.text)
  const caption = visibleText.shouldSkip ? "" : sanitizeInlineOutgoingText(visibleText.text).trim()

  const client = new InlineSdkClient({
    baseUrl: account.baseUrl,
    token,
  })

  await client.connect()
  try {
    const resolvedTarget = await resolveInlineOutboundTarget({
      client,
      context: "sendMedia",
      target,
    })
    const effectiveChatId =
      resolvedTarget.kind === "chat"
        ? resolveInlineReplyThreadChatId({
            cfg: params.cfg,
            accountId: account.accountId,
            parentChatId: resolvedTarget.targetId,
            threadId: params.threadId ?? null,
          })
        : null
    const media = await uploadInlineMediaFromUrl({
      client,
      cfg: params.cfg,
      accountId: account.accountId,
      mediaUrl: params.mediaUrl,
      ...(params.mediaAccess ? { mediaAccess: params.mediaAccess } : {}),
      ...(params.mediaLocalRoots ? { mediaLocalRoots: params.mediaLocalRoots } : {}),
      ...(params.mediaReadFile ? { mediaReadFile: params.mediaReadFile } : {}),
    })
    const result = await client
      .sendMessage({
        ...(effectiveChatId != null ? { chatId: effectiveChatId } : buildInlineSendTarget(resolvedTarget)),
        ...(caption ? { text: caption } : {}),
        media,
        ...(params.actions !== undefined ? { actions: params.actions } : {}),
        ...(replyToMsgId != null ? { replyToMsgId } : {}),
        ...(caption ? { parseMarkdown: account.config.parseMarkdown ?? true } : {}),
      })
      .catch((error: unknown) => {
        throw wrapInlineTargetError({
          error,
          context: "sendMedia",
          target,
          resolvedTarget,
        })
      })
    const bestEffort =
      result.messageId != null ? String(result.messageId) : BigInt(Date.now()).toString()
    if (resolvedTarget.kind === "chat") {
      recordInlineOutboundThreadParticipation({
        accountId: account.accountId,
        parentChatId: resolvedTarget.targetId,
        chatId: effectiveChatId,
        threadId: params.threadId ?? null,
      })
    }
    return {
      messageId: bestEffort,
      chatId:
        effectiveChatId != null ? String(effectiveChatId) : formatInlineResultChatId(resolvedTarget),
    }
  } finally {
    await client.close().catch(() => {})
  }
}

function resolveDirectoryLimit(limit: number | null | undefined): number {
  const parsed = typeof limit === "number" ? Math.trunc(limit) : undefined
  return Math.max(1, Math.min(200, parsed ?? 50))
}

async function fetchInlineChatsSnapshot(params: {
  cfg: OpenClawConfig
  accountId?: string | null
}): Promise<{ chats: Chat[]; users: User[]; dialogByChatId: Map<string, Dialog> }> {
  return await withInlineClient({
    cfg: params.cfg,
    accountId: params.accountId ?? null,
    fn: async (client) => {
      const result = await client.invokeRaw(Method.GET_CHATS, {
        oneofKind: "getChats",
        getChats: {},
      })
      if (result.oneofKind !== "getChats") {
        throw new Error(`inline directory: expected getChats result, got ${String(result.oneofKind)}`)
      }
      const chats = result.getChats.chats ?? []
      const users = result.getChats.users ?? []
      const dialogByChatId = buildDialogMap(result.getChats.dialogs ?? [])
      return { chats, users, dialogByChatId }
    },
  })
}

function normalizeResolverInput(input: string): string {
  return input.trim()
}

function resolveInlineGroupCandidates(params: {
  chats: ReturnType<typeof toInlineGroupDirectoryEntry>[]
  input: string
}): Array<{ id: string; name?: string }> {
  const raw = normalizeResolverInput(params.input)
  if (!raw) return []

  const normalized = normalizeInlineTarget(raw) ?? raw
  const lowered = normalized.toLowerCase()
  if (/^[0-9]+$/.test(normalized)) {
    const exact = params.chats.find((chat) => chat.id === normalized)
    return exact ? [{ id: exact.id, name: exact.name }] : []
  }

  const byExactName = params.chats.filter((chat) => (chat.name ?? "").trim().toLowerCase() === lowered)
  if (byExactName.length > 0) {
    return byExactName.map((chat) => ({ id: chat.id, name: chat.name }))
  }

  return params.chats
    .filter((chat) => (chat.name ?? "").trim().toLowerCase().includes(lowered))
    .map((chat) => ({ id: chat.id, name: chat.name }))
}

function resolveInlineUserCandidates(params: {
  users: ReturnType<typeof toInlineUserDirectoryEntry>[]
  input: string
}): Array<{ id: string; name?: string }> {
  const raw = normalizeResolverInput(params.input)
  if (!raw) return []

  const withoutPrefix = raw.replace(/^inline:/i, "").replace(/^user:/i, "").trim()
  const normalized = withoutPrefix.startsWith("@") ? withoutPrefix.slice(1) : withoutPrefix
  const lowered = normalized.toLowerCase()

  if (/^[0-9]+$/.test(normalized)) {
    const exact = params.users.find((user) => user.id === normalized)
    return exact ? [{ id: exact.id, name: exact.name }] : []
  }

  const byHandle = params.users.filter((user) => (user.handle ?? "").replace(/^@/, "").toLowerCase() === lowered)
  if (byHandle.length > 0) {
    return byHandle.map((user) => ({ id: user.id, name: user.name }))
  }

  const byName = params.users.filter((user) => (user.name ?? "").trim().toLowerCase() === lowered)
  if (byName.length > 0) {
    return byName.map((user) => ({ id: user.id, name: user.name }))
  }

  return params.users
    .filter((user) => {
      const haystack = [user.name ?? "", user.handle ?? "", user.id].join("\n").toLowerCase()
      return haystack.includes(lowered)
    })
    .map((user) => ({ id: user.id, name: user.name }))
}

async function resolveInlineAllowlistNames(params: {
  cfg: OpenClawConfig
  accountId?: string | null
  entries: string[]
}): Promise<Array<{ input: string; resolved: boolean; name?: string | null }>> {
  const account = resolveInlineAccount({ cfg: params.cfg, accountId: params.accountId ?? null })
  if (!account.enabled || !account.configured || !account.baseUrl) {
    return []
  }

  const snapshot = await fetchInlineChatsSnapshot({
    cfg: params.cfg,
    accountId: params.accountId ?? null,
  })
  const usersById = new Map(
    snapshot.users.map((user) => {
      const entry = toInlineUserDirectoryEntry(user)
      return [entry.id, entry] as const
    }),
  )

  return params.entries.map((input) => {
    const id = normalizeInlineAllowEntry(input)
    if (!/^[0-9]+$/.test(id)) {
      return { input, resolved: false }
    }
    const user = usersById.get(id)
    if (!user) {
      return { input, resolved: false }
    }
    return {
      input,
      resolved: true,
      name: user.handle ? `${user.name} ${user.handle}` : user.name,
    }
  })
}

const resolveInlineAllowlistGroupOverrides = createFlatAllowlistOverrideResolver({
  resolveRecord: (account: ResolvedInlineAccount) => account.config.groups,
  label: (key) => key,
  resolveEntries: (value) => value?.allowFrom,
})

const inlineOutbound: NonNullable<ChannelPlugin<ResolvedInlineAccount>["outbound"]> = {
  deliveryMode: "direct",
  chunker: (text, limit) => getInlineRuntime().channel.text.chunkMarkdownText(text, limit),
  chunkerMode: "markdown",
  extractMarkdownImages: true,
  textChunkLimit: 4000,
  sanitizeText: ({ text }) => sanitizeInlineOutgoingText(text),
  shouldSkipPlainTextSanitization: ({ payload }) => Boolean(payload.channelData),
  shouldTreatDeliveredTextAsVisible: ({ kind }) => kind !== "final",
  preferFinalAssistantVisibleText: true,
  presentationCapabilities: {
    supported: true,
    buttons: true,
    selects: true,
    context: true,
    divider: false,
  },
  renderPresentation: ({ payload, presentation }) => {
    const text = renderMessagePresentationFallbackText({
      ...(payload.text !== undefined ? { text: payload.text } : {}),
      presentation,
    })
    const interactive = presentationToInteractiveReply(presentation)
    return {
      ...payload,
      text,
      ...(interactive ? { interactive } : {}),
    }
  },
  sendPayload: async ({
    cfg,
    to,
    payload,
    accountId,
    replyToId,
    threadId,
    mediaAccess,
    mediaLocalRoots,
    mediaReadFile,
  }) => {
    const text =
      resolveInlineInteractiveTextFallback({
        text: payload.text ?? undefined,
        interactive: payload.interactive,
        presentation: payload.presentation,
      }) ??
      payload.text ??
      ""
    const payloadReplyToId = typeof payload.replyToId === "string" ? payload.replyToId.trim() : null
    const effectiveReplyToId = payloadReplyToId || replyToId || null
    const actions = resolveInlinePayloadActions(payload as Record<string, unknown>)
    const mediaUrls = payload.mediaUrls?.length
      ? payload.mediaUrls
      : payload.mediaUrl
        ? [payload.mediaUrl]
        : []

    if (mediaUrls.length === 0) {
      const result = await sendMessageInline({
        cfg,
        to,
        text,
        actions,
        accountId: accountId ?? null,
        replyToId: effectiveReplyToId,
        threadId: threadId ?? null,
      })
      return { channel: "inline", to, messageId: result.messageId, chatId: result.chatId }
    }

    let finalResult: { messageId: string; chatId: string } | null = null
    for (let index = 0; index < mediaUrls.length; index += 1) {
      const mediaUrl = mediaUrls[index]
      if (!mediaUrl?.trim()) continue
      const isFirst = index === 0
      finalResult = await sendMediaInline({
        cfg,
        to,
        text: isFirst ? text : "",
        mediaUrl,
        actions: isFirst ? actions : undefined,
        accountId: accountId ?? null,
        replyToId: isFirst ? effectiveReplyToId : null,
        threadId: threadId ?? null,
        ...(mediaAccess ? { mediaAccess } : {}),
        ...(mediaLocalRoots ? { mediaLocalRoots } : {}),
        ...(mediaReadFile ? { mediaReadFile } : {}),
      })
    }

    if (!finalResult) {
      const result = await sendMessageInline({
        cfg,
        to,
        text,
        actions,
        accountId: accountId ?? null,
        replyToId: effectiveReplyToId,
        threadId: threadId ?? null,
      })
      return { channel: "inline", to, messageId: result.messageId, chatId: result.chatId }
    }
    return { channel: "inline", to, messageId: finalResult.messageId, chatId: finalResult.chatId }
  },
  sendText: async ({ cfg, to, text, accountId, replyToId, threadId }) => {
    // Inline threads are modeled as chats. OpenClaw threadId isn't a message id for Inline.
    const result = await sendMessageInline({
      cfg,
      to,
      text,
      accountId: accountId ?? null,
      replyToId: replyToId ?? null,
      threadId: threadId ?? null,
    })
    return { channel: "inline", to, messageId: result.messageId, chatId: result.chatId }
  },
  sendMedia: async ({
    cfg,
    to,
    text,
    mediaUrl,
    accountId,
    replyToId,
    threadId,
    mediaAccess,
    mediaLocalRoots,
    mediaReadFile,
  }) => {
    if (!mediaUrl) {
      const result = await sendMessageInline({
        cfg,
        to,
        text,
        accountId: accountId ?? null,
        replyToId: replyToId ?? null,
        threadId: threadId ?? null,
      })
      return { channel: "inline", to, messageId: result.messageId, chatId: result.chatId }
    }

    // Inline threads are modeled as chats. OpenClaw threadId isn't a message id for Inline.
    const result = await sendMediaInline({
      cfg,
      to,
      text,
      mediaUrl,
      accountId: accountId ?? null,
      replyToId: replyToId ?? null,
      threadId: threadId ?? null,
      ...(mediaAccess ? { mediaAccess } : {}),
      ...(mediaLocalRoots ? { mediaLocalRoots } : {}),
      ...(mediaReadFile ? { mediaReadFile } : {}),
    })
    return { channel: "inline", to, messageId: result.messageId, chatId: result.chatId }
  },
}

const inlineMessageAdapter = createChannelMessageAdapterFromOutbound<OpenClawConfig>({
  id: "inline",
  outbound: inlineOutbound,
  live: {
    capabilities: {
      draftPreview: true,
      previewFinalization: true,
      progressUpdates: true,
    },
    finalizer: {
      capabilities: {
        finalEdit: true,
        normalFallback: true,
        discardPending: true,
      },
    },
  },
})

export const inlineChannelPlugin: ChannelPlugin<ResolvedInlineAccount> = {
  id: "inline",
  meta: inlineMeta,
  capabilities: {
    chatTypes: ["direct", "group"],
    media: true,
    reactions: true,
    edit: true,
    reply: true,
    groupManagement: true,
    threads: true,
    nativeCommands: true,
    blockStreaming: true,
  },
  streaming: {
    blockStreamingCoalesceDefaults: { minChars: 1500, idleMs: 1000 },
  },
  commands: {
    nativeCommandsAutoEnabled: true,
    nativeSkillsAutoEnabled: true,
    buildCommandsListChannelData: buildInlineCommandsListChannelData,
    buildModelsMenuChannelData: buildInlineModelsMenuChannelData,
    buildModelsProviderChannelData: buildInlineModelsProviderChannelData,
    buildModelsAddProviderChannelData: buildInlineModelsAddProviderChannelData,
    buildModelsListChannelData: buildInlineModelsListChannelData,
    buildModelBrowseChannelData: buildInlineModelBrowseChannelData,
  },
  reload: { configPrefixes: ["channels.inline"] },
  lifecycle: {
    onAccountConfigChanged: async ({ prevCfg, nextCfg, accountId }) => {
      if (resolveInlineStateIdentity(prevCfg, accountId) === resolveInlineStateIdentity(nextCfg, accountId)) {
        return
      }
      await deleteInlineAccountState(accountId)
    },
    onAccountRemoved: async ({ accountId }) => {
      await deleteInlineAccountState(accountId)
    },
  },
  configSchema: inlineConfigSchema,
  setup: inlineSetupAdapter,
  setupWizard: inlineSetupWizard,
  doctor: inlineDoctor,
  secrets: inlineSecrets,

  config: inlineConfigAdapter,

  pairing: {
    idLabel: "inlineUserId",
    normalizeAllowEntry: (entry) => normalizeInlineAllowEntry(entry),
    notifyApproval: async ({ cfg, id }) => {
      await notifyPairingApprovedInline({ cfg, id })
    },
  },

  security: inlineSecurityAdapter,
  allowlist: {
    ...buildDmGroupAccountAllowlistAdapter({
      channelId: "inline",
      resolveAccount: ({ cfg, accountId }) => resolveInlineAccount({ cfg, accountId: accountId ?? null }),
      normalize: ({ values }) =>
        values
          .map((entry) => String(entry).trim())
          .filter(Boolean)
          .map((entry) => normalizeInlineAllowEntry(entry)),
      resolveDmAllowFrom: (account) => account.config.allowFrom ?? [],
      resolveGroupAllowFrom: (account) => account.config.groupAllowFrom ?? [],
      resolveDmPolicy: (account) => account.config.dmPolicy,
      resolveGroupPolicy: (account) => account.config.groupPolicy,
      resolveGroupOverrides: resolveInlineAllowlistGroupOverrides,
    }),
    resolveNames: resolveInlineAllowlistNames,
  },
  bindings: {
    compileConfiguredBinding: ({ conversationId }) => {
      const normalized = normalizeInlineConversationId(conversationId)
      if (!normalized) {
        return null
      }
      return { conversationId: normalized }
    },
    matchInboundConversation: ({ compiledBinding, conversationId, parentConversationId }) => {
      const expected = normalizeInlineConversationId(compiledBinding.conversationId)
      if (!expected) {
        return null
      }
      const incoming = normalizeInlineConversationId(conversationId)
      const parent = parentConversationId ? normalizeInlineConversationId(parentConversationId) : null
      if (incoming && incoming === expected) {
        return {
          conversationId: incoming,
          ...(parent ? { parentConversationId: parent } : {}),
          matchPriority: 2,
        }
      }
      if (incoming && parent && parent === expected) {
        return {
          conversationId: incoming,
          parentConversationId: parent,
          matchPriority: 1,
        }
      }
      return null
    },
  },
  conversationBindings: {
    supportsCurrentConversationBinding: true,
    defaultTopLevelPlacement: "current",
    resolveConversationRef: ({ conversationId, parentConversationId, threadId }) =>
      resolveInlineConversationRef({
        conversationId,
        ...(parentConversationId !== undefined ? { parentConversationId } : {}),
        ...(threadId !== undefined ? { threadId } : {}),
      }),
  },

  groups: {
    resolveRequireMention: ({ cfg, accountId, groupId }) => {
      const resolved = resolveInlineAccount({ cfg, accountId: accountId ?? null })
      return resolveInlineGroupRequireMention({
        cfg,
        groupId,
        accountId,
        requireMentionDefault: resolved.config.requireMention ?? INLINE_DEFAULT_REQUIRE_MENTION,
      })
    },
    resolveToolPolicy: ({ cfg, accountId, groupId, senderId, senderName, senderUsername, senderE164 }) =>
      resolveInlineGroupToolPolicy({
        cfg,
        groupId,
        accountId,
        senderId,
        senderName,
        senderUsername,
        senderE164,
      }),
  },

  threading: {
    resolveReplyToMode: () => "off",
    buildToolContext: ({ cfg, accountId, context, hasRepliedRef }) => {
      if (!isInlineReplyThreadsEnabled({ cfg, accountId: accountId ?? null })) {
        return undefined
      }
      const currentChannelId = context.To?.trim() || undefined
      if (!currentChannelId) {
        return undefined
      }
      return {
        currentChannelId,
        ...(context.MessageThreadId != null
          ? { currentThreadTs: String(context.MessageThreadId) }
          : {}),
        ...(context.CurrentMessageId != null ? { currentMessageId: context.CurrentMessageId } : {}),
        replyToMode: "off" as const,
        ...(hasRepliedRef ? { hasRepliedRef } : {}),
      }
    },
    resolveReplyTransport: ({ cfg, accountId, threadId, replyToId }) => {
      if (!isInlineReplyThreadsEnabled({ cfg, accountId: accountId ?? null })) {
        return null
      }
      return {
        threadId: threadId != null ? String(threadId) : null,
        replyToId: replyToId ?? null,
      }
    },
  },

  agentPrompt: {
    inboundFormattingHints: () => buildInlineInboundFormattingHints(),
    reactionGuidance: ({ cfg, accountId }) =>
      supportsInlineReactionsForConfig(cfg, accountId ?? null)
        ? { level: "minimal", channelLabel: "Inline" }
        : undefined,
    messageToolCapabilities: ({ cfg, accountId }) =>
      supportsInlineMessageButtonsForConfig(cfg, accountId ?? null) ? ["inlineButtons"] : [],
    messageToolHints: ({ cfg, accountId }) => [
      "- Inline targeting: omit `target` to reply in the current chat.",
      "- Inline explicit targets: `chat:<chatId>` for chats and `user:<userId>` for direct users. Prefer `user:` for DM user targets.",
      "- Inline discovery: use `channel-list` to discover available chats and users. Use `scope: groups|peers|all` when helpful, and reuse returned `target` values.",
      "- Inline markdown links: in visible replies, link returned users as `[@name](inline://user?id=<userId>)` and returned chats/threads as `[title](inline://chat?id=<chatId>)` or `[title](inline://thread?id=<chatId>)`. Use `target` values only for tool calls.",
      ...(supportsInlineMessageButtonsForConfig(cfg, accountId ?? null)
        ? [
            "- Prefer Inline buttons/selects for 2-5 discrete choices or parameter picks instead of asking the user to type one. Use `presentation` blocks for shared buttons/selects, or `buttons` rows with `callback_data` for callbacks and `copy_text`/`copyText` for copy buttons. For quick button feedback, JSON `callback_data` can include `callbackToast`/`toast`.",
          ]
        : []),
      ...(supportsInlineReactionsForConfig(cfg, accountId ?? null)
        ? [
            "- Inline reactions: pass `messageId` for `react` when you have it; on inbound turns, the current inbound message id can be used as fallback.",
          ]
        : []),
      "- Inline history tools: `read` and `search` return media-aware message payloads (`media`, `attachments`, `attachmentUrls`) so image-only history remains discoverable. `search` is chat-scoped; run it per chat.",
      "- Inline bot command discovery: use `peer-bot-commands`/`bot-commands` to read commands available in the current or target chat/user/reply thread; use `inline_bot_commands` only to manage this bot's registered command menu.",
      "- Inline special tools: use `inline_members` to find users in a space and reuse returned `user:<id>` DM targets. It can infer `spaceId` inside a current Inline space chat/reply thread; pass `spaceId` explicitly otherwise. Use `inline_parent_context` for more parent-chat history from the current reply thread, with `beforeMessageId`, `afterMessageId`, or `messageId` for older/newer/around windows.",
      "- Inline special tools: use `inline_nudge` to send a nudge, `inline_forward` to forward message ids between chats or users, and `inline_bot_presence` to move or emote through your on-screen body without sending a chat message.",
      "- Inline bot profile setup: use `inline_update_profile` only when the user explicitly asks to change your Inline bot display name or profile photo.",
      "- Inline bot avatar setup: use `inline_bot_avatar` only when the user explicitly asks you to install, replace, or clear your on-screen avatar. Do not call it during ordinary chat, do not invent file paths, and do not use it for mood/state changes.",
      "- Inline bot command setup: use `inline_bot_commands` to get, set, or delete this bot's registered command menu; do not use it to execute slash commands.",
      "- Inline botPresence is your literal on-screen character/body in Inline, not another answer channel. Treat `kind` as your body pose/mood and `comment` as a tiny thought bubble or body-language caption; use `action: get` only when you need to inspect the current avatar/state.",
      "- Inline botPresence states: use `waving` for greetings/attention, `jumping` for delight or completion, `review` for inspecting/thinking, `waiting` when asking the human, `failed` when blocked or disappointed, `running` for active focused work, `happy` for positive/settled moments, and `idle` only when neutral is intentionally useful. Do not use it to hide yourself.",
      "- Inline botPresence comments: include a generated `comment` when it helps the human understand your current mood, thought, status, request, nudge, or small aside. Keep it casual, short, characterful, and true to what you are doing or feeling; under 30 characters. Text or one/two emoji characters are both fine. It should supplement the full chat answer, not replace substantive answers.",
      "- Inline botPresence is cheap to call during active work. Use it when your thought/body state changes or when a tiny status would make you easier to read; long work past roughly 20s should use a fresh, true comment if you keep the body active. Avoid repeated identical updates, fixed-timer filler, or static comments.",
      "- Inline botPresence final beat: before your final chat message in active Inline chats, make one last `inline_bot_presence` call whenever there is a real final expression to show. Do this for greetings (`waving`, `hey 👋` or `👋`), weather/status answers (`happy`, `☀️ 72°` or `rainy ☔️`), completed longer work (`jumping`, `phew, done!`), blockers (`failed`, short reason), or requests for user input (`waiting`, short ask). Then send the normal full chat answer. Do not send `idle` just to clean up; the client quiets the presence later.",
      "- Inline botPresence in messages: when you are already sending a message, you may also set `channelData.inline.botPresence` with the same `kind` and `comment` fields.",
      "- Inline voice messages: Inline normally auto-transcribes voice notes by editing the message text shortly after upload. Treat text on an Inline voice turn as the preferred transcript; only use configured audio transcription when you receive raw audio without transcript text.",
      "- Inline reply threads: use normal `reply` for short or newly started parent-chat conversations unless the user asks for a thread.",
      "- Inline reply threads: use `thread-create` to create or reuse a real reply thread under the current/target chat. On parent-chat inbound turns, omit `messageId` to anchor it to the current message, or pass `messageId`/`parentMessageId` explicitly.",
      "- Inline reply threads: use `thread-reply` to send into a real reply thread. Prefer `threadId` from `thread-create`; when already inside a reply-thread turn you may omit it, and after `thread-create` you may pass the parent chat target plus `parentMessageId` to recover the saved route.",
      "- Inline reply threads: when already inside a reply-thread chat, continue in that reply thread and do not create nested reply threads.",
      "- Inline reply-thread turns include nearby parent-chat context as background only; answer the current reply-thread conversation, not unrelated parent-chat or other-thread questions; unrelated parent-chat messages need separate parent-message anchors.",
    ],
  },

  messaging: {
    targetPrefixes: ["inline"],
    transformReplyPayload: ({ payload }) => {
      if (typeof payload.text !== "string") {
        return payload
      }
      const text = sanitizeInlineOutgoingText(payload.text)
      return text === payload.text ? payload : { ...payload, text }
    },
    normalizeTarget: normalizeInlineTarget,
    resolveInboundConversation: ({ to, conversationId, threadId }) =>
      resolveInlineInboundConversation({
        ...(to !== undefined ? { to } : {}),
        ...(conversationId !== undefined ? { conversationId } : {}),
        ...(threadId !== undefined ? { threadId } : {}),
      }),
    resolveDeliveryTarget: ({ conversationId, parentConversationId }) =>
      resolveInlineDeliveryTarget({
        conversationId,
        ...(parentConversationId !== undefined ? { parentConversationId } : {}),
      }),
    resolveSessionConversation: ({ rawId }) => resolveInlineSessionConversation({ rawId }),
    resolveSessionTarget: ({ id }) => resolveInlineSessionTarget({ id }),
    preserveHeartbeatThreadIdForGroupRoute: true,
    parseExplicitTarget: ({ raw }) => {
      try {
        const parsed = parseInlineExplicitTarget(raw)
        if (!parsed) return null
        return { to: parsed.to, chatType: parsed.chatType }
      } catch {
        return null
      }
    },
    inferTargetChatType: ({ to }) => {
      try {
        const parsed = parseInlineExplicitTarget(to)
        return parsed?.chatType
      } catch {
        return undefined
      }
    },
    resolveOutboundSessionRoute: (params) => resolveInlineOutboundSessionRoute(params),
    formatTargetDisplay: ({ target, display, kind }) =>
      formatInlineTargetDisplay({
        target,
        ...(display !== undefined ? { display } : {}),
        ...(kind !== undefined ? { kind } : {}),
      }),
    targetResolver: {
      looksLikeId: looksLikeInlineTargetId,
      hint: "<chatId | chat:<chatId> | user:<userId>>",
    },
  },

  heartbeat: {
    sendTyping: async ({ cfg, to, accountId, threadId }) => {
      await sendTypingInline({
        cfg,
        to,
        accountId: accountId ?? null,
        threadId: threadId ?? null,
        typing: true,
      })
    },
    clearTyping: async ({ cfg, to, accountId, threadId }) => {
      await sendTypingInline({
        cfg,
        to,
        accountId: accountId ?? null,
        threadId: threadId ?? null,
        typing: false,
      })
    },
  },

  approvalCapability: {
    ...inlineApprovalCapability,
    render: {
      exec: {
        buildPendingPayload: ({ request, nowMs }) =>
          buildInlineExecApprovalPendingPayload({ request, nowMs }),
      },
    },
  },

  directory: {
    self: async ({ cfg, accountId }) =>
      await withInlineClient({
        cfg,
        accountId: accountId ?? null,
        fn: async (client) => {
          const result = await client.invokeRaw(Method.GET_ME, {
            oneofKind: "getMe",
            getMe: {},
          })
          if (result.oneofKind !== "getMe") {
            throw new Error(`inline directory: expected getMe result, got ${String(result.oneofKind)}`)
          }
          if (!result.getMe.user) {
            throw new Error("inline directory: missing current user from getMe")
          }
          return toInlineUserDirectoryEntry(result.getMe.user)
        },
      }),
    listPeers: async ({ cfg, accountId, query, limit }) => {
      const snapshot = await fetchInlineChatsSnapshot({
        cfg,
        accountId: accountId ?? null,
      })
      const normalizedQuery = normalizeSearchQuery(query)
      const maxItems = resolveDirectoryLimit(limit)
      return snapshot.users
        .map((user) => toInlineUserTargetDirectoryEntry(user))
        .filter((user) => {
          if (!normalizedQuery) return true
          const haystack = [user.id, user.name ?? "", user.handle ?? ""].join("\n").toLowerCase()
          return matchesInlineQuery(haystack, normalizedQuery)
        })
        .slice(0, maxItems)
    },
    listGroups: async ({ cfg, accountId, query, limit }) => {
      const snapshot = await fetchInlineChatsSnapshot({
        cfg,
        accountId: accountId ?? null,
      })
      const normalizedQuery = normalizeSearchQuery(query)
      const maxItems = resolveDirectoryLimit(limit)
      return snapshot.chats
        .map((chat) => toInlineGroupDirectoryEntry(chat, snapshot.dialogByChatId))
        .filter((chat) => {
          if (!normalizedQuery) return true
          const haystack = [chat.id, chat.name ?? ""].join("\n").toLowerCase()
          return matchesInlineQuery(haystack, normalizedQuery)
        })
        .slice(0, maxItems)
    },
    listGroupMembers: async ({ cfg, accountId, groupId, limit }) =>
      await withInlineClient({
        cfg,
        accountId: accountId ?? null,
        fn: async (client) => {
          const normalizedGroupId = normalizeInlineTarget(groupId) ?? groupId.trim()
          if (!/^[0-9]+$/.test(normalizedGroupId)) {
            throw new Error(`inline directory: invalid groupId "${groupId}"`)
          }
          const chatId = BigInt(normalizedGroupId)
          const result = await client.invokeRaw(Method.GET_CHAT_PARTICIPANTS, {
            oneofKind: "getChatParticipants",
            getChatParticipants: { chatId },
          })
          if (result.oneofKind !== "getChatParticipants") {
            throw new Error(
              `inline directory: expected getChatParticipants result, got ${String(result.oneofKind)}`,
            )
          }
          const usersById = new Map(
            (result.getChatParticipants.users ?? []).map((user) => [String(user.id), user] as const),
          )
          const maxItems = resolveDirectoryLimit(limit)
          return (result.getChatParticipants.participants ?? [])
            .map((participant) => usersById.get(String(participant.userId)))
            .filter((user): user is User => Boolean(user))
            .map((user) => toInlineUserTargetDirectoryEntry(user))
            .slice(0, maxItems)
        },
      }),
  },

  resolver: {
    resolveTargets: async ({ cfg, accountId, inputs, kind }) => {
      const snapshot = await fetchInlineChatsSnapshot({
        cfg,
        accountId: accountId ?? null,
      })
      if (kind === "group") {
        const groups = snapshot.chats.map((chat) => toInlineGroupDirectoryEntry(chat, snapshot.dialogByChatId))
        return inputs.map((input) => {
          const candidates = resolveInlineGroupCandidates({ chats: groups, input })
          if (candidates.length === 1) {
            const candidate = candidates[0]
            if (!candidate) {
              return { input, resolved: false, note: "group not found" }
            }
            return {
              input,
              resolved: true,
              id: candidate.id,
              ...(candidate.name ? { name: candidate.name } : {}),
            }
          }
          if (candidates.length > 1) {
            return { input, resolved: false, note: "multiple matching groups" }
          }
          return { input, resolved: false, note: "group not found" }
        })
      }

      const users = snapshot.users.map((user) => toInlineUserDirectoryEntry(user))
      return inputs.map((input) => {
        const candidates = resolveInlineUserCandidates({ users, input })
        if (candidates.length === 1) {
          const candidate = candidates[0]
          if (!candidate) {
            return { input, resolved: false, note: "user not found" }
          }
          return {
            input,
            resolved: true,
            id: toInlineUserTargetId(candidate.id),
            ...(candidate.name ? { name: candidate.name } : {}),
          }
        }
        if (candidates.length > 1) {
          return { input, resolved: false, note: "multiple matching users" }
        }
        return { input, resolved: false, note: "user not found" }
      })
    },
  },

  actions: inlineMessageActions,
  outbound: inlineOutbound,
  message: inlineMessageAdapter,

  status: {
    defaultRuntime: {
      accountId: DEFAULT_ACCOUNT_ID,
      running: false,
      connected: false,
      lastStartAt: null,
      lastStopAt: null,
      lastConnectedAt: null,
      lastEventAt: null,
      lastTransportActivityAt: null,
      lastError: null,
      lastProbeAt: null,
    },
    collectStatusIssues: collectInlineStatusIssues,
    buildChannelSummary: ({ snapshot }) => buildTokenChannelStatusSummary(snapshot),
    probeAccount: async ({ account, timeoutMs }) => await probeInlineAccount(account, timeoutMs),
    formatCapabilitiesProbe: ({ probe }) => formatInlineCapabilitiesProbeLines(probe),
    buildAccountSnapshot: ({ cfg, account, runtime, probe }) => {
      const inspected = inspectInlineAccount({
        cfg: cfg as OpenClawConfig,
        accountId: account.accountId,
      })
      const ownerAccountId = findInlineTokenOwnerAccountId({
        cfg: cfg as OpenClawConfig,
        accountId: account.accountId,
      })
      const duplicateTokenReason = ownerAccountId
        ? formatDuplicateInlineTokenReason({
            accountId: account.accountId,
            ownerAccountId,
          })
        : null
      const snapshot = {
        accountId: account.accountId,
        name: account.name,
        enabled: account.enabled,
        configured: inspected.configured && !ownerAccountId,
        baseUrl: account.baseUrl ? "[set]" : "[missing]",
        tokenSource: inspected.tokenSource,
        reactionNotifications: account.reactionNotifications,
        ...(account.reactionAllowlist !== undefined
          ? { reactionAllowlist: account.reactionAllowlist }
          : {}),
        running: runtime?.running ?? false,
        connected: runtime?.connected ?? false,
        lastStartAt: runtime?.lastStartAt ?? null,
        lastStopAt: runtime?.lastStopAt ?? null,
        lastConnectedAt: runtime?.lastConnectedAt ?? null,
        lastEventAt: runtime?.lastEventAt ?? null,
        lastTransportActivityAt: runtime?.lastTransportActivityAt ?? null,
        lastError: runtime?.lastError ?? duplicateTokenReason,
        lastInboundAt: runtime?.lastInboundAt ?? null,
        lastOutboundAt: runtime?.lastOutboundAt ?? null,
        lastProbeAt: runtime?.lastProbeAt ?? null,
        ...(probe !== undefined ? { probe } : {}),
      } as Record<string, unknown>

      const diagnostics = (runtime as { diagnostics?: unknown } | undefined)?.diagnostics
      if (diagnostics !== undefined) {
        snapshot.diagnostics = diagnostics
      }

      return snapshot as any
    },
  },

  gateway: {
    startAccount: async (ctx) => {
      const account = ctx.account
      const ownerAccountId = findInlineTokenOwnerAccountId({
        cfg: ctx.cfg as OpenClawConfig,
        accountId: account.accountId,
      })
      if (ownerAccountId) {
        const reason = formatDuplicateInlineTokenReason({
          accountId: account.accountId,
          ownerAccountId,
        })
        ctx.log?.error?.(`[${account.accountId}] ${reason}`)
        throw new Error(reason)
      }
      if (!account.configured || !account.baseUrl) {
        throw new Error(
          `Inline not configured for account "${account.accountId}" (missing baseUrl or token)`,
        )
      }

      ctx.log?.info(`[${account.accountId}] starting Inline realtime monitor`)

      // Best-effort stop if already running for this account.
      const existing = activeMonitors.get(account.accountId)
      if (existing) {
        await existing.stop().catch(() => {})
        activeMonitors.delete(account.accountId)
      }

      const now = Date.now()
      ctx.setStatus({
        ...ctx.getStatus(),
        accountId: account.accountId,
        configured: true,
        running: true,
        connected: false,
        lastStartAt: now,
        lastConnectedAt: null,
        lastEventAt: null,
        lastTransportActivityAt: null,
        lastError: null,
      })

      const handle = await monitorInlineProvider({
        cfg: ctx.cfg as OpenClawConfig,
        account,
        runtime: ctx.runtime,
        ...(ctx.channelRuntime ? { channelRuntime: ctx.channelRuntime } : {}),
        abortSignal: ctx.abortSignal,
        ...(ctx.log ? { log: ctx.log } : {}),
        statusSink: (patch) => {
          ctx.setStatus({ ...ctx.getStatus(), ...patch })
        },
      })

      activeMonitors.set(account.accountId, handle)
      try {
        await handle.done
      } finally {
        activeMonitors.delete(account.accountId)
        await handle.stop().catch(() => {})
      }
    },

    stopAccount: async (ctx) => {
      const existing = activeMonitors.get(ctx.account.accountId)
      if (existing) {
        await existing.stop().catch(() => {})
        activeMonitors.delete(ctx.account.accountId)
      }
      ctx.setStatus({
        ...ctx.getStatus(),
        running: false,
        connected: false,
        lastStopAt: Date.now(),
      })
    },
    logoutAccount: async ({ accountId, cfg }) => {
      const cleanup = clearInlineAccountCredentials({ cfg, accountId })
      if (cleanup.changed) {
        return {
          cleared: cleanup.cleared,
          loggedOut: cleanup.cleared,
          cfg: cleanup.cfg,
          message: cleanup.cleared
            ? "Inline credentials cleared from config. Restart gateway to apply."
            : "Inline credential fields removed from config.",
        }
      }

      const envToken = resolveInlineEnvToken() ?? ""
      if (accountId === DEFAULT_ACCOUNT_ID && envToken) {
        return {
          cleared: false,
          loggedOut: false,
          message:
            "No Inline credentials found in config. INLINE_TOKEN/INLINE_BOT_TOKEN is set in env; unset it and restart gateway to fully log out.",
        }
      }

      return {
        cleared: false,
        loggedOut: false,
        message: "No Inline credentials found in config for this account.",
      }
    },
  },
}
