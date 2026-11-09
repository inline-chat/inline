import { formatQuietTimeline, activityAttention, activityLifecycleOutcome, preserveActivityTitles, ACTIVITY_MESSAGE_MAX_CHARS, type ActivityOutcome } from "./quiet-timeline.js"
import { reportOpenClawPluginError } from "../telemetry.js"
import { mkdir, stat } from "node:fs/promises"
import path from "node:path"
import { beginInlineActiveThreadRoute, type ActiveInlineThreadRoute } from "./active-thread-route.js"
import {
  resolveCommandArgMenuAsync,
} from "openclaw/plugin-sdk/native-command-registry"
import { CHANNEL_APPROVAL_NATIVE_RUNTIME_CONTEXT_CAPABILITY } from "openclaw/plugin-sdk/approval-handler-adapter-runtime"
import { registerChannelRuntimeContext } from "openclaw/plugin-sdk/channel-runtime-context"
import {
  resolveCommandAuthorizationAsync,
} from "openclaw/plugin-sdk/command-auth-native"
import { expandAllowFromWithAccessGroups } from "openclaw/plugin-sdk/security-runtime"
import { buildCommandsMessagePaginated } from "openclaw/plugin-sdk/command-status"
import {
  createConnectedChannelStatusPatch,
  createTransportActivityStatusPatch,
} from "openclaw/plugin-sdk/gateway-runtime"
import {
  hasFinalInboundReplyDispatch,
  hasVisibleInboundReplyDispatch,
  classifyChannelInboundEvent,
  createChannelInboundDebouncer,
  resolveUnmentionedGroupInboundPolicy,
  shouldDebounceTextInbound,
} from "openclaw/plugin-sdk/channel-inbound"
import {
  resolveDefaultModelForAgent,
} from "openclaw/plugin-sdk/agent-runtime"
import {
  applySessionEntryPatch,
  resolveStorePath,
} from "openclaw/plugin-sdk/session-store-runtime"
import { buildModelsProviderData } from "openclaw/plugin-sdk/models-provider-runtime"
import { prepareSkillCommandsForAgents } from "openclaw/plugin-sdk/skill-commands-runtime"
import {
  buildChannelProgressDraftLine,
  buildChannelProgressDraftLineForEntry,
  createChannelProgressDraftGate,
  formatChannelProgressDraftText,
  resolveChannelProgressDraftMaxLines,
  isChannelProgressDraftWorkToolName,
  mergeChannelProgressDraftLine,
  resolveChannelProgressDraftMaxLineChars,
  resolveChannelStreamingPreviewToolProgress,
  type AgentPlanStep,
  type ChannelProgressDraftLine,
} from "openclaw/plugin-sdk/channel-outbound"
import { normalizeLowercaseStringOrEmpty } from "openclaw/plugin-sdk/string-coerce-runtime"
import {
  clearHistoryEntriesIfEnabled,
  createChannelReplyPipelineCompat,
  recordPendingHistoryEntryIfEnabled,
  type InlineTypingCallbacks,
} from "../sdk-runtime-compat.js"
import type { OpenClawConfig, PluginCommandContext } from "openclaw/plugin-sdk/core"
import type { ChannelRuntimeSurface } from "openclaw/plugin-sdk/channel-contract"
import type { RuntimeEnv } from "openclaw/plugin-sdk/runtime-env"
import { resolveInboundLastRouteSessionKey } from "openclaw/plugin-sdk/routing"
import {
  BotCapability_Kind,
  BotChatSettingsProblem_Code,
  DialogFollowMode,
  InlineSdkAuthenticationError,
  InlineSdkClient,
  JsonFileStateStore,
  Method,
  registerBotCapabilitiesWithRetry,
  type Message,
  type MessageActions,
  type User,
} from "@inline-chat/realtime-sdk"
import { resolveInlineToken, type ResolvedInlineAccount } from "./accounts.js"
import { shareInlineAccountClient } from "./client-registry.js"
import { createInlineMessageSender } from "./delivery.js"
import {
  INLINE_DEFAULT_GROUP_POLICY,
  INLINE_DEFAULT_REQUIRE_MENTION,
} from "./config-schema.js"
import { isInlineExecApprovalHandlerConfigured } from "./exec-approvals.js"
import { buildInlineSystemPrompt, isInlineHostNoReplyFallback, sanitizeInlineOutgoingText } from "./message-formatting.js"
import {
  resolveInlineGroupAllowFrom,
  resolveInlineGroupAccessPolicy,
  resolveInlineGroupRequireMention,
  resolveInlineGroupReplyThreadMode,
  resolveInlineGroupReplyThreadParentHistoryLimit,
  resolveInlineGroupReplyThreadRequireExplicitMention,
  resolveInlineGroupSystemPrompt,
} from "./policy.js"
import { getInlineRuntime } from "../runtime.js"
import { uploadInlineMediaFromUrl } from "./media.js"
import {
  summarizeInlineMessageContent,
} from "./message-content.js"
import { callInlineBotApi } from "./bot-commands-api.js"
import {
  buildInlineAgentSpecializationPrompt,
  createInlineAgentSpecializationResolver,
  projectInlineAgentSessionKey,
} from "./agent-specialization.js"
import {
  buildInlineAgentActionBody,
  buildInlineAgentActionStructuredContext,
  resolveInlineMessageActionOwnership,
} from "./message-actions.js"
import { resolveInlineInteractiveTextFallback } from "./interactive-fallback.js"
import {
  InlineSenderProfileCache,
} from "./sender-profile-cache.js"
import {
  buildInlineCommandsListChannelData,
  buildInlineModelProviderButtons,
  parseInlineCommandsPageCallback,
  type InlineReplyMarkupButton,
} from "./command-ui.js"
import {
  createInlineReplyThreadForMessage,
  isInlineReplyThreadsEnabled,
} from "./reply-threads.js"
import {
  lookupInlineReplyThreadRoute,
  lookupInlineReplyThreadRouteByThreadId,
  rememberInlineReplyThreadRoute,
} from "./thread-routes.js"
import {
  resolveInlineThreadFreshness,
} from "./thread-freshness.js"
import {
  logInboundDrop,
  resolveControlCommandGate,
  resolveMentionGatingWithBypass,
  setOpenClawAgentDefaultModel,
  resolveUseAccessGroups,
} from "../openclaw-compat.js"
import { mutateInlineLiveConfig, resolveInlineLiveConfig } from "./live-config.js"
import {
  handleInlineThreadReplyCommandWithConfigRuntime,
  resolveCurrentMode as resolveInlineThreadReplyMode,
  setGroupMode as setInlineThreadReplyMode,
} from "./threadreply-command.js"
import {
  inlineFollowCommandFailureText,
  inlineFollowCommandSuccessText,
  inlineFollowCommandUsageText,
  inlineFollowModeForCommand,
  parseInlineFollowCommandBody,
  summarizeInlineFollowCommandError,
  takeInlineFollowModeChanged,
  updateInlineFollowMode,
} from "./follow-command.js"
import {
  OPENCLAW_BOT_CHAT_SETTINGS_VERSION,
  buildOpenClawBotChatSettingsDocument,
  invokeOpenClawBotChatSetting,
  openClawBotChatSettingsProblem,
  type OpenClawBotChatSettingsContext,
  type OpenClawBotChatSettingsOption,
} from "./bot-chat-settings.js"
import { CHANNEL_ID, type InlineReplyPayload, isRecord, buildChatPeer } from "./monitor-shared.js"
import {
  buildInlineTypingDispatcherOptions,
  sendInlineTypingToChats,
  resolveInlineBotPresenceSignal,
  sendInlineTypingAndBotPresenceToChats,
  createInlineBotPresenceLifecycle,
} from "./monitor-presence.js"
import { resolveInlinePayloadMediaUrls, resolveInlineChatVisibleReplyPayload } from "./monitor-reasoning.js"
import {
  normalizeInlineUsername,
  resolveInlineCommandTarget,
  leadingInlineBotCommandTargetUserId,
  startsWithUnclaimedInlineBotCommand,
  isInlineServiceMessage,
  isInlineAbortRequestMessage,
  findInlineNativeCommandFromBody,
  resolveInlineCommandNameFromBody,
  listHostInlinePluginCommandSpecs,
  hasInlineCommandSpec,
  isInlineThreadReplyCommandBody,
  parseInlineCommandArgs,
  isInlineNativeCommandBody,
  stripInlineBotMention,
  stripInlineBotMentionEntityText,
  collectInlineMentionedUserIds,
  leadingInlineMentionUserIds,
  isInlineDialogFollowing,
  isInlineDialogExplicitlyUnfollowed,
  resolveInlineMentionSource,
} from "./monitor-addressing.js"
import {
  resolveInlineParentSessionKeyCandidate,
  resolveInlineCommandMenuModelContext,
  resolveInlineThinkMenuCurrentLevel,
  resolveInlineNativeCommandMenu,
  parseInlineModelPickerCallback,
  resolveInlineModelPickerSelection,
} from "./monitor-model-menu.js"
import {
  callbackDataToBase64,
  callbackDataToUtf8,
  resolveInlineCallbackResponseUi,
  resolveInlineReplyActions,
  answerInlineMessageAction,
  resolveCallbackCommandBodyFromActionData,
} from "./monitor-reply-actions.js"
import {
  type CachedChatInfo,
  type InlinePendingHistoryEntry,
  type InlineReplyThreadContext,
  REPLY_TARGET_LOOKUP_LIMIT,
  resolveChatInfo,
  rewriteNumericMentionsToUsernames,
  rememberInlineBotDelivery,
  loadInlineJoinWindowMessages,
  findChatMessageById,
  isReactionTargetBotMessage,
  normalizeHistoryText,
  buildInlineReplyThreadLabel,
  resolveInlineSenderLabel,
  resolveInlineDirectSenderName,
  resolveInlineConversationLabel,
  resolveHistoryLimit,
  mergeInboundHistoryEntries,
  prependInlineReplyThreadAnchor,
  prependInlineParentHistoryContext,
  buildInlineChannelStructuredContext,
  resolveInlineInboundReplyThreadContext,
  resolveInlineReplyThreadContextFromRoute,
  buildReplyThreadParentHistoryContext,
  buildHistoryContext,
} from "./monitor-history.js"
import {
  resolveInlineMediaMaxBytes,
  buildInlineInboundMediaFacts,
  buildInlineInboundBodyText,
  resolveInlineInboundMedia,
} from "./monitor-media.js"

const INLINE_REQUEST_ERROR_FALLBACK =
  "OpenClaw could not process that request. Please try again."
const INLINE_DEBOUNCE_ERROR_FALLBACK =
  "OpenClaw could not process those messages. Please try again."
const INLINE_REPLY_SESSION_INIT_CONFLICT_RE = /reply session initialization conflicted for \S+/u
const INLINE_REPLY_SESSION_INIT_RETRY_DELAYS_MS = [50, 150, 300, 600] as const
const DEFAULT_REPLY_THREAD_PARENT_HISTORY_LIMIT = 10
const DEFAULT_INLINE_VOICE_TRANSCRIPT_WAIT_MS = 8_000
const MAX_INLINE_VOICE_TRANSCRIPT_WAIT_MS = 60_000
const INLINE_REPLY_THREAD_SYSTEM_PROMPT =
  "Inline reply threads are scoped conversations: reply to the current reply-thread message using this thread's own history, with parent-chat context as background. Don't pick up questions asked in the parent chat or other reply threads as if they were addressed here. Earlier conversation lives in the parent chat; read it with inline_parent_context. When someone here asks about another chat or thread you're in, you may read it with the message tool's read action."
// Telegram's drop_pending_on_cold_boot, for Inline: updates the server recorded
// before this gateway process started don't wake the agent. A lost or fresh SDK
// cursor otherwise replays chat history as new messages.
const INLINE_PROCESS_STARTED_AT_SECONDS = Date.now() / 1000
const INLINE_COLD_BOOT_CLOCK_SKEW_SECONDS = 60
const INLINE_COLD_BOOT_DROP_LOG_INTERVAL_MS = 60_000
const INLINE_COLD_BOOT_GATED_EVENTS = new Set([
  "message.new",
  "message.edit",
  "reaction.add",
  "reaction.delete",
])

// The Claude Code runtime reaches OpenClaw tools over MCP, so they arrive as
// `mcp__openclaw__exec`; the host would title that "Mcp Openclaw Exec".
const INLINE_OPENCLAW_MCP_TOOL_PREFIX = /^mcp__openclaw__/

function normalizeInlineProgressToolInput<T>(input: T): T {
  const record = input as { event?: unknown; name?: unknown }
  if (record.event !== "tool" || typeof record.name !== "string") return input
  const name = record.name.replace(INLINE_OPENCLAW_MCP_TOOL_PREFIX, "")
  return name === record.name ? input : { ...input, name }
}

const INLINE_COMMAND_TOOL_NAMES = new Set(["exec", "bash", "shell"])

// Say what the command is, like bridge v2 ("Running `cargo test`"), not "Exec".
function relabelInlineCommandProgressLine(line: unknown, input: unknown): void {
  const record = input as {
    event?: unknown
    name?: unknown
    phase?: unknown
    title?: unknown
    args?: { command?: unknown }
  }
  if (!line || typeof line !== "object" || typeof record.name !== "string") return
  if (!INLINE_COMMAND_TOOL_NAMES.has(record.name.replace(INLINE_OPENCLAW_MCP_TOOL_PREFIX, ""))) return
  const shorten = (value: unknown): string => {
    const command = typeof value === "string" ? value.replace(/\s+/g, " ").trim() : ""
    return command.length > 80 ? `${command.slice(0, 79)}…` : command
  }
  // The host decides whether command text is shown (`commandText`, "status" by
  // default on every channel): it is in the host's line only when allowed.
  const hostText = typeof (line as { text?: unknown }).text === "string" ? (line as { text: string }).text : ""
  if (record.event === "tool") {
    const raw = typeof record.args?.command === "string" ? record.args.command.trim() : ""
    const command = raw && hostText.includes(raw) ? shorten(raw) : ""
    Object.assign(line, { text: command ? `Running \`${command}\`` : "Running a command", label: "Running a command" })
    return
  }
  if (record.event === "item" && record.phase === "end") {
    // Host item titles read `command <text>`; anything else is not the command.
    const title = typeof record.title === "string" ? record.title.match(/^command\s+(.+)$/s)?.[1] : undefined
    const command = title && hostText.includes(title.trim()) ? shorten(title) : ""
    Object.assign(line, { text: command ? `Ran \`${command}\`` : "Ran a command", label: "Ran a command" })
  }
}

const INLINE_OUT_OF_BAND_COMMAND_RE = /^\/(?:approve|stop)(?:@[A-Za-z0-9_]+)?(?:\s|$)/i

export function isInlineOutOfBandCommandText(text: string | undefined | null): boolean {
  return typeof text === "string" && INLINE_OUT_OF_BAND_COMMAND_RE.test(text.trim())
}

function decodeInlineCallbackText(data: Uint8Array): string {
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(data)
  } catch {
    return ""
  }
}

const INLINE_BOT_HAND_BACK_SYSTEM_PROMPT =
  "This message is another bot's reply to you. It needs no answer: your response will not reach that bot. To ask it for more, mention it."

type InlineMonitorHandle = {
  stop: () => Promise<void>
  done: Promise<void>
}

async function dispatchInlineReplyWithSessionInitRetry<T>(params: {
  run: () => Promise<T>
  shouldRetry: () => boolean
  onRetry?: (retry: number, delayMs: number) => void
}): Promise<{ result: T; retries: number }> {
  let retries = 0
  while (true) {
    try {
      const result = await params.run()
      return { result, retries }
    } catch (error) {
      const delayMs = INLINE_REPLY_SESSION_INIT_RETRY_DELAYS_MS[retries]
      if (
        delayMs == null ||
        !params.shouldRetry() ||
        !INLINE_REPLY_SESSION_INIT_CONFLICT_RE.test(String(error))
      ) {
        throw error
      }
      retries += 1
      params.onRetry?.(retries, delayMs)
      await new Promise<void>((resolve) => setTimeout(resolve, delayMs))
    }
  }
}

type StatusSink = (patch: {
  connected?: boolean
  lastConnectedAt?: number | null
  lastEventAt?: number | null
  lastTransportActivityAt?: number | null
  lastInboundAt?: number
  lastOutboundAt?: number
  lastError?: string | null
  diagnostics?: unknown
}) => void

type InlineDiagnosticsSnapshot = {
  protocol?: {
    state?: unknown
    ping?: {
      pendingCount?: unknown
    }
    transport?: {
      state?: unknown
      socketReadyState?: unknown
    } | null
  } | null
}

type InlineEditStreamState = {
  messageId: bigint | null
  initialSendMayHaveLanded: boolean
  accumulatedText: string
  lastPartialText: string
  finalTextAccumulator: string
  failed: boolean
  pendingSnapshot: InlineEditStreamSnapshot | null
  inFlight: Promise<void> | null
  timer: ReturnType<typeof setTimeout> | null
  nextAllowedAt: number
  actionsFingerprint: string | null
  latestActions: MessageActions | undefined
}

type InlineEditStreamSnapshot = {
  text: string
  actions?: MessageActions
  actionsFingerprint: string | null
}

type InlinePartialMediaDeliveryResult = {
  mediaUrl: string
  messageId: bigint | null
  sent: boolean
  usedUrlFallback: boolean
  commitOutcomeUnknown: boolean
}

type InlineClosedProgressRow = {
  messageId: bigint
  chatId: bigint
  lines: Array<string | ChannelProgressDraftLine>
  elapsed: number
  toolFailed: boolean
  outcome: ActivityOutcome
}

type InlineProgressPlaceholderState = {
  messageId: bigint | null
  text: string
  lines: Array<string | ChannelProgressDraftLine>
  opChain: Promise<void>
  closing: boolean
  startedAt: number | null
  toolFailed: boolean
  lastClosed: InlineClosedProgressRow | null
  pendingClosures: Set<InlineClosedProgressRow>
}

type InlineDispatchReplyInfo = {
  kind?: string
  reason?: string
}

type InlineDispatchResult = NonNullable<Parameters<typeof hasVisibleInboundReplyDispatch>[0]> & {
  queuedFinal?: boolean
  observedReplyDelivery?: boolean
  noVisibleReplyFallbackDelivered?: boolean
  noVisibleReplyFallbackEligible?: boolean
  deliberateSilentTerminalReply?: boolean
  sourceReplyDeliveryMode?: string
  sendPolicyDenied?: boolean
}

type InlineReplyDeliveryResult = {
  visibleReplySent: boolean
  suppression?: { reason: "no_visible_result" }
}

function normalizeInlineDispatchResult(value: unknown): InlineDispatchResult {
  return isRecord(value) ? (value as InlineDispatchResult) : {}
}

function inlineReplyDeliveryResult(visibleReplySent: boolean): InlineReplyDeliveryResult {
  return visibleReplySent
    ? { visibleReplySent: true }
    : { visibleReplySent: false, suppression: { reason: "no_visible_result" } }
}

class OpenClawBotChatSettingsMutationError extends Error {}

function classifyOpenClawBotSettingsError(error: unknown): string | undefined {
  const message = error instanceof Error
    ? error.message
    : typeof error === "string"
      ? error
      : ""
  if (!message.trim()) return undefined
  if (/invalid_refresh_token|oauth.{0,40}refresh|\b(?:401|unauthorized)\b/iu.test(message)) {
    return "OpenClaw authentication failed. Re-authenticate the model provider and try again."
  }
  if (/rate.?limit|\b429\b|quota/iu.test(message)) {
    return "The model provider is rate-limited or out of quota. Try again later or choose another model."
  }
  if (/credentials?.{0,40}(?:missing|not found)|(?:missing|no).{0,40}credentials?/iu.test(message)) {
    return "OpenClaw is missing credentials for this model. Configure the provider and try again."
  }
  if (/model.{0,60}(?:unavailable|not found|unknown|not allowed)/iu.test(message)) {
    return "The selected model is unavailable in OpenClaw. Choose another model or refresh settings."
  }
  if (/timed? out|timeout/iu.test(message)) {
    return "OpenClaw timed out while updating this setting. Try again."
  }
  if (/\b403\b|forbidden|permission denied/iu.test(message)) {
    return "OpenClaw denied this change. Check provider access and try again."
  }
  if (/ECONN|ENET|socket|network|gateway.{0,40}(?:closed|unreachable|unavailable)/iu.test(message)) {
    return "OpenClaw’s gateway or model provider is unreachable. Check the connection and try again."
  }
  return undefined
}

function summarizeOpenClawCommandFailure(reply: string): string {
  const classified = classifyOpenClawBotSettingsError(reply)
  if (classified) return classified
  const concise = reply
    .replace(/[*_`]/gu, "")
    .replace(/\s+/gu, " ")
    .trim()
    .slice(0, 220)
  return concise
    ? `OpenClaw rejected the model change: ${concise}`
    : "OpenClaw did not apply the requested session model."
}

function buildInlineReplyThreadSessionKey(parentSessionKey: string, threadChatId: bigint): string {
  const suffix = `:thread:${String(threadChatId)}`
  return parentSessionKey.endsWith(suffix) ? parentSessionKey : `${parentSessionKey}${suffix}`
}

type InlineDebounceEntry = {
  chatId: bigint
  msg: Message
}

type InlinePendingVoiceMessage = {
  chatId: bigint
  msg: Message
  timeout: ReturnType<typeof setTimeout>
}

type InlineParsedInboundEvent = {
  chatId: bigint
  msg: Message
  messageIds?: string[]
  rawBodyOverride?: string | null
  callbackActionEvent?: {
    interactionId: bigint
    actionId: string
    targetMessageId: bigint
    data: Uint8Array
  } | null
}

type InlineSystemEventContext = {
  channelLabel: string
  sessionKey: string
  agentId: string
  effectiveChatId: bigint
  isReplyThread: boolean
  conversationKind: CachedChatInfo["kind"]
  chatInfo: CachedChatInfo
}

function summarizeSdkMeta(meta: unknown): string {
  if (meta == null) return ""
  if (meta instanceof Error) return `${meta.name}: ${meta.message}`
  if (typeof meta === "string") return meta
  try {
    const json = JSON.stringify(meta)
    return json === undefined ? String(meta) : json
  } catch {
    return String(meta)
  }
}

function formatSdkLogLine(message: string, meta?: unknown): string {
  const detail = summarizeSdkMeta(meta)
  if (!detail) return message
  return `${message} ${detail}`
}

function isRecoverableInlineConnectionError(line: string): boolean {
  return /^(WebSocket (?:closed|error|reconnect scheduled)|Protocol reconnect scheduled|Ping timeout, reconnecting|Failed to send RPC request; waiting for reconnect)/.test(line)
}

function isNonStickyInlineSdkWarning(line: string): boolean {
  return line.startsWith("GET_UPDATES_STATE failed (continuing without date cursor)")
}

function isNonStickyInlineSdkRecoveryDiagnostic(message: string): boolean {
  return message === "Sync recovery scheduled" ||
    message === "Sync bucket unavailable" ||
    message === "Sync discovery unavailable"
}

function isInlineConnectionRecovered(diagnostics: unknown): boolean {
  const snapshot = diagnostics as InlineDiagnosticsSnapshot
  const protocol = snapshot.protocol
  if (protocol?.state !== "open") return false

  const transport = protocol.transport
  if (transport?.state != null && transport.state !== "connected") return false
  if (transport?.socketReadyState != null && transport.socketReadyState !== 1) return false

  const pendingCount = protocol.ping?.pendingCount
  return typeof pendingCount !== "number" || pendingCount === 0
}

function formatInlineOperationError(operation: string, error: unknown): string {
  const detail = summarizeSdkMeta(error) || String(error)
  return `${operation} failed: ${detail}`
}

function inlineErrorChainHasCode(error: unknown, code: string): boolean {
  const visited = new Set<unknown>()
  let current: unknown = error
  while (current && typeof current === "object" && !visited.has(current)) {
    visited.add(current)
    if ((current as { code?: unknown }).code === code) return true
    current = (current as { cause?: unknown }).cause
  }
  return false
}

function isInlineCommitOutcomeUnknown(error: unknown): boolean {
  return inlineErrorChainHasCode(error, "commit-outcome-unknown")
}

function isInlineSendOutcomeUnknown(error: unknown): boolean {
  return isInlineCommitOutcomeUnknown(error) || inlineErrorChainHasCode(error, "timeout")
}

const INLINE_EDIT_STREAM_MIN_INTERVAL_MS = 250
const INLINE_EDIT_STREAM_MAX_INTERVAL_MS = 750
const EMPTY_RESPONSE_FALLBACK = "No response generated. Please try again."

function normalizeAllowEntry(raw: string): string {
  const withoutChannel = raw.trim().replace(/^inline:/i, "").trim()
  if (/^chat:/i.test(withoutChannel)) {
    return withoutChannel
  }
  return withoutChannel.replace(/^user:/i, "").trim()
}

function fingerprintInlineMessageActions(actions: MessageActions | undefined): string | null {
  if (actions === undefined) return null
  return JSON.stringify(actions, (_key, value) =>
    value instanceof Uint8Array ? Array.from(value) : value)
}

function normalizeAllowlist(entries: Array<string | number> | undefined): string[] {
  return (entries ?? [])
    .map((entry) => normalizeAllowEntry(String(entry)))
    .map((entry) => entry.trim())
    .filter(Boolean)
}

function sanitizeInlineDeliveryText(text: string): string {
  return sanitizeInlineOutgoingText(text)
}

function allowlistMatch(params: { allowFrom: string[]; senderId: string }): boolean {
  if (params.allowFrom.some((entry) => entry === "*")) return true
  return params.allowFrom.some((entry) => entry === params.senderId)
}

async function resolveInlineAllowlist(params: {
  cfg: OpenClawConfig
  accountId: string
  entries: Array<string | number> | undefined
  senderId: string
}): Promise<string[]> {
  const raw = (params.entries ?? []).map(String)
  const expanded = await expandAllowFromWithAccessGroups({
    cfg: params.cfg,
    allowFrom: raw,
    channel: CHANNEL_ID,
    accountId: params.accountId,
    senderId: params.senderId,
    isSenderAllowed: (candidateSenderId, allowFrom) =>
      allowlistMatch({
        allowFrom: normalizeAllowlist(allowFrom),
        senderId: candidateSenderId,
      }),
  })
  return normalizeAllowlist(expanded)
}

async function resolveInlineGroupSenderAllowlist(params: {
  cfg: OpenClawConfig
  account: ResolvedInlineAccount
  groupId: string
  senderId: string | null
}): Promise<{
  raw: string[]
  expanded: string[]
}> {
  const entries = resolveInlineGroupAllowFrom({
    cfg: params.cfg,
    accountId: params.account.accountId,
    groupId: params.groupId,
    accountAllowFrom: params.account.config.groupAllowFrom,
  })
  const raw = normalizeAllowlist(entries)
  if (params.senderId == null) {
    return {
      raw,
      expanded: raw.includes("*") ? ["*"] : [],
    }
  }
  return {
    raw,
    expanded: await resolveInlineAllowlist({
      cfg: params.cfg,
      accountId: params.account.accountId,
      entries,
      senderId: params.senderId,
    }),
  }
}

async function resolveInlineCommandAuthorized(params: {
  cfg: OpenClawConfig
  accountId: string
  isGroup: boolean
  chatId: string
  senderId: string
  commandAuthorized: boolean
}): Promise<boolean> {
  const authorization = await resolveCommandAuthorizationAsync({
    ctx: {
      Provider: CHANNEL_ID,
      Surface: CHANNEL_ID,
      OriginatingChannel: CHANNEL_ID,
      AccountId: params.accountId,
      ChatType: params.isGroup ? "group" : "direct",
      From: params.isGroup ? `inline:chat:${params.chatId}` : `inline:${params.senderId}`,
      To: `inline:${params.chatId}`,
      SenderId: params.senderId,
    },
    cfg: params.cfg,
    commandAuthorized: params.commandAuthorized,
  })
  return authorization.isAuthorizedSender
}

function hasExplicitInlineCommandAuthorizationPolicy(cfg: OpenClawConfig): boolean {
  return cfg.commands?.ownerAllowFrom !== undefined || cfg.commands?.allowFrom !== undefined
}

function formatInlineSystemEventChannelLabel(params: {
  chatInfo: CachedChatInfo
  effectiveChatId: bigint
}): string {
  const title = params.chatInfo.title?.trim()
  if (params.chatInfo.kind === "direct") {
    return title ? `direct chat with ${title}` : `direct chat ${String(params.effectiveChatId)}`
  }
  if (!title) return `chat ${String(params.effectiveChatId)}`
  return title.startsWith("#") ? title : `#${title}`
}

function describeInlineMessageLifecycleSystemEvent(params: {
  action: "edited" | "deleted"
  messageCount: number
  channelLabel: string
}): string {
  const subject = params.messageCount === 1 ? "message" : "messages"
  return `Inline ${subject} ${params.action} in ${params.channelLabel}.`
}

function buildInlineMessageLifecycleContextKey(params: {
  action: "edited" | "deleted"
  chatId: bigint
  messageIds: bigint[]
}): string {
  const ids = params.messageIds.map(String).sort().join(",")
  return `inline:message:${params.action}:${String(params.chatId)}:${ids}`
}

function describeInlineReactionSystemEvent(params: {
  action: "added" | "removed"
  emoji: string
  senderLabel: string
  channelLabel: string
  messageId: bigint
}): string {
  const emoji = params.emoji.trim() || "emoji"
  return `Inline reaction ${params.action}: ${emoji} by ${params.senderLabel} in ${params.channelLabel} msg ${String(params.messageId)}`
}

function buildInlineReactionContextKey(params: {
  action: "added" | "removed"
  chatId: bigint
  messageId: bigint
  senderId: bigint
  emoji: string
}): string {
  const emoji = params.emoji.trim() || "emoji"
  return `inline:reaction:${params.action}:${String(params.chatId)}:${String(params.messageId)}:${String(params.senderId)}:${emoji}`
}

function buildInlineInboundMessageSid(params: {
  msgId: bigint
  callbackActionEvent?: {
    interactionId: bigint
    targetMessageId: bigint
  } | null
}): string {
  if (params.callbackActionEvent) {
    return `callback:${String(params.callbackActionEvent.targetMessageId)}:${String(params.callbackActionEvent.interactionId)}`
  }
  return String(params.msgId)
}

function claimInlineInboundMessageInstance(params: {
  seen: Map<string, true>
  chatId: bigint
  message: Pick<Message, "id" | "date">
  maximum?: number
}): boolean {
  const message = params.message as Message
  const media = message.media as
    | { media?: { oneofKind?: string }; oneofKind?: string }
    | undefined
  const content = [
    String(message.fromId ?? 0n),
    message.message ?? "",
    String(message.replyToMsgId ?? 0n),
    media?.media?.oneofKind ?? media?.oneofKind ?? "",
    String(message.entities?.entities.length ?? 0),
  ].join("\u0000")
  const key = `${String(params.chatId)}:${String(message.id)}:${String(message.date ?? 0n)}:${content}`
  if (params.seen.has(key)) return false
  params.seen.set(key, true)
  const maximum = params.maximum ?? 5_000
  while (params.seen.size > maximum) {
    const oldest = params.seen.keys().next().value
    if (oldest == null) break
    params.seen.delete(oldest)
  }
  return true
}

function buildInlineDebounceKey(params: {
  accountId: string
  chatId: bigint
  senderId: bigint | null | undefined
}): string | null {
  if (params.senderId == null) return null
  return `inline:${params.accountId}:${String(params.chatId)}:${String(params.senderId)}`
}

function buildInlineInboundTaskKey(params: {
  accountId: string
  chatId: bigint
}): string {
  return `inline:${params.accountId}:${String(params.chatId)}`
}

function buildSyntheticInlineTextMessage(params: {
  base: Message
  text: string
  mentioned?: boolean
}): Message {
  return {
    ...params.base,
    message: params.text,
    ...(params.mentioned !== undefined ? { mentioned: params.mentioned } : {}),
  }
}

function buildInlineTranscriptTextMessage(params: {
  base: Message
  text: string
}): Message {
  const { media: _media, ...base } = params.base as Message & { media?: unknown }
  return {
    ...base,
    message: params.text,
  } as Message
}

function buildInlineVoicePendingKey(params: { chatId: bigint; messageId: bigint }): string {
  return `${String(params.chatId)}:${String(params.messageId)}`
}

function resolveInlineVoiceTranscriptWaitMs(config: { voiceTranscriptWaitMs?: unknown }): number {
  const raw = config.voiceTranscriptWaitMs
  if (typeof raw !== "number" || !Number.isFinite(raw)) {
    return DEFAULT_INLINE_VOICE_TRANSCRIPT_WAIT_MS
  }
  return Math.max(0, Math.min(MAX_INLINE_VOICE_TRANSCRIPT_WAIT_MS, Math.trunc(raw)))
}

function resolveInlineInboundDebounceMsOverride(config: { debounceMs?: unknown }): number | undefined {
  const raw = config.debounceMs
  if (typeof raw !== "number" || !Number.isFinite(raw)) {
    return undefined
  }
  return Math.max(0, Math.trunc(raw))
}

function shouldWaitForInlineVoiceTranscript(message: Message): boolean {
  const content = summarizeInlineMessageContent(message)
  return content.media?.kind === "voice" && !content.rawText
}

function extractInlineVoiceTranscriptText(message: Message): string | null {
  const text = message.message?.trim()
  return text ? text : null
}

type InlineStreamingMode = "off" | "partial" | "block" | "progress"

function normalizeInlineStreamingMode(value: unknown): InlineStreamingMode | null {
  if (typeof value !== "string") return null
  const normalized = normalizeLowercaseStringOrEmpty(value)
  switch (normalized) {
    case "off":
    case "partial":
    case "block":
    case "progress":
      return normalized
    default:
      return null
  }
}

function resolveExplicitInlineStreamingMode(config: {
  streaming?: unknown
  streamMode?: unknown
}): InlineStreamingMode | null {
  const streaming = isRecord(config.streaming) ? config.streaming : null
  return (
    normalizeInlineStreamingMode(streaming?.mode) ??
    normalizeInlineStreamingMode(config.streaming) ??
    normalizeInlineStreamingMode(config.streamMode)
  )
}

function resolveInlineStreamingMode(config: {
  streaming?: unknown
  streamMode?: unknown
  streamViaEditMessage?: boolean | undefined
}): InlineStreamingMode {
  const mode = resolveExplicitInlineStreamingMode(config)
  if (mode) return mode
  if (typeof config.streaming === "boolean") {
    return config.streaming ? "partial" : "off"
  }
  return config.streamViaEditMessage === true ? "partial" : "off"
}

function resolveInlineProgressPlaceholderEnabled(config: {
  streaming?: unknown
  streamMode?: unknown
  streamViaEditMessage?: boolean | undefined
}): boolean {
  const mode = resolveExplicitInlineStreamingMode(config)
  if (mode === "off") return false
  if (mode === "progress") return true
  if (config.streaming === false) return false
  if (isRecord(config.streaming) && isRecord(config.streaming.progress)) return true

  // Friendly by default (D2): Working status while it runs, no progress card.
  // `streaming: { mode: "progress" }` opts into the card.
  return false
}

function resolveInlineBlockStreamingEnabled(config: {
  streaming?: unknown
  streamMode?: unknown
  blockStreaming?: boolean | undefined
  streamViaEditMessage?: boolean | undefined
}): boolean | undefined {
  const mode = resolveInlineStreamingMode(config)
  const streaming = isRecord(config.streaming) ? config.streaming : null
  const block = streaming && isRecord(streaming.block) ? streaming.block : null
  if (typeof block?.enabled === "boolean") return block.enabled
  if (typeof config.blockStreaming === "boolean") return config.blockStreaming
  if (mode === "block") return true
  if (mode === "off") return false
  return undefined
}

function shouldStartInlineProgressPlaceholderNow(
  line: string | ChannelProgressDraftLine | undefined,
): boolean {
  return typeof line === "object" && line?.kind === "patch" && Boolean(line.detail)
}

function resolveInlineSystemPrompt(params: {
  account: ResolvedInlineAccount
  groupId?: string
  replyThread?: boolean
  botHandBack?: boolean
}): string {
  const groupPrompt = params.groupId
    ? resolveInlineGroupSystemPrompt({
        groups: params.account.config.groups,
        groupId: params.groupId,
      })
    : undefined
  return [
    buildInlineSystemPrompt(params.account.config.systemPrompt),
    groupPrompt,
    params.replyThread ? INLINE_REPLY_THREAD_SYSTEM_PROMPT : undefined,
    params.botHandBack ? INLINE_BOT_HAND_BACK_SYSTEM_PROMPT : undefined,
  ]
    .filter((entry): entry is string => Boolean(entry))
    .join("\n\n")
}

export async function monitorInlineProvider(params: {
  cfg: OpenClawConfig
  account: ResolvedInlineAccount
  runtime: RuntimeEnv
  channelRuntime?: ChannelRuntimeSurface
  abortSignal: AbortSignal
  log?: { info: (msg: string) => void; warn: (msg: string) => void; error: (msg: string) => void; debug?: (msg: string) => void }
  statusSink?: StatusSink
}): Promise<InlineMonitorHandle> {
  let { cfg } = params
  const { account, runtime, log, statusSink } = params
  const shutdown = new AbortController()
  const abortSignal = AbortSignal.any([params.abortSignal, shutdown.signal])
  const core = getInlineRuntime()
  // Settings changed in chat (/threads, inline_reply_threads, follow callbacks)
  // write config without a gateway reload, so pick up the host's live snapshot
  // whenever it changes rather than keeping the one this monitor started with.
  const readLiveConfig = (): OpenClawConfig | undefined => {
    try {
      return (core.config as { current?: () => unknown } | undefined)?.current?.() as OpenClawConfig | undefined
    } catch {
      return undefined
    }
  }
  const readResolvedLiveConfig = () => {
    const live = readLiveConfig()
    return live ? resolveInlineLiveConfig(live) as OpenClawConfig : undefined
  }
  let lastLiveConfig = readResolvedLiveConfig()
  const refreshLiveConfig = () => {
    const live = readResolvedLiveConfig()
    if (live && live !== lastLiveConfig) {
      lastLiveConfig = live
      cfg = live
    }
  }

  if (!account.configured || !account.baseUrl) {
    throw new Error(`Inline not configured for account "${account.accountId}" (missing baseUrl or token)`)
  }
  const botApiBaseUrl = account.baseUrl
  const token = await resolveInlineToken(account)

  const stateDir = core.state.resolveStateDir()
  const statePath = path.join(stateDir, "channels", "inline", `${account.accountId}.json`)
  const hasExistingState = await stat(statePath).then(() => true).catch(() => false)
  await mkdir(path.dirname(statePath), { recursive: true })

  let client: InlineSdkClient | null = null
  let currentLastError: string | null = null
  let recoverableConnectionError: string | null = null
  const publishStatus = (patch: Parameters<StatusSink>[0]) => {
    if (Object.prototype.hasOwnProperty.call(patch, "lastError")) {
      currentLastError = typeof patch.lastError === "string" ? patch.lastError : null
      if (currentLastError == null) {
        recoverableConnectionError = null
      }
    }
    statusSink?.(patch)
  }
  const pushDiagnostics = (patch?: Parameters<StatusSink>[0]) => {
    const diagnostics = client?.getDiagnostics()
    const nextPatch = { ...patch }
    if (
      diagnostics &&
      !Object.prototype.hasOwnProperty.call(nextPatch, "lastError") &&
      currentLastError != null &&
      currentLastError === recoverableConnectionError &&
      isInlineConnectionRecovered(diagnostics)
    ) {
      nextPatch.lastError = null
    }
    publishStatus({
      ...nextPatch,
      ...(diagnostics ? { diagnostics } : {}),
    })
  }
  const sdkLog = {
    debug: (msg: string, meta?: unknown) => log?.debug?.(formatSdkLogLine(msg, meta)),
    info: (msg: string, meta?: unknown) => log?.info(formatSdkLogLine(msg, meta)),
    warn: (msg: string, meta?: unknown) => {
      const line = formatSdkLogLine(msg, meta)
      log?.warn(line)
      if (isRecoverableInlineConnectionError(line)) {
        recoverableConnectionError = line
      } else if (isNonStickyInlineSdkWarning(line)) {
        pushDiagnostics()
        return
      } else {
        recoverableConnectionError = null
      }
      pushDiagnostics({ lastError: line })
    },
    error: (msg: string, meta?: unknown) => {
      const line = formatSdkLogLine(msg, meta)
      const isRecoveryDiagnostic = isNonStickyInlineSdkRecoveryDiagnostic(msg)
      if (isRecoveryDiagnostic) {
        reportOpenClawPluginError("sdk.sync_recovery", new Error(line))
      }
      log?.error(line)
      if (isRecoveryDiagnostic) {
        pushDiagnostics()
        return
      }
      if (isRecoverableInlineConnectionError(line)) {
        recoverableConnectionError = line
      } else {
        recoverableConnectionError = null
      }
      pushDiagnostics({ lastError: line })
    },
  }

  client = new InlineSdkClient({
    baseUrl: account.baseUrl,
    token,
    logger: sdkLog,
    state: new JsonFileStateStore(statePath),
    catchUpUserFromStart: hasExistingState,
    onAuthenticationError: (error) => {
      recoverableConnectionError = null
      pushDiagnostics({
        connected: false,
        lastError: formatInlineOperationError("inline authentication", error),
      })
    },
  })

  let meUser: User | null = null
  let startupOperation = "inline startup connect"
  try {
    await client.connect(abortSignal)
    pushDiagnostics()
    startupOperation = "inline startup getMe"
    const meResult = await client.invokeRaw(Method.GET_ME, {
      oneofKind: "getMe",
      getMe: {},
    }, { signal: abortSignal })
    if (meResult.oneofKind !== "getMe" || !meResult.getMe.user) {
      throw new Error("missing user")
    }
    meUser = meResult.getMe.user
  } catch (err) {
    const message = formatInlineOperationError(startupOperation, err)
    pushDiagnostics({ connected: false, lastError: message })
    await client.close().catch((closeErr) => {
      log?.warn(`inline startup cleanup failed: ${formatInlineOperationError("client close", closeErr)}`)
    })
    if (err instanceof InlineSdkAuthenticationError) throw err
    throw new Error(message)
  }
  if (!meUser) {
    throw new Error("inline startup getMe failed: missing user")
  }
  const unshareClient = shareInlineAccountClient({
    accountId: account.accountId,
    baseUrl: account.baseUrl,
    token,
    client,
  })
  const sendMessage = createInlineMessageSender(client, abortSignal)
  const meId = meUser.id
  const botUsername = normalizeInlineUsername(meUser.username)?.toLowerCase()
  void registerBotCapabilitiesWithRetry({
    register: () => client.setMyBotCapabilities({
      capabilities: [{
        kind: BotCapability_Kind.CHAT_SETTINGS,
        version: OPENCLAW_BOT_CHAT_SETTINGS_VERSION,
      }],
    }),
    isCancelled: () => abortSignal.aborted,
    onFailure: (error, willRetry) => {
      log?.warn(
        `[${account.accountId}] inline agent settings registration failed: ${String(error)}`
          + (willRetry ? "; retrying" : ""),
      )
    },
  })
  log?.info(`[${account.accountId}] inline connected (me=${String(meId)})`)
  const connectedAt = Date.now()
  pushDiagnostics({
    ...createConnectedChannelStatusPatch(connectedAt),
    ...createTransportActivityStatusPatch(connectedAt),
    lastError: null,
  })
  if (isInlineExecApprovalHandlerConfigured({ cfg, accountId: account.accountId })) {
    registerChannelRuntimeContext({
      channelId: CHANNEL_ID,
      accountId: account.accountId,
      capability: CHANNEL_APPROVAL_NATIVE_RUNTIME_CONTEXT_CAPABILITY,
      context: {
        client,
        parseMarkdown: account.config.parseMarkdown ?? true,
      },
      ...(params.channelRuntime ? { channelRuntime: params.channelRuntime } : {}),
      abortSignal,
    })
  }

  const chatCache = new Map<bigint, CachedChatInfo>()
  const senderProfilesById = new InlineSenderProfileCache({
    fetchChatParticipants: async (chatId) => {
      const result = await client.invokeRaw(Method.GET_CHAT_PARTICIPANTS, {
        oneofKind: "getChatParticipants",
        getChatParticipants: { chatId },
      })
      if (result.oneofKind !== "getChatParticipants") {
        throw new Error(`unexpected response: ${result.oneofKind ?? "unknown"}`)
      }
      return result.getChatParticipants.users ?? []
    },
    fetchDirectoryUsers: async () => {
      const result = await client.invokeRaw(Method.GET_CHATS, {
        oneofKind: "getChats",
        getChats: {},
      })
      if (result.oneofKind !== "getChats") {
        throw new Error(`unexpected response: ${result.oneofKind ?? "unknown"}`)
      }
      return result.getChats.users ?? []
    },
    onError: (operation, error) => {
      publishStatus({ lastError: `${operation} failed: ${String(error)}` })
    },
  })
  const botMessageIdsByChat = new Map<string, string[]>()
  const seenInboundMessageInstances = new Map<string, true>()
  const groupPendingHistories = new Map<string, InlinePendingHistoryEntry[]>()
  const inlineAgentResolver = createInlineAgentSpecializationResolver({
    fetchAgent: async (agentId) => {
      const result = await callInlineBotApi<{
        agent?: { name?: string; skill_key?: string; instructions?: string }
      }>({
        baseUrl: botApiBaseUrl,
        token,
        methodName: "getAgent",
        method: "GET",
        query: { agent_id: agentId },
      })
      const agent = result.agent
      if (!agent?.name) return null
      return {
        name: agent.name,
        ...(agent.skill_key ? { skillKey: agent.skill_key } : {}),
        ...(agent.instructions ? { instructions: agent.instructions } : {}),
      }
    },
  })
  const inboundMediaMaxBytes = resolveInlineMediaMaxBytes({ cfg, account })

  const hydrateChatParticipants = (chatId: bigint): Promise<void> => senderProfilesById.hydrateChat(chatId)

  const projectSavedInlineReplyThreadSessionKey = async (params: {
    baseSessionKey: string
    threadId: bigint
    agentId: string
    eventKind: string
  }): Promise<string> => {
    const threadedSessionKey = buildInlineReplyThreadSessionKey(
      params.baseSessionKey,
      params.threadId,
    )
    try {
      const savedRoute = await lookupInlineReplyThreadRouteByThreadId({
        accountId: account.accountId,
        threadId: params.threadId,
      })
      if (
        savedRoute?.agentId !== params.agentId ||
        !savedRoute.inlineAgentId
      ) {
        return threadedSessionKey
      }
      const specialization = await inlineAgentResolver.resolve(savedRoute.inlineAgentId)
      return projectInlineAgentSessionKey(
        threadedSessionKey,
        savedRoute.inlineAgentId,
        specialization,
      )
    } catch (error) {
      runtime.error?.(
        `inline: ${params.eventKind} reply-thread specialization lookup failed: ${String(error)}`,
      )
      return threadedSessionKey
    }
  }

  const resolveInlineSystemEventContext = async (params: {
    chatId: bigint
    senderId?: bigint | null
    eventKind: string
  }): Promise<InlineSystemEventContext | null> => {
    let chatInfo: CachedChatInfo
    try {
      chatInfo = await resolveChatInfo(client, chatCache, params.chatId)
    } catch (err) {
      publishStatus({ lastError: `getChat failed: ${String(err)}` })
      return null
    }

    const replyThreadsEnabled = isInlineReplyThreadsEnabled({ cfg, accountId: account.accountId })
    let replyThreadContextFailed = false
    const replyThreadContext = await resolveInlineInboundReplyThreadContext({
      replyThreadsEnabled,
      client,
      chatId: params.chatId,
      chatInfo,
      chatCache,
      // resolveChatInfo already loaded the child record. Reuse its parent
      // metadata so a transient second GET_CHAT cannot turn a known child into
      // an apparent top-level group.
      useCachedChatMetadata: true,
    }).catch((err) => {
      publishStatus({ lastError: `getChat (system event reply thread) failed: ${String(err)}` })
      replyThreadContextFailed = true
      return null
    })
    if (replyThreadContextFailed && chatInfo.parentChatId != null) {
      log?.warn(
        `[${account.accountId}] inline: drop ${params.eventKind} child=${String(params.chatId)} (parent chat unavailable)`,
      )
      return null
    }
    const conversationKind = replyThreadContext?.parentChatKind ?? chatInfo.kind
    const isGroup = conversationKind !== "direct"
    const effectiveChatId = replyThreadContext?.parentChatId ?? params.chatId
    const effectiveChatInfo =
      replyThreadContext?.parentChatId != null
        ? {
            ...chatInfo,
            kind: replyThreadContext.parentChatKind,
            title: replyThreadContext.parentChatTitle ?? chatInfo.title,
            ...(replyThreadContext.parentPeerUserId != null
              ? { peerUserId: replyThreadContext.parentPeerUserId }
              : {}),
          }
        : chatInfo
    const senderId = params.senderId != null ? String(params.senderId) : null
    const dmPolicy = account.config.dmPolicy ?? "pairing"
    const defaultGroupPolicy = cfg.channels?.defaults?.groupPolicy
    const groupPolicy = account.config.groupPolicy ?? defaultGroupPolicy ?? INLINE_DEFAULT_GROUP_POLICY

    if (isGroup) {
      if (groupPolicy === "disabled") {
        log?.info(
          `[${account.accountId}] inline: drop ${params.eventKind} chat=${String(params.chatId)} (groupPolicy=disabled)`,
        )
        return null
      }

      const groupSenderAllowlist = await resolveInlineGroupSenderAllowlist({
        cfg,
        account,
        groupId: String(effectiveChatId),
        senderId,
      })

      if (groupPolicy === "allowlist") {
        const shouldBypassGroupAccess = params.eventKind === "participant.add"
        const groupAccess = resolveInlineGroupAccessPolicy({
          cfg,
          accountId: account.accountId,
          groupId: String(effectiveChatId),
          hasGroupAllowFrom: groupSenderAllowlist.raw.length > 0,
          groupPolicy,
        })
        if (groupAccess.allowlistEnabled && !groupAccess.allowed && !shouldBypassGroupAccess) {
          log?.info(
            `[${account.accountId}] inline: drop ${params.eventKind} chat=${String(effectiveChatId)} (groupPolicy=allowlist)`,
          )
          return null
        }
        if (groupSenderAllowlist.raw.length > 0 && !shouldBypassGroupAccess) {
          if (senderId == null && !groupSenderAllowlist.raw.includes("*")) {
            log?.info(
              `[${account.accountId}] inline: drop ${params.eventKind} chat=${String(effectiveChatId)} (sender unknown)`,
            )
            return null
          }
          const allowed =
            senderId == null
              ? groupSenderAllowlist.expanded.includes("*")
              : allowlistMatch({ allowFrom: groupSenderAllowlist.expanded, senderId })
          if (!allowed) {
            log?.info(
              `[${account.accountId}] inline: drop ${params.eventKind} sender=${senderId ?? "unknown"} (groupPolicy=allowlist)`,
            )
            return null
          }
        }
      }

      const route = core.channel.routing.resolveAgentRoute({
        cfg,
        channel: CHANNEL_ID,
        accountId: account.accountId,
        peer: {
          kind: "group",
          id: String(effectiveChatId),
        },
      })
      const sessionKey = replyThreadContext
        ? await projectSavedInlineReplyThreadSessionKey({
            baseSessionKey: route.sessionKey,
            threadId: replyThreadContext.childChatId,
            agentId: route.agentId,
            eventKind: params.eventKind,
          })
        : route.sessionKey
      return {
        channelLabel: formatInlineSystemEventChannelLabel({
          chatInfo: effectiveChatInfo,
          effectiveChatId,
        }),
        sessionKey,
        agentId: route.agentId,
        effectiveChatId,
        isReplyThread: replyThreadContext != null,
        conversationKind,
        chatInfo,
      }
    }

    const peerUserId =
      senderId ??
      (replyThreadContext?.parentPeerUserId != null
        ? String(replyThreadContext.parentPeerUserId)
        : chatInfo.peerUserId != null ? String(chatInfo.peerUserId) : null)
    if (!peerUserId) {
      log?.info(
        `[${account.accountId}] inline: drop ${params.eventKind} chat=${String(params.chatId)} (direct peer unknown)`,
      )
      return null
    }
    if (dmPolicy === "disabled") {
      log?.info(`[${account.accountId}] inline: drop ${params.eventKind} sender=${peerUserId} (dmPolicy=disabled)`)
      return null
    }
    if (dmPolicy !== "open") {
      const configAllowFrom = await resolveInlineAllowlist({
        cfg,
        accountId: account.accountId,
        entries: account.config.allowFrom,
        senderId: peerUserId,
      })
      const storeAllowFrom = await core.channel.pairing
        .readAllowFromStore({
          channel: CHANNEL_ID,
          accountId: account.accountId,
        })
        .catch(() => [])
      const effectiveAllowFrom = [...configAllowFrom, ...normalizeAllowlist(storeAllowFrom)].filter(Boolean)
      if (!allowlistMatch({ allowFrom: effectiveAllowFrom, senderId: peerUserId })) {
        log?.info(`[${account.accountId}] inline: drop ${params.eventKind} sender=${peerUserId} (dmPolicy=${dmPolicy})`)
        return null
      }
    }

    const route = core.channel.routing.resolveAgentRoute({
      cfg,
      channel: CHANNEL_ID,
      accountId: account.accountId,
      peer: {
        kind: "direct",
        id: peerUserId,
      },
    })
    const sessionKey = replyThreadContext
      ? await projectSavedInlineReplyThreadSessionKey({
          baseSessionKey: route.sessionKey,
          threadId: replyThreadContext.childChatId,
          agentId: route.agentId,
          eventKind: params.eventKind,
        })
      : route.sessionKey
    return {
      channelLabel: formatInlineSystemEventChannelLabel({
        chatInfo: effectiveChatInfo,
        effectiveChatId,
      }),
      sessionKey,
      agentId: route.agentId,
      effectiveChatId,
      isReplyThread: replyThreadContext != null,
      conversationKind,
      chatInfo,
    }
  }

  const queueInlineMessageLifecycleSystemEvent = async (params: {
    action: "edited" | "deleted"
    chatId: bigint
    messageIds: bigint[]
    senderId?: bigint | null
  }): Promise<void> => {
    const messageIds = params.messageIds
    if (!messageIds.length) return

    const inboundAt = Date.now()
    publishStatus({
      lastInboundAt: inboundAt,
      lastEventAt: inboundAt,
      ...createTransportActivityStatusPatch(inboundAt),
    })

    const ingress = await resolveInlineSystemEventContext({
      chatId: params.chatId,
      senderId: params.senderId ?? null,
      eventKind: `message.${params.action}`,
    })
    if (!ingress) return

    core.system.enqueueSystemEvent(
      describeInlineMessageLifecycleSystemEvent({
        action: params.action,
        messageCount: messageIds.length,
        channelLabel: ingress.channelLabel,
      }),
      {
        sessionKey: ingress.sessionKey,
        contextKey: buildInlineMessageLifecycleContextKey({
          action: params.action,
          chatId: params.chatId,
          messageIds,
        }),
      },
    )
  }

  const queueInlineReactionSystemEvent = async (params: {
    action: "added" | "removed"
    chatId: bigint
    messageId: bigint
    senderId: bigint
    emoji: string
  }): Promise<void> => {
    const inboundAt = Date.now()
    publishStatus({
      lastInboundAt: inboundAt,
      lastEventAt: inboundAt,
      ...createTransportActivityStatusPatch(inboundAt),
    })

    const ingress = await resolveInlineSystemEventContext({
      chatId: params.chatId,
      senderId: params.senderId,
      eventKind: "reaction",
    })
    if (!ingress) return

    const senderId = String(params.senderId)
    const chatInfo = chatCache.get(params.chatId)
    const senderProfile = await senderProfilesById.resolve({ userId: senderId, chatId: params.chatId })
    const senderLabel = resolveInlineSenderLabel({
      senderId,
      senderName: chatInfo?.kind === "direct"
        ? resolveInlineDirectSenderName({ profileName: senderProfile?.name, chatTitle: chatInfo.title, senderId })
        : senderProfile?.name,
      senderUsername: senderProfile?.username,
    })

    const eventOptions = {
      sessionKey: ingress.sessionKey,
      contextKey: buildInlineReactionContextKey(params),
    }
    core.system.enqueueSystemEvent(
      describeInlineReactionSystemEvent({
        action: params.action,
        emoji: params.emoji,
        senderLabel,
        channelLabel: ingress.channelLabel,
        messageId: params.messageId,
      }),
      eventOptions,
    )
  }

  const recoverInlineJoinMentions = async (params: {
    chatId: bigint
    participant?: { userId?: bigint; date?: bigint }
    eventDate?: bigint
  }): Promise<Message[]> => {
    const participant = params.participant
    if (!participant || participant.userId !== meId) return []
    const participantDate = participant.date ?? params.eventDate
    if (participantDate == null || participantDate <= 0n) {
      log?.warn(`[${account.accountId}] inline: cannot recover join mentions without participant date`)
      return []
    }

    const inboundAt = Date.now()
    publishStatus({
      lastInboundAt: inboundAt,
      lastEventAt: inboundAt,
      ...createTransportActivityStatusPatch(inboundAt),
    })

    await hydrateChatParticipants(params.chatId)
    const recentMessages = await loadInlineJoinWindowMessages({
      client,
      chatId: params.chatId,
      participantDate,
    }).catch((err) => {
      publishStatus({ lastError: `getChatHistory (participant add) failed: ${String(err)}` })
      return null
    })
    const freshness = resolveInlineThreadFreshness({
      messages: recentMessages,
      botUserId: meId,
      botUsername,
      participantDate,
    })
    return freshness.priorMentionMessages
      .slice()
      .sort((a, b) => {
        const byDate = Number(a.date - b.date)
        if (byDate !== 0) return byDate
        if (a.id === b.id) return 0
        return a.id < b.id ? -1 : 1
      })
  }

  const shouldQueueInlineReactionSystemEvent = async (params: {
    chatId: bigint
    messageId: bigint
    senderId: bigint
  }): Promise<boolean> => {
    const mode = account.config.reactionNotifications ?? "own"
    if (mode === "off") return false
    if (mode === "all") return true
    if (mode === "allowlist") {
      const allowlist = await resolveInlineAllowlist({
        cfg,
        accountId: account.accountId,
        entries: account.config.reactionAllowlist,
        senderId: String(params.senderId),
      })
      return allowlistMatch({ allowFrom: allowlist, senderId: String(params.senderId) })
    }

    return isReactionTargetBotMessage({
      client,
      chatId: params.chatId,
      messageId: params.messageId,
      meId,
      botMessageIdsByChat,
    }).catch((err) => {
      publishStatus({ lastError: `getChatHistory (reaction target) failed: ${String(err)}` })
      return false
    })
  }

  const handleInboundNow = async (input: InlineParsedInboundEvent): Promise<void> => {
    if (abortSignal.aborted) return
    refreshLiveConfig()
    const chatId = input.chatId
    const msg = input.msg
    const rawBodyOverride = input.rawBodyOverride ?? null
    const callbackActionEvent = input.callbackActionEvent ?? null
    let rawBody = ""
    let currentContent: ReturnType<typeof summarizeInlineMessageContent> | null = null
    let currentAttachmentText: string | null = null
    let currentEntityText: string | null = null
    let commandTarget = { body: "", targeted: false, addressedToMe: false }
    let commandAddressedToMe = false

    if (!callbackActionEvent) {
      if (rawBodyOverride != null) {
        rawBody = rawBodyOverride.trim()
      } else {
        currentContent = summarizeInlineMessageContent(msg)
        rawBody = buildInlineInboundBodyText(currentContent)
        currentAttachmentText = currentContent.attachmentText || null
        currentEntityText = currentContent.entityText || null
      }
      if (!rawBody && !currentContent?.media && !currentContent?.attachments.length) return
      commandTarget = resolveInlineCommandTarget(rawBody, botUsername)
      const structuredCommandTarget = leadingInlineBotCommandTargetUserId(msg)
      if (
        (commandTarget.targeted && !commandTarget.addressedToMe) ||
        (structuredCommandTarget != null && structuredCommandTarget !== String(meId))
      ) {
        runtime.log?.(`inline: drop command targeted at another bot chat=${String(chatId)}`)
        return
      }
      // A command picked for this bot addresses it directly, like a mention.
      commandAddressedToMe = commandTarget.addressedToMe || structuredCommandTarget === String(meId)
    }

    const inboundAt = Date.now()
    publishStatus({
      lastInboundAt: inboundAt,
      lastEventAt: inboundAt,
      ...createTransportActivityStatusPatch(inboundAt),
    })

    // Follow state is mutable and decides who wakes: the server follows a bot
    // for a thread it opened with no event here, so a group's snapshot is only
    // good for one message. Direct chats have no follow state.
    const previousChatInfo = chatCache.get(chatId)
    if (
      takeInlineFollowModeChanged({ accountId: account.accountId, chatId }) ||
      previousChatInfo?.kind === "group"
    ) {
      chatCache.delete(chatId)
    }
    let chatInfo: CachedChatInfo
    try {
      chatInfo = await resolveChatInfo(client, chatCache, chatId)
    } catch (err) {
      publishStatus({ lastError: `getChat failed: ${String(err)}` })
      if (!previousChatInfo) {
        runtime.log?.(`inline: drop message chat=${String(chatId)} (chat metadata unavailable)`)
        return
      }
      chatInfo = previousChatInfo
    }

    const inlineThreadDefaults = (cfg.channels?.inline ?? {}) as {
      replyThreadRequireExplicitMention?: boolean
      replyThreadParentHistoryLimit?: number
    }
    const replyThreadsEnabled = isInlineReplyThreadsEnabled({ cfg, accountId: account.accountId })
    let replyThreadContextFailed = false
    const replyThreadContext = await resolveInlineInboundReplyThreadContext({
      replyThreadsEnabled,
      client,
      chatId,
      chatInfo,
      chatCache,
      useCachedChatMetadata: true,
    }).catch((err) => {
      publishStatus({ lastError: `getChat (reply thread) failed: ${String(err)}` })
      replyThreadContextFailed = true
      return null
    })
    if (replyThreadContextFailed && chatInfo.parentChatId != null) {
      runtime.log?.(
        `inline: drop child message chat=${String(chatId)} (reply-thread parent unavailable)`,
      )
      return
    }
    // Inline encodes every reply-thread child as a chat peer. Preserve the
    // logical parent kind so a DM child remains a DM for policy and sessions.
    const senderId = String(msg.fromId)
    // A thread under the bot's DM stays that DM for its person. Anyone else added
    // to it keeps group rules and their own session, away from the DM's context.
    const isGuestInDmThread =
      replyThreadContext?.parentChatKind === "direct" &&
      replyThreadContext.parentPeerUserId != null &&
      String(replyThreadContext.parentPeerUserId) !== senderId
    const conversationKind = isGuestInDmThread
      ? "group"
      : replyThreadContext?.parentChatKind ?? chatInfo.kind
    const isGroup = conversationKind !== "direct"
    const effectiveChatId = replyThreadContext?.parentChatId ?? chatId
    const effectiveGroupTitle = replyThreadContext?.parentChatTitle ?? chatInfo.title ?? null
    const replyThreadMode =
      replyThreadsEnabled
        ? resolveInlineGroupReplyThreadMode({
            cfg,
            accountId: account.accountId,
            groupId: String(effectiveChatId),
          })
        : "auto"
    const replyThreadRequireExplicitMention =
      isGroup && replyThreadsEnabled
        ? resolveInlineGroupReplyThreadRequireExplicitMention({
            cfg,
            accountId: account.accountId,
            groupId: String(effectiveChatId),
            defaultRequireExplicitMention:
              account.config.replyThreadRequireExplicitMention ??
              inlineThreadDefaults.replyThreadRequireExplicitMention ??
              false,
          })
        : false
    const replyThreadParentHistoryLimit =
      replyThreadsEnabled
        ? resolveInlineGroupReplyThreadParentHistoryLimit({
            cfg,
            accountId: account.accountId,
            groupId: String(effectiveChatId),
            defaultLimit:
              account.config.replyThreadParentHistoryLimit ??
              inlineThreadDefaults.replyThreadParentHistoryLimit ??
              DEFAULT_REPLY_THREAD_PARENT_HISTORY_LIMIT,
          })
        : DEFAULT_REPLY_THREAD_PARENT_HISTORY_LIMIT
    const senderResolution = await senderProfilesById.resolveWithProvenance({ userId: senderId, chatId })
    const senderProfile = senderResolution.profile
    const explicitlyMentionsThisBot = collectInlineMentionedUserIds(currentContent)
      .includes(String(meId))
    if (!senderResolution.provenanceVerified && !explicitlyMentionsThisBot) {
      runtime.log?.(`inline: observe sender with unverified bot provenance chat=${String(chatId)} sender=${senderId}`)
      return
    }
    // Another bot wakes this one by mention, addressed command, or a reply to its
    // message; the reply is checked against history below.
    const senderIsBot = senderProfile?.bot === true
    const botAddressedThisBot = senderIsBot && (explicitlyMentionsThisBot || commandAddressedToMe)
    if (senderIsBot && !botAddressedThisBot && msg.replyToMsgId == null) {
      runtime.log?.(`inline: observe ambient bot message chat=${String(chatId)} sender=${senderId}`)
      return
    }
    const senderUsername = senderProfile?.username
    const senderName = isGroup
      ? senderProfile?.name
      : resolveInlineDirectSenderName({ profileName: senderProfile?.name, chatTitle: effectiveGroupTitle, senderId })
    const callbackActionOwnership = callbackActionEvent
      ? resolveInlineMessageActionOwnership(callbackActionEvent.actionId)
      : null
    if (callbackActionEvent) {
      const actor =
        senderUsername != null && senderUsername.length > 0
          ? `@${senderUsername}`
          : senderName ?? "the sender"
      rawBody = buildInlineAgentActionBody({
        actor,
        targetMessageId: callbackActionEvent.targetMessageId,
      })
    }

    const dmPolicy = account.config.dmPolicy ?? "pairing"
    const defaultGroupPolicy = cfg.channels?.defaults?.groupPolicy
    const groupPolicy = account.config.groupPolicy ?? defaultGroupPolicy ?? INLINE_DEFAULT_GROUP_POLICY

    const configAllowFrom = await resolveInlineAllowlist({
      cfg,
      accountId: account.accountId,
      entries: account.config.allowFrom,
      senderId,
    })
    const groupSenderAllowlist = isGroup
      ? await resolveInlineGroupSenderAllowlist({
          cfg,
          account,
          groupId: String(effectiveChatId),
          senderId,
        })
      : { raw: [], expanded: [] }
    const storeAllowFrom = await core.channel.pairing
      .readAllowFromStore({
        channel: CHANNEL_ID,
        accountId: account.accountId,
      })
      .catch(() => [])
    const storeAllowList = normalizeAllowlist(storeAllowFrom)

    const effectiveAllowFrom = [...configAllowFrom, ...storeAllowList].filter(Boolean)
    const effectiveGroupAllowFrom = groupSenderAllowlist.expanded.filter(Boolean)
    const effectiveGroupCommandAllowFrom = effectiveGroupAllowFrom
    const shouldRouteCallbackThroughSystemHandlers =
      callbackActionEvent != null &&
      (callbackActionOwnership?.owner === "system" || callbackActionOwnership?.explicit === false)
    const callbackCommandBody = callbackActionEvent && shouldRouteCallbackThroughSystemHandlers
      ? resolveCallbackCommandBodyFromActionData({
          data: callbackActionEvent.data,
          ...(botUsername ? { botUsername } : {}),
        })
      : undefined
    const callbackResponseUi = callbackActionEvent
      ? resolveInlineCallbackResponseUi(callbackActionEvent.data)
      : undefined
    let callbackActionAnswered = false
    const answerCallbackIfNeeded = async () => {
      if (!callbackActionEvent || callbackActionAnswered) return
      await answerInlineMessageAction(client, callbackActionEvent.interactionId, callbackResponseUi)
      callbackActionAnswered = true
    }
    if (callbackActionEvent) {
      await answerCallbackIfNeeded().catch((error) => {
        runtime.error?.(`inline callback answer failed: ${String(error)}`)
      })
    }
    const shouldEditCallbackTargetInPlace = callbackActionEvent != null
    const normalizedCommandBody = callbackCommandBody ?? commandTarget.body
    const mentionedInlineAgentId = currentContent?.entities.find((entity) =>
      entity.type === "mention" && entity.userId === String(meId) && entity.agentId)?.agentId
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
    const savedReplyThreadRoute = replyThreadContext
      ? await lookupInlineReplyThreadRouteByThreadId({
          accountId: account.accountId,
          threadId: replyThreadContext.childChatId,
        }).catch((error) => {
          runtime.error?.(`inline reply-thread specialization lookup failed: ${String(error)}`)
          return null
        })
      : null
    // A specialized Inline Agent remains attached to its reply-thread child.
    // Follow-up messages should not need to mention the Agent again, but a
    // child route owned by another OpenClaw agent must not leak specialization.
    const inlineAgentId = mentionedInlineAgentId ?? (
      savedReplyThreadRoute?.agentId === route.agentId
        ? savedReplyThreadRoute.inlineAgentId
        : undefined
    )
    let inlineAgent: Awaited<ReturnType<typeof inlineAgentResolver.resolve>> = null
    if (inlineAgentId) {
      try {
        inlineAgent = await inlineAgentResolver.resolve(inlineAgentId)
      } catch (error) {
        runtime.error?.(`inline: failed to resolve mentioned Agent ${inlineAgentId}: ${String(error)}`)
      }
    }
    const baseInboundSessionKey = replyThreadContext
      ? buildInlineReplyThreadSessionKey(route.sessionKey, replyThreadContext.childChatId)
      : route.sessionKey
    const inboundSessionKey = projectInlineAgentSessionKey(
      baseInboundSessionKey,
      inlineAgentId,
      inlineAgent,
    )
    if (replyThreadContext) {
      rememberInlineReplyThreadRoute({
        accountId: account.accountId,
        parentChatId: replyThreadContext.parentChatId,
        threadId: replyThreadContext.childChatId,
        parentMessageId: replyThreadContext.parentMessageId,
        threadLabel: replyThreadContext.threadLabel,
        agentId: route.agentId,
        ...(inlineAgentId ? { inlineAgentId } : {}),
      })
    }
    const rememberSentBotMessage = (params: {
      chatId: bigint
      messageId: bigint | null | undefined
      replyThreadContext?: InlineReplyThreadContext | null
    }): void => {
      if (params.messageId == null) return
      rememberInlineBotDelivery({
        botMessageIdsByChat,
        chatId: params.chatId,
        messageId: params.messageId,
        accountId: account.accountId,
        agentId: route.agentId,
        ...(inlineAgentId ? { inlineAgentId } : {}),
        replyThreadContext: params.replyThreadContext ?? null,
      })
    }
    const hasTextControlCommand = core.channel.text.hasControlCommand(
      callbackCommandBody ?? rawBody,
      cfg,
      botUsername ? { botUsername } : undefined,
    )
    const isRegisteredNativeCommand = await isInlineNativeCommandBody({
      cfg,
      account,
      commandBody: normalizedCommandBody,
      agentId: route.agentId,
    })
    const inlineFollowCommand = parseInlineFollowCommandBody(normalizedCommandBody)
    const hasControlCommand =
      hasTextControlCommand || isRegisteredNativeCommand || inlineFollowCommand != null
    // Several bots offer this command and nothing says which one was meant; running
    // it here could reset or steer the wrong conversation.
    if (
      isGroup &&
      callbackActionEvent == null &&
      !commandAddressedToMe &&
      isRegisteredNativeCommand &&
      startsWithUnclaimedInlineBotCommand(msg)
    ) {
      runtime.log?.(`inline: drop command no bot claimed chat=${String(chatId)}`)
      return
    }
    const commandSource = hasControlCommand
      ? isRegisteredNativeCommand
        ? "native"
        : "text"
      : undefined
    const normalizedCommandName = resolveInlineCommandNameFromBody(normalizedCommandBody)
    const hostInlinePluginCommandRegistered = normalizedCommandName
      ? hasInlineCommandSpec(listHostInlinePluginCommandSpecs(cfg), normalizedCommandName)
      : false
    const allowTextCommands = core.channel.commands.shouldHandleTextCommands({
      cfg,
      surface: CHANNEL_ID,
      ...(commandSource ? { commandSource } : {}),
    })
    const useAccessGroups = resolveUseAccessGroups(cfg)
    const allowForCommands = isGroup ? effectiveGroupCommandAllowFrom : effectiveAllowFrom
    const senderAllowedForCommands = allowlistMatch({ allowFrom: allowForCommands, senderId })
    const commandGate = resolveControlCommandGate({
      useAccessGroups,
      authorizers: [{ configured: allowForCommands.length > 0, allowed: senderAllowedForCommands }],
      allowTextCommands,
      hasControlCommand,
    })
    const commandAuthorized = await resolveInlineCommandAuthorized({
      cfg,
      accountId: account.accountId,
      isGroup,
      chatId: String(effectiveChatId),
      senderId,
      commandAuthorized: commandGate.commandAuthorized,
    })
    const shouldBlockControlCommand = allowTextCommands && hasControlCommand && !commandAuthorized
    const nativeMentioned = typeof msg.mentioned === "boolean" ? msg.mentioned : false

    if (isGroup) {
      if (groupPolicy === "disabled") {
        log?.info(
          `[${account.accountId}] inline: drop group chat=${String(chatId)} (groupPolicy=disabled)`,
        )
        await answerCallbackIfNeeded().catch((error) => {
          runtime.error?.(`inline callback answer failed: ${String(error)}`)
        })
        return
      }
      if (groupPolicy === "allowlist") {
        const groupAccess = resolveInlineGroupAccessPolicy({
          cfg,
          accountId: account.accountId,
          groupId: String(effectiveChatId),
          hasGroupAllowFrom: groupSenderAllowlist.raw.length > 0,
          groupPolicy,
        })
        if (groupAccess.allowlistEnabled && !groupAccess.allowed) {
          log?.info(`[${account.accountId}] inline: drop group chat=${String(effectiveChatId)} (groupPolicy=allowlist)`)
          await answerCallbackIfNeeded().catch((error) => {
            runtime.error?.(`inline callback answer failed: ${String(error)}`)
          })
          return
        }
        const allowed = allowlistMatch({ allowFrom: effectiveGroupAllowFrom, senderId })
        if (effectiveGroupAllowFrom.length > 0 && !allowed) {
          log?.info(`[${account.accountId}] inline: drop group sender=${senderId} (groupPolicy=allowlist)`)
          await answerCallbackIfNeeded().catch((error) => {
            runtime.error?.(`inline callback answer failed: ${String(error)}`)
          })
          return
        }
      }
    } else {
      if (dmPolicy === "disabled") {
        log?.info(`[${account.accountId}] inline: drop DM sender=${senderId} (dmPolicy=disabled)`)
        await answerCallbackIfNeeded().catch((error) => {
          runtime.error?.(`inline callback answer failed: ${String(error)}`)
        })
        return
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
                await sendMessage({
                  chatId,
                  text: core.channel.pairing.buildPairingReply({
                    channel: CHANNEL_ID,
                    idLine: `Your Inline user id: ${senderId}`,
                    code,
                  }),
                  parseMarkdown: account.config.parseMarkdown ?? true,
                })
                publishStatus({ lastOutboundAt: Date.now() })
              } catch (err) {
                runtime.error?.(`inline: pairing reply failed for ${senderId}: ${String(err)}`)
              }
            }
          }
          log?.info(`[${account.accountId}] inline: drop DM sender=${senderId} (dmPolicy=${dmPolicy})`)
          await answerCallbackIfNeeded().catch((error) => {
            runtime.error?.(`inline callback answer failed: ${String(error)}`)
          })
          return
        }
      }
    }

    const shouldEnforceFollowCommandDmAuthorization =
      inlineFollowCommand != null &&
      !isGroup &&
      (hasExplicitInlineCommandAuthorizationPolicy(cfg) ||
        (effectiveAllowFrom.length > 0 && !effectiveAllowFrom.includes("*")))
    if ((isGroup || shouldEnforceFollowCommandDmAuthorization) && shouldBlockControlCommand) {
      logInboundDrop({
        log: (m) => runtime.log?.(m),
        channel: CHANNEL_ID,
        reason: "control command (unauthorized)",
        target: senderId,
      })
      await answerCallbackIfNeeded().catch((error) => {
        runtime.error?.(`inline callback answer failed: ${String(error)}`)
      })
      return
    }

    // The run of mentions a group message starts with names who it is for. If
    // that run names someone else, a later mention of this bot does not count.
    const leadingMentionUserIds = isGroup && callbackActionEvent == null
      ? leadingInlineMentionUserIds({ content: currentContent, messageText: msg.message })
      : []
    const addressedElsewhere =
      leadingMentionUserIds.length > 0 && !leadingMentionUserIds.includes(String(meId))
    const explicitlyMentioned = nativeMentioned && !addressedElsewhere
    const wasMentioned = explicitlyMentioned || commandAddressedToMe
    const messageTimestamp = Number(msg.date) * 1000
    const pendingReplyThreadContext = replyThreadContext
    const pendingGroupHistoryKey = isGroup
      ? pendingReplyThreadContext
        ? inboundSessionKey
        : route.sessionKey
      : null
    const senderLabel = resolveInlineSenderLabel({
      senderId,
      senderName,
      senderUsername,
    })
    const pendingHistorySender = senderLabel
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
      publishStatus({ lastError: `getChatHistory failed: ${String(err)}` })
      return {
        historyText: null,
        attachmentText: null,
        entityText: null,
        inboundHistory: [],
        repliedToBot: false,
        replyToSenderId: null,
      }
    })
    let effectiveHistoryContext =
      replyThreadContext?.anchorMessage != null
        ? prependInlineReplyThreadAnchor({
            historyContext,
            anchorMessage: replyThreadContext.anchorMessage,
            parentChatId: replyThreadContext.parentChatId,
            senderProfilesById,
            meId,
          })
        : historyContext
    if (senderIsBot && !botAddressedThisBot && !effectiveHistoryContext.repliedToBot) {
      runtime.log?.(`inline: observe bot reply to someone else chat=${String(chatId)} sender=${senderId}`)
      return
    }
    const explicitlyUnfollowed = isInlineDialogExplicitlyUnfollowed(chatInfo.dialogFollowMode)
    const followModeImplicitMention =
      isGroup &&
      !replyThreadRequireExplicitMention &&
      // Freshness controls server-side auto-follow only. Once a dialog is
      // FOLLOWING, its unmentioned activity remains relevant until unfollowed.
      isInlineDialogFollowing(chatInfo.dialogFollowMode)
    const configuredRequireMention = isGroup
      ? resolveInlineGroupRequireMention({
          cfg,
          groupId: String(effectiveChatId),
          accountId: account.accountId,
          requireMentionDefault: account.config.requireMention ?? INLINE_DEFAULT_REQUIRE_MENTION,
        })
      : false
    // An explicit unfollow beats free response: only mentions and replies to
    // this bot reach it, as they would in a mention-only room.
    const unfollowedFreeResponse = isGroup && explicitlyUnfollowed && !configuredRequireMention
    const replyToBotImplicitMention =
      isGroup &&
      ((account.config.replyToBotWithoutMention ?? true) || unfollowedFreeResponse) &&
      msg.replyToMsgId != null &&
      effectiveHistoryContext.repliedToBot
    const inferredThreadAttention = followModeImplicitMention || replyToBotImplicitMention
    // A reply is addressed to its author. Replies to other people or bots stay
    // theirs unless they mention this bot; replying to yourself is not one.
    const repliedToSomeoneElse =
      isGroup &&
      callbackActionEvent == null &&
      msg.replyToMsgId != null &&
      !effectiveHistoryContext.repliedToBot &&
      effectiveHistoryContext.replyToSenderId != null &&
      effectiveHistoryContext.replyToSenderId !== String(meId) &&
      effectiveHistoryContext.replyToSenderId !== senderId
    const addressedToOthers = addressedElsewhere || (repliedToSomeoneElse && !wasMentioned)
    // Messages addressed to someone else never start a turn here, whether the
    // room is followed, free-response, or a thread this bot replied in.
    const implicitMention =
      (callbackActionEvent != null && isGroup) ||
      (!addressedToOthers && inferredThreadAttention)

    const requireMention = configuredRequireMention || unfollowedFreeResponse || addressedToOthers
    const mentionGate = resolveMentionGatingWithBypass({
      isGroup,
      requireMention,
      canDetectMention: typeof msg.mentioned === "boolean",
      wasMentioned,
      implicitMention,
      // A bare command addressed to someone else (a reply to them) is theirs too.
      hasAnyMention: addressedToOthers,
      allowTextCommands,
      hasControlCommand,
      commandAuthorized,
    })
    const implicitMentionKinds =
      isGroup && implicitMention
        ? [
            ...(callbackActionEvent != null ? ["message_action"] : []),
            ...(followModeImplicitMention ? ["follow_mode"] : []),
            ...(replyToBotImplicitMention ? ["reply_to_bot"] : []),
          ]
        : []
    const mentionedUserIds = isGroup ? collectInlineMentionedUserIds(currentContent) : []
    const mentionSource = isGroup
      ? resolveInlineMentionSource({
          nativeMentioned: wasMentioned,
          implicitMention,
          shouldBypassMention: mentionGate.shouldBypassMention,
        })
      : "none"
    if (isGroup && mentionGate.shouldSkip) {
      runtime.log?.(`inline: drop group chat ${String(chatId)} (no mention)`)
      const pendingBody =
        normalizeHistoryText(currentContent?.text) ??
        normalizeHistoryText(rawBody)
      recordPendingHistoryEntryIfEnabled({
        historyMap: groupPendingHistories,
        historyKey: pendingGroupHistoryKey ?? "",
        limit: historyLimit,
        entry:
          pendingGroupHistoryKey && pendingBody
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
      return
    }

    const parseMarkdown = account.config.parseMarkdown ?? true
    if (inlineFollowCommand) {
      const { command, args } = inlineFollowCommand
      let responseText: string
      if (args) {
        responseText = inlineFollowCommandUsageText(command)
      } else {
        const target = isGroup
          ? { chatId }
          : { userId: BigInt(senderId) }
        try {
          await updateInlineFollowMode({ client, target, command })
          const { protocolMode } = inlineFollowModeForCommand(command)
          chatCache.set(chatId, {
            ...chatInfo,
            dialogFollowMode: protocolMode,
          })
          responseText = inlineFollowCommandSuccessText(command)
        } catch (error) {
          log?.warn(
            `[${account.accountId}] inline /${command} failed for chat=${String(chatId)}: ${summarizeInlineFollowCommandError(error)}`,
          )
          responseText = inlineFollowCommandFailureText(command)
        }
      }

      const sent = await sendMessage({
        chatId,
        text: responseText,
        replyToMsgId: msg.id,
        parseMarkdown,
      })
      rememberSentBotMessage({
        chatId,
        messageId: sent.messageId,
        replyThreadContext,
      })
      publishStatus({ lastOutboundAt: Date.now() })
      await answerCallbackIfNeeded().catch((error) => {
        runtime.error?.(`inline callback answer failed: ${String(error)}`)
      })
      return
    }
    if (
      isInlineThreadReplyCommandBody(normalizedCommandBody) &&
      !hostInlinePluginCommandRegistered
    ) {
      const configRuntime = (core as {
        config?: {
          current?: unknown
          mutateConfigFile?: unknown
        }
      }).config
      if (
        typeof configRuntime?.current !== "function" ||
        typeof configRuntime.mutateConfigFile !== "function"
      ) {
        runtime.error?.("inline /threads fallback unavailable: runtime config API missing")
      } else {
        const result = await handleInlineThreadReplyCommandWithConfigRuntime(
          configRuntime as Parameters<typeof handleInlineThreadReplyCommandWithConfigRuntime>[0],
          {
            senderId,
            channel: CHANNEL_ID,
            channelId: CHANNEL_ID,
            isAuthorizedSender: commandAuthorized,
            senderIsOwner: commandAuthorized,
            sessionKey: inboundSessionKey,
            args: parseInlineCommandArgs(normalizedCommandBody),
            commandBody: normalizedCommandBody,
            config: cfg,
            from: isGroup ? `inline:chat:${String(effectiveChatId)}` : `inline:${senderId}`,
            to: `inline:${String(effectiveChatId)}`,
            accountId: account.accountId,
            ...(replyThreadContext
              ? {
                  messageThreadId: String(replyThreadContext.childChatId),
                  threadParentId: String(replyThreadContext.parentChatId),
                }
              : {}),
            requestConversationBinding: async () => ({ ok: false }) as never,
            detachConversationBinding: async () => ({ removed: false }),
            getCurrentConversationBinding: async () => null,
          } satisfies PluginCommandContext,
        )
        cfg = configRuntime.current() as OpenClawConfig
        const resultRecord = result as Record<string, unknown>
        const actions = resolveInlineReplyActions(resultRecord, { owner: "system" })
        const text =
          typeof result.text === "string"
            ? sanitizeInlineDeliveryText(result.text)
            : ""

        if (text || actions) {
          let delivered = false
          if (shouldEditCallbackTargetInPlace && callbackActionEvent) {
            try {
              const editResult = await client.invokeRaw(Method.EDIT_MESSAGE, {
                oneofKind: "editMessage",
                editMessage: {
                  messageId: callbackActionEvent.targetMessageId,
                  peerId: buildChatPeer(chatId),
                  text,
                  ...(actions ? { actions } : {}),
                  parseMarkdown,
                },
              })
              if (editResult.oneofKind !== "editMessage") {
                throw new Error(
                  `inline /threads edit: expected editMessage result, got ${String(editResult.oneofKind)}`,
                )
              }
              delivered = true
            } catch (error) {
              runtime.error?.(`inline /threads edit failed; falling back to send (${String(error)})`)
            }
          }
          if (!delivered) {
            const sent = await sendMessage({
              chatId,
              text,
              ...(actions ? { actions } : {}),
              parseMarkdown,
            })
            rememberSentBotMessage({ chatId, messageId: sent.messageId, replyThreadContext })
          }
          publishStatus({ lastOutboundAt: Date.now() })
        }

        await answerCallbackIfNeeded().catch((error) => {
          runtime.error?.(`inline callback answer failed: ${String(error)}`)
        })
        return
      }
    }
    const commandsPageCallback = callbackActionEvent && shouldRouteCallbackThroughSystemHandlers
      ? parseInlineCommandsPageCallback(callbackDataToUtf8(callbackActionEvent.data))
      : null
    if (shouldEditCallbackTargetInPlace && callbackActionEvent && commandsPageCallback) {
      if (commandsPageCallback.page === "noop") return

      const agentId = commandsPageCallback.agentId ?? route.agentId
      const paginated = buildCommandsMessagePaginated(
        cfg,
        await prepareSkillCommandsForAgents({
          cfg,
          agentIds: [agentId],
        }),
        {
          page: commandsPageCallback.page,
          forcePaginatedList: true,
          surface: CHANNEL_ID,
        },
      )
      const actions = resolveInlineReplyActions({
        channelData: buildInlineCommandsListChannelData({
          currentPage: paginated.currentPage,
          totalPages: paginated.totalPages,
          agentId,
        }) ?? { inline: { buttons: [] } },
      }, { owner: "system" }) ?? { rows: [] }
      const text = sanitizeInlineDeliveryText(paginated.text)

      try {
        const result = await client.invokeRaw(Method.EDIT_MESSAGE, {
          oneofKind: "editMessage",
          editMessage: {
            messageId: callbackActionEvent.targetMessageId,
            peerId: buildChatPeer(chatId),
            text,
            actions,
            parseMarkdown,
          },
        })
        if (result.oneofKind !== "editMessage") {
          throw new Error(
            `inline commands pagination: expected editMessage result, got ${String(result.oneofKind)}`,
          )
        }
      } catch (error) {
        runtime.error?.(`inline commands pagination edit failed; falling back to send (${String(error)})`)
        const sent = await sendMessage({
          chatId,
          text,
          actions,
          parseMarkdown,
        })
        rememberSentBotMessage({ chatId, messageId: sent.messageId, replyThreadContext })
      }
      publishStatus({ lastOutboundAt: Date.now() })
      return
    }

    const nativeCommandMenu = await resolveInlineNativeCommandMenu({
      commandBody: normalizedCommandBody,
      cfg,
      agentId: route.agentId,
      sessionKey: inboundSessionKey,
    })
    if (nativeCommandMenu) {
      const menuActions = resolveInlineReplyActions({
        channelData: {
          inline: {
            buttons: nativeCommandMenu.buttons,
          },
        },
      }, { owner: "system" })
      const menuText = sanitizeInlineDeliveryText(nativeCommandMenu.title)
      let deliveredNativeMenu = false
      if (shouldEditCallbackTargetInPlace && callbackActionEvent) {
        try {
          const result = await client.invokeRaw(Method.EDIT_MESSAGE, {
            oneofKind: "editMessage",
            editMessage: {
              messageId: callbackActionEvent.targetMessageId,
              peerId: buildChatPeer(chatId),
              text: menuText,
              ...(menuActions ? { actions: menuActions } : {}),
              parseMarkdown,
            },
          })
          if (result.oneofKind !== "editMessage") {
            throw new Error(
              `inline command menu: expected editMessage result, got ${String(result.oneofKind)}`,
            )
          }
          deliveredNativeMenu = true
        } catch (error) {
          runtime.error?.(`inline command menu edit failed; falling back to send (${String(error)})`)
        }
      }
      if (!deliveredNativeMenu) {
        const sent = await sendMessage({
          chatId,
          text: menuText,
          ...(menuActions ? { actions: menuActions } : {}),
          parseMarkdown,
        })
        rememberSentBotMessage({ chatId, messageId: sent.messageId, replyThreadContext })
      }
      publishStatus({ lastOutboundAt: Date.now() })
      await answerCallbackIfNeeded().catch((error) => {
        runtime.error?.(`inline callback answer failed: ${String(error)}`)
      })
      return
    }

    const modelPickerCallbackData = callbackActionEvent && shouldRouteCallbackThroughSystemHandlers
      ? callbackDataToUtf8(callbackActionEvent.data)
      : undefined
    const modelPickerCallback = modelPickerCallbackData
      ? parseInlineModelPickerCallback(modelPickerCallbackData)
      : null
    if (shouldEditCallbackTargetInPlace && callbackActionEvent && modelPickerCallback?.type === "select") {
      const deliverModelPickerEdit = async (
        text: string,
        buttons: InlineReplyMarkupButton[][],
      ): Promise<void> => {
        const outboundText = sanitizeInlineDeliveryText(text)
        const actions = resolveInlineReplyActions({
          channelData: {
            inline: {
              buttons,
            },
          },
        }, { owner: "system" }) ?? { rows: [] }
        try {
          const result = await client.invokeRaw(Method.EDIT_MESSAGE, {
            oneofKind: "editMessage",
            editMessage: {
              messageId: callbackActionEvent.targetMessageId,
              peerId: buildChatPeer(chatId),
              text: outboundText,
              actions,
              parseMarkdown,
            },
          })
          if (result.oneofKind !== "editMessage") {
            throw new Error(
              `inline model picker edit: expected editMessage result, got ${String(result.oneofKind)}`,
            )
          }
        } catch (error) {
          runtime.error?.(`inline model picker edit failed; falling back to send (${String(error)})`)
          const sent = await sendMessage({
            chatId,
            text: outboundText,
            actions,
            parseMarkdown,
          })
          rememberSentBotMessage({ chatId, messageId: sent.messageId, replyThreadContext })
        }
      }

      const { byProvider, providers } = await buildModelsProviderData(cfg, route.agentId)
      const providerButtons = buildInlineModelProviderButtons(
        providers.map((provider) => ({
          id: provider,
          count: byProvider.get(provider)?.size ?? 0,
        })),
      )
      const selection = resolveInlineModelPickerSelection({
        callback: modelPickerCallback,
        providers,
        byProvider,
      })

      if (selection.kind !== "resolved") {
        await deliverModelPickerEdit(
          `Could not resolve model "${selection.model}".\n\nSelect a provider:`,
          providerButtons,
        )
      } else {
        const modelSet = byProvider.get(selection.provider)
        if (!modelSet?.has(selection.model)) {
          await deliverModelPickerEdit(`❌ Model "${selection.provider}/${selection.model}" is not allowed.`, [])
        } else {
          try {
            const resolvedDefault = resolveDefaultModelForAgent({
              cfg,
              agentId: route.agentId,
            })
            const isDefaultSelection =
              selection.provider === resolvedDefault.provider && selection.model === resolvedDefault.model
            await setOpenClawSessionModel({
              ingress: {
                channelLabel: effectiveGroupTitle ?? chatInfo.title ?? String(effectiveChatId),
                sessionKey: inboundSessionKey,
                agentId: route.agentId,
                effectiveChatId,
                isReplyThread: replyThreadContext != null,
                conversationKind,
                chatInfo,
              },
              actorUserId: msg.fromId,
              chatId,
              requestId: callbackActionEvent.interactionId,
              selection: `${selection.provider}/${selection.model}`,
            })

            const actionText = isDefaultSelection
              ? "reset to default"
              : `changed to **${selection.provider}/${selection.model}**`
            await deliverModelPickerEdit(
              `✅ Model ${actionText}\n\nThis model will be used for your next message.`,
              [],
            )
          } catch (error) {
            await deliverModelPickerEdit(`❌ Failed to change model: ${String(error)}`, [])
          }
        }
      }

      publishStatus({ lastOutboundAt: Date.now() })
      await answerCallbackIfNeeded().catch((error) => {
        runtime.error?.(`inline callback answer failed: ${String(error)}`)
      })
      return
    }

    if (
      callbackActionEvent &&
      callbackActionOwnership?.owner === "system" &&
      callbackActionOwnership.explicit &&
      callbackCommandBody == null
    ) {
      runtime.log?.(
        `inline: drop unhandled system action ${callbackActionEvent.actionId} ` +
        `message=${String(callbackActionEvent.targetMessageId)}`,
      )
      return
    }

    let deliveryReplyThreadContext = replyThreadContext
    // A bot's message is answered in place even in a chat set to On: it wakes
    // on replies in the chat it asked from, and a thread would never reach it.
    const shouldCreateDeliveryThread =
      replyThreadsEnabled &&
      !deliveryReplyThreadContext &&
      replyThreadMode === "on" &&
      senderProfile?.bot !== true &&
      !shouldEditCallbackTargetInPlace
    let parentThreadCreationTyping = false
    const setParentThreadCreationTyping = async (typing: boolean): Promise<void> => {
      if (!shouldCreateDeliveryThread || parentThreadCreationTyping === typing) return
      parentThreadCreationTyping = typing
      await sendInlineTypingAndBotPresenceToChats({
        client,
        chatIds: [effectiveChatId],
        typing,
        presenceKind: typing ? "running" : "idle",
        onTypingPartialError: (chatId, error) =>
          runtime.error?.(`inline parent reply-thread typing failed for chat ${String(chatId)}: ${String(error)}`),
        onPresencePartialError: (chatId, error) =>
          runtime.error?.(`inline parent reply-thread bot presence failed for chat ${String(chatId)}: ${String(error)}`),
        onPresenceError: (error) =>
          runtime.error?.(`inline parent reply-thread bot presence failed: ${String(error)}`),
      }).catch((error) => runtime.error?.(`inline parent reply-thread typing failed: ${String(error)}`))
    }

    if (shouldCreateDeliveryThread) {
      await setParentThreadCreationTyping(true)
      const cachedRoute = await lookupInlineReplyThreadRoute({
        accountId: account.accountId,
        parentChatId: effectiveChatId,
        parentMessageId: msg.id,
        agentId: route.agentId,
      }).catch((error) => {
        publishStatus({ lastError: `reply-thread route lookup failed: ${String(error)}` })
        runtime.error?.(`inline reply-thread route lookup failed: ${String(error)}`)
        return null
      })
      if (cachedRoute) {
        deliveryReplyThreadContext = await resolveInlineReplyThreadContextFromRoute({
          route: cachedRoute,
          client,
          chatCache,
          fallbackParentChatInfo: chatInfo,
        }).catch((error) => {
          publishStatus({ lastError: `reply-thread route restore failed: ${String(error)}` })
          runtime.error?.(`inline reply-thread route restore failed: ${String(error)}`)
          return null
        })
      }
    }

    if (shouldCreateDeliveryThread && !deliveryReplyThreadContext) {
      const createdThread = await createInlineReplyThreadForMessage({
        client,
        parentChatId: effectiveChatId,
        parentMessageId: msg.id,
      }).catch((error) => {
        publishStatus({ lastError: `createSubthread failed: ${String(error)}` })
        runtime.error?.(`inline create reply thread failed: ${String(error)}`)
        return null
      })

      if (createdThread) {
        deliveryReplyThreadContext = {
          childChatId: createdThread.childChatId,
          parentChatId: createdThread.parentChatId,
          parentChatKind: chatInfo.kind,
          ...(chatInfo.peerUserId != null ? { parentPeerUserId: chatInfo.peerUserId } : {}),
          parentChatTitle: effectiveGroupTitle,
          parentMessageId: createdThread.parentMessageId,
          threadLabel: buildInlineReplyThreadLabel({
            title: createdThread.title,
            anchorMessage: createdThread.anchorMessage,
          }),
          anchorMessage: createdThread.anchorMessage,
        }
        rememberInlineReplyThreadRoute({
          accountId: account.accountId,
          parentChatId: deliveryReplyThreadContext.parentChatId,
          threadId: deliveryReplyThreadContext.childChatId,
          parentMessageId: deliveryReplyThreadContext.parentMessageId,
          title: createdThread.title,
          threadLabel: deliveryReplyThreadContext.threadLabel,
          agentId: route.agentId,
          ...(inlineAgentId ? { inlineAgentId } : {}),
        })
      }
    }
    if (shouldCreateDeliveryThread && !deliveryReplyThreadContext) {
      const cachedRoute = await lookupInlineReplyThreadRoute({
        accountId: account.accountId,
        parentChatId: effectiveChatId,
        parentMessageId: msg.id,
        agentId: route.agentId,
      }).catch(() => null)
      if (cachedRoute) {
        deliveryReplyThreadContext = await resolveInlineReplyThreadContextFromRoute({
          route: cachedRoute,
          client,
          chatCache,
          fallbackParentChatInfo: chatInfo,
        }).catch(() => null)
      }
    }
    if (shouldCreateDeliveryThread && !deliveryReplyThreadContext) {
      await setParentThreadCreationTyping(false)
      runtime.error?.("inline create reply thread failed; answer withheld from parent chat")
      const sent = await sendMessage({
        chatId,
        text: "I couldn't confirm the reply thread, so I haven't sent the answer. Please check the thread or try again.",
        replyToMsgId: msg.id,
        parseMarkdown,
      })
      rememberSentBotMessage({ chatId, messageId: sent.messageId })
      publishStatus({ lastOutboundAt: Date.now() })
      return
    }
    await setParentThreadCreationTyping(false)
    if (!replyThreadContext && deliveryReplyThreadContext?.anchorMessage != null) {
      effectiveHistoryContext = prependInlineReplyThreadAnchor({
        historyContext: {
          historyText: null,
          attachmentText: null,
          entityText: null,
          inboundHistory: [],
          repliedToBot: effectiveHistoryContext.repliedToBot,
          replyToSenderId: effectiveHistoryContext.replyToSenderId,
        },
        anchorMessage: deliveryReplyThreadContext.anchorMessage,
        parentChatId: deliveryReplyThreadContext.parentChatId,
        senderProfilesById,
        meId,
      })
    }
    const canExposeParentHistoryToSender =
      deliveryReplyThreadContext != null &&
      (deliveryReplyThreadContext.parentChatKind !== "direct" ||
        (deliveryReplyThreadContext.parentPeerUserId != null &&
          String(deliveryReplyThreadContext.parentPeerUserId) === senderId))
    if (deliveryReplyThreadContext && canExposeParentHistoryToSender) {
      const parentHistoryContext = await buildReplyThreadParentHistoryContext({
        client,
        replyThreadContext: deliveryReplyThreadContext,
        parentHistoryLimit: replyThreadParentHistoryLimit,
        senderProfilesById,
        meId,
        botMessageIdsByChat,
      }).catch((err) => {
        publishStatus({ lastError: `getChatHistory (reply thread parent) failed: ${String(err)}` })
        return null
      })
      if (parentHistoryContext) {
        effectiveHistoryContext = prependInlineParentHistoryContext({
          historyContext: effectiveHistoryContext,
          parentHistoryContext,
        })
      }
    }

    let deliveryChatId = deliveryReplyThreadContext?.childChatId ?? chatId
    let deliveryTypingChain: Promise<void> = Promise.resolve()
    const sendDeliveryTyping = (targetChatId: bigint, typing: boolean): Promise<void> => {
      const phase = typing ? "start" : "stop"
      const task = deliveryTypingChain
        .catch(() => {})
        .then(() => sendInlineTypingToChats({
          client,
          chatIds: [targetChatId],
          typing,
          onPartialError: (failedChatId, error) =>
            runtime.error?.(
              `inline typing ${phase} failed for chat ${String(failedChatId)}: ${String(error)}`,
            ),
        }))
      // Preserve ordering after an individual activity RPC fails. The caller
      // still receives the original failure through `task`.
      deliveryTypingChain = task.catch(() => {})
      return task
    }
    let adoptingThread = false
    let adoptedThreadThisTurn = false
    const baseDeliverySessionKey = deliveryReplyThreadContext
      ? buildInlineReplyThreadSessionKey(route.sessionKey, deliveryReplyThreadContext.childChatId)
      : baseInboundSessionKey
    const deliverySessionKey = projectInlineAgentSessionKey(
      baseDeliverySessionKey,
      inlineAgentId,
      inlineAgent,
    )
    const groupHistoryKey = isGroup
      ? deliveryReplyThreadContext
        ? deliverySessionKey
        : route.sessionKey
      : null

    const inboundMedia = await resolveInlineInboundMedia({
      core,
      message: msg,
      maxBytes: inboundMediaMaxBytes,
      ...(log ? { log } : {}),
    })

    const timestamp = messageTimestamp
    const fromLabel = resolveInlineConversationLabel({
      isGroup,
      groupTitle: effectiveGroupTitle,
      groupId: String(effectiveChatId),
      senderLabel,
    })

    const storePath = core.channel.session.resolveStorePath(cfg.session?.store, { agentId: route.agentId })
    const rawBodyForAgent = isGroup && mentionGate.effectiveWasMentioned
      ? stripInlineBotMention(rawBody, botUsername)
      : rawBody
    const agentBodyForCommands = inlineAgent?.skillKey
      ? `/skill ${inlineAgent.skillKey}${rawBodyForAgent ? ` ${rawBodyForAgent}` : ""}`
      : inlineAgent
        ? rawBodyForAgent
        : normalizedCommandBody
    const currentEntityTextForAgent =
      isGroup && mentionGate.effectiveWasMentioned
        ? stripInlineBotMentionEntityText(currentEntityText, botUsername)
        : currentEntityText
    const currentBody = rawBodyForAgent || rawBody
    const inboundHistory =
      isGroup && groupHistoryKey
        ? mergeInboundHistoryEntries({
            historyContextEntries: effectiveHistoryContext.inboundHistory,
            pendingEntries: groupPendingHistories.get(groupHistoryKey) ?? [],
            limit: historyLimit,
          })
        : effectiveHistoryContext.inboundHistory
    const actionCallbackDataUtf8 = callbackActionEvent
      ? callbackDataToUtf8(callbackActionEvent.data)
      : undefined
    const channelStructuredContext = buildInlineChannelStructuredContext({
      currentAttachmentText,
      currentEntityText: currentEntityTextForAgent,
      currentBody,
      historyAttachmentText: effectiveHistoryContext.attachmentText,
      historyEntityText: effectiveHistoryContext.entityText,
      ...(callbackActionEvent
        ? {
            actionContext: buildInlineAgentActionStructuredContext({
              actorUserId: msg.fromId,
              chatId,
              targetMessageId: callbackActionEvent.targetMessageId,
              interactionId: callbackActionEvent.interactionId,
              actionId: callbackActionEvent.actionId,
              callbackDataBase64: callbackDataToBase64(callbackActionEvent.data),
              ...(actionCallbackDataUtf8
                ? { callbackDataUtf8: actionCallbackDataUtf8 }
                : {}),
            }),
          }
        : {}),
    })
    const inboundEventKind = classifyChannelInboundEvent({
      conversation: { kind: isGroup ? "group" : "direct" },
      unmentionedGroupPolicy: resolveUnmentionedGroupInboundPolicy({
        cfg,
        agentId: route.agentId,
      }),
      ...(isGroup ? { wasMentioned: mentionGate.effectiveWasMentioned } : {}),
      hasControlCommand,
      ...(commandSource ? { commandSource } : {}),
    })
    const effectiveSurface = CHANNEL_ID
    const baseSystemPrompt = resolveInlineSystemPrompt({
      account,
      ...(isGroup ? { groupId: String(effectiveChatId) } : {}),
      replyThread: Boolean(deliveryReplyThreadContext),
      botHandBack: senderIsBot && !wasMentioned,
    })
    const inlineAgentPrompt = inlineAgent
      ? buildInlineAgentSpecializationPrompt(inlineAgent)
      : undefined
    const systemPrompt = [baseSystemPrompt, inlineAgentPrompt].filter(Boolean).join("\n\n") || undefined
    const messageSid = buildInlineInboundMessageSid({
      msgId: msg.id,
      ...(callbackActionEvent ? { callbackActionEvent } : {}),
    })
    const messageIds = input.messageIds?.filter(Boolean) ?? []
    const batchMessageIds = messageIds.length > 1 ? messageIds : null

    const ctxPayload = core.channel.reply.finalizeInboundContext({
      Body: rawBody,
      InboundEventKind: inboundEventKind,
      BodyForAgent: currentBody,
      BodyForCommands: agentBodyForCommands,
      InboundHistory: inboundHistory,
      RawBody: rawBody,
      CommandBody: normalizedCommandBody,
      From: isGroup ? `inline:chat:${String(effectiveChatId)}` : `inline:${senderId}`,
      To: `inline:${String(effectiveChatId)}`,
      SessionKey: deliverySessionKey,
      ...(deliveryReplyThreadContext ? { ParentSessionKey: route.sessionKey } : {}),
      AccountId: route.accountId,
      ChatType: isGroup ? "group" : "direct",
      ConversationLabel: fromLabel,
      ...(isGroup ? { GroupSubject: effectiveGroupTitle ?? String(effectiveChatId) } : {}),
      SenderId: senderId,
      ...(senderName ? { SenderName: senderName } : {}),
      ...(senderUsername ? { SenderUsername: senderUsername } : {}),
      Provider: CHANNEL_ID,
      Surface: effectiveSurface,
      MessageSid: messageSid,
      ...(batchMessageIds
        ? {
            MessageSids: batchMessageIds,
            MessageSidFirst: batchMessageIds[0],
            MessageSidLast: batchMessageIds[batchMessageIds.length - 1],
          }
        : {}),
      ...(commandSource ? { CommandSource: commandSource } : {}),
      CommandTurn: commandSource
        ? {
            kind: commandSource === "native" ? "native" : "text-slash",
            source: commandSource,
            authorized: commandAuthorized,
            body: normalizedCommandBody,
          }
        : {
            kind: "normal",
            source: "message",
            authorized: false,
            body: normalizedCommandBody,
          },
      ...(deliveryReplyThreadContext ? { MessageThreadId: String(deliveryReplyThreadContext.childChatId) } : {}),
      ...(deliveryReplyThreadContext?.threadLabel ? { ThreadLabel: deliveryReplyThreadContext.threadLabel } : {}),
      ...(msg.replyToMsgId != null ? { ReplyToId: String(msg.replyToMsgId) } : {}),
      ...(effectiveHistoryContext.replyToSenderId != null ? { ReplyToSenderId: effectiveHistoryContext.replyToSenderId } : {}),
      ...(msg.replyToMsgId != null ? { ReplyToWasBot: effectiveHistoryContext.repliedToBot } : {}),
      ...(channelStructuredContext.length > 0
        ? { ChannelStructuredContext: channelStructuredContext }
        : {}),
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
      ...(inboundMedia.length > 0 ? { media: buildInlineInboundMediaFacts(inboundMedia) } : {}),
      Timestamp: timestamp || Date.now(),
      ...(isGroup ? { WasMentioned: mentionGate.effectiveWasMentioned } : {}),
      ...(isGroup
        ? {
            ExplicitlyMentionedBot: explicitlyMentioned,
            ...(mentionedUserIds.length > 0 ? { MentionedUserIds: mentionedUserIds } : {}),
            ...(implicitMentionKinds.length > 0 ? { ImplicitMentionKinds: implicitMentionKinds } : {}),
            MentionSource: mentionSource,
          }
        : {}),
      CommandAuthorized: commandAuthorized,
      ...(systemPrompt ? { GroupSystemPrompt: systemPrompt } : {}),
      OriginatingChannel: CHANNEL_ID,
      OriginatingTo: `inline:${String(deliveryChatId)}`,
      NativeChannelId: String(chatId),
    })

    await core.channel.session.recordInboundSession({
      storePath,
      sessionKey: ctxPayload.SessionKey ?? deliverySessionKey,
      ctx: ctxPayload,
      ...(!isGroup
        ? {
            updateLastRoute: {
              sessionKey: resolveInboundLastRouteSessionKey({ route, sessionKey: route.sessionKey }),
              channel: CHANNEL_ID,
              to: `inline:${String(effectiveChatId)}`,
              accountId: route.accountId,
              ...(deliveryChatId !== effectiveChatId
                ? { threadId: String(deliveryChatId) }
                : {}),
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
        start: () => adoptingThread ? Promise.resolve() :
          sendDeliveryTyping(deliveryChatId, true),
        stop: () => sendDeliveryTyping(deliveryChatId, false),
        onStartError: (err) => runtime.error?.(`inline typing start failed: ${String(err)}`),
        onStopError: (err) => runtime.error?.(`inline typing stop failed: ${String(err)}`),
      },
    })
    const onModelSelected = replyPipeline.onModelSelected
    const rawTypingCallbacks = replyPipeline.typingCallbacks
    const botPresenceLifecycle = createInlineBotPresenceLifecycle({
      client,
      chatIds: [deliveryChatId],
      onPartialError: (chatId, error) =>
        runtime.error?.(`inline bot presence failed for chat ${String(chatId)}: ${String(error)}`),
      onError: (error) => runtime.error?.(`inline bot presence failed: ${String(error)}`),
    })
    let deferredTypingCleanup = false
    const runTypingCleanup = () => {
      rawTypingCallbacks?.onCleanup?.()
      botPresenceLifecycle.cleanup()
    }
    const typingCallbacks: InlineTypingCallbacks | undefined = rawTypingCallbacks
      ? {
          onReplyStart: async () => {
            await Promise.all([
              rawTypingCallbacks.onReplyStart(),
              botPresenceLifecycle.start(),
            ])
          },
          ...(rawTypingCallbacks.onIdle
            ? {
                onIdle: () => {
                  rawTypingCallbacks.onIdle?.()
                  botPresenceLifecycle.finish()
                },
              }
            : {}),
          ...(rawTypingCallbacks.onCleanup
            ? {
                onCleanup: () => {
                  if (adoptingThread) {
                    deferredTypingCleanup = true
                    return
                  }
                  runTypingCleanup()
                },
              }
            : {}),
        }
      : undefined
    const dispatcherPipelineOptions = {
      ...(replyPipeline.responsePrefix !== undefined
        ? { responsePrefix: replyPipeline.responsePrefix }
        : {}),
      ...(replyPipeline.responsePrefixContextProvider
        ? {
            responsePrefixContextProvider:
              replyPipeline.responsePrefixContextProvider as never,
          }
        : {}),
      ...(replyPipeline.transformReplyPayload
        ? { transformReplyPayload: replyPipeline.transformReplyPayload as never }
        : {}),
    }

    const callbackTargetMessage =
      shouldEditCallbackTargetInPlace && callbackActionEvent
        ? await findChatMessageById({
            client,
            chatId,
            messageId: callbackActionEvent.targetMessageId,
            limit: REPLY_TARGET_LOOKUP_LIMIT,
            meId,
            botMessageIdsByChat,
          }).catch(() => null)
        : null

    const agentActivityEnabled = account.config.experimentalAgentActivity === true
    const inlineStreamingMode = resolveInlineStreamingMode(account.config)
    const streamViaEditMessage =
      inlineStreamingMode === "partial" &&
      !shouldEditCallbackTargetInPlace
    const progressPlaceholderEnabled =
      resolveInlineProgressPlaceholderEnabled(account.config) &&
      !shouldEditCallbackTargetInPlace
    const progressToolProgressEnabled =
      progressPlaceholderEnabled && resolveChannelStreamingPreviewToolProgress(account.config)
    const suppressDefaultToolProgressMessages = progressPlaceholderEnabled
    // An answer quotes a bot only when that bot asked by mention or addressed
    // command, so the answer reaches it. A bot's reply needs no answer and quoting
    // it would wake it again, which is how two bots end up in a loop. People get
    // plain answers.
    const botAskedThisBot = senderIsBot && wasMentioned
    const botHandBack = senderIsBot && !wasMentioned
    let canReplyToSourceMessage = deliveryChatId === chatId && !botHandBack
    let defaultReplyToMsgId =
      canReplyToSourceMessage && botAskedThisBot ? msg.id : undefined
    const inlineBlockStreamingEnabled = resolveInlineBlockStreamingEnabled(account.config)
    const disableBlockStreaming =
      progressPlaceholderEnabled || streamViaEditMessage
        ? true
        : typeof inlineBlockStreamingEnabled === "boolean"
        ? !inlineBlockStreamingEnabled
        : undefined
    const editStreamState: InlineEditStreamState = {
      messageId: shouldEditCallbackTargetInPlace ? callbackActionEvent?.targetMessageId ?? null : null,
      initialSendMayHaveLanded: false,
      accumulatedText: callbackTargetMessage?.message ?? "",
      lastPartialText: "",
      finalTextAccumulator: "",
      failed: false,
      pendingSnapshot: null,
      inFlight: null,
      timer: null,
      nextAllowedAt: 0,
      actionsFingerprint: null,
      latestActions: undefined,
    }
    let progressSeed = `${account.accountId}:${String(deliveryChatId)}:${String(msg.id)}`
    const progressState: InlineProgressPlaceholderState = {
      messageId: null,
      text: "",
      lines: [],
      opChain: Promise.resolve(),
      closing: false,
      startedAt: null,
      toolFailed: false,
      lastClosed: null,
      pendingClosures: new Set(),
    }
    const progressMaxLineChars = resolveChannelProgressDraftMaxLineChars(account.config)
    // The row's start on the wall clock, for the clients' live timer; the
    // monotonic clock stays the source of truth for "Worked for".
    // Kept per start, so clock jitter can't change the text and force an edit.
    let progressStartedAtWall: { at: number; unix: number } | null = null
    const progressStartedAtUnix = (): number => {
      const startedAt = progressState.startedAt ?? performance.now()
      if (progressStartedAtWall?.at !== startedAt) {
        progressStartedAtWall = { at: startedAt, unix: Math.floor((Date.now() - (performance.now() - startedAt)) / 1000) }
      }
      return progressStartedAtWall.unix
    }
    const formatProgress = (lines: Array<string | ChannelProgressDraftLine>, working: boolean, elapsed?: number, outcome?: ActivityOutcome, toolFailed?: boolean) =>
      agentActivityEnabled
        ? formatQuietTimeline(lines, working, elapsed, outcome, toolFailed, progressMaxLineChars, working ? progressStartedAtUnix() : undefined)
        : sanitizeInlineDeliveryText(formatChannelProgressDraftText({
            entry: account.config, lines, seed: progressSeed,
          })).trim()
    const renderInlineProgressPlaceholder = async (): Promise<void> => {
      if (abortSignal.aborted || !progressPlaceholderEnabled || progressState.closing || adoptingThread) return
      const text = formatProgress(progressState.lines, true)
      if (!text || text === progressState.text) return

      progressState.opChain = progressState.opChain
        .then(async () => {
          if (abortSignal.aborted || progressState.closing || text === progressState.text) return
          if (progressState.messageId == null) {
            progressState.startedAt ??= performance.now()
            const sent = await sendMessage({
              chatId: deliveryChatId,
              text,
              sendMode: "silent",
              parseMarkdown: agentActivityEnabled || parseMarkdown,
            })
            if (sent.messageId == null) {
              throw new Error("inline progress placeholder: sendMessage returned no messageId")
            }
            progressState.messageId = sent.messageId
            rememberSentBotMessage({
              chatId: deliveryChatId,
              messageId: sent.messageId,
              replyThreadContext: deliveryReplyThreadContext,
            })
          } else {
            const result = await client.invokeRaw(Method.EDIT_MESSAGE, {
              oneofKind: "editMessage",
              editMessage: {
                messageId: progressState.messageId,
                peerId: buildChatPeer(deliveryChatId),
                text,
                parseMarkdown: agentActivityEnabled || parseMarkdown,
              },
            })
            if (result.oneofKind !== "editMessage") {
              throw new Error(
                `inline progress placeholder: expected editMessage result, got ${String(result.oneofKind)}`,
              )
            }
          }
          progressState.text = text
          publishStatus({ lastOutboundAt: Date.now() })
        })
        .catch((error) => {
          runtime.error?.(`inline progress placeholder failed: ${String(error)}`)
        })

      await progressState.opChain
    }
    let progressDraftGate = createChannelProgressDraftGate({
      onStart: renderInlineProgressPlaceholder,
    })
    let activityOperationTail: Promise<void> = Promise.resolve()
    const enqueueActivityOperation = <T>(operation: () => Promise<T>): Promise<T> => {
      if (!agentActivityEnabled) return operation()
      const pending = activityOperationTail.then(operation)
      // Keep later operations runnable after a failed visible send.
      activityOperationTail = pending.then(() => undefined, () => undefined)
      return pending
    }
    const drainActivityOperations = async (): Promise<void> => {
      let pending: Promise<void>
      do {
        pending = activityOperationTail
        await pending
      } while (pending !== activityOperationTail)
    }
    const pushInlineProgressPlaceholder = async (
      line?: string | ChannelProgressDraftLine,
      options?: { toolName?: string; startImmediately?: boolean },
    ): Promise<void> => {
      const eventAt = performance.now()
      return enqueueActivityOperation(async () => {
        if (!progressPlaceholderEnabled || progressState.closing) return
        if (options?.toolName !== undefined && !isChannelProgressDraftWorkToolName(options.toolName)) {
          return
        }

        const normalized = typeof line === "string" ? line.replace(/\s+/g, " ").trim() : line?.text.trim()
        if (line && !normalized) return
        if (line) progressState.startedAt ??= eventAt
        if (progressToolProgressEnabled && line && normalized) {
          const toolFailed = agentActivityEnabled && activityAttention([line]).failed
          const nextLines = mergeChannelProgressDraftLine(progressState.lines, line, {
            maxLines: agentActivityEnabled ? Number.MAX_SAFE_INTEGER : resolveChannelProgressDraftMaxLines(account.config),
          })
          if (nextLines !== progressState.lines) {
            if (agentActivityEnabled) preserveActivityTitles(progressState.lines, nextLines)
            // Reserve room for the terminal title, and flush even if the initial
            // delayed draft has not been sent yet. Individual previews are bounded.
            if (agentActivityEnabled && nextLines.length > 1 && formatProgress(nextLines, true).length > ACTIVITY_MESSAGE_MAX_CHARS - 300) {
              const rolloverLine = nextLines.find((entry, index) => entry !== progressState.lines[index]) ?? line
              await progressDraftGate.startNow()
              await cleanupInlineProgressPlaceholder("success", eventAt)
              progressState.closing = false
              progressState.lines = [rolloverLine]
              progressState.startedAt = eventAt
              progressDraftGate = createChannelProgressDraftGate({ onStart: renderInlineProgressPlaceholder })
            } else {
              progressState.lines = nextLines
            }
          }
          progressState.toolFailed ||= toolFailed
        }

        const alreadyStarted = progressDraftGate.hasStarted
        if (options?.startImmediately || shouldStartInlineProgressPlaceholderNow(line)) {
          await progressDraftGate.startNow()
        } else {
          await progressDraftGate.noteWork()
        }
        if (alreadyStarted && progressDraftGate.hasStarted) {
          await renderInlineProgressPlaceholder()
        }
      })
    }
    const cleanupInlineProgressPlaceholder = async (outcome: ActivityOutcome = "success", endedAt = performance.now()): Promise<void> => {
      progressDraftGate.cancel()
      progressState.closing = true
      // Freeze the endpoint before awaiting queued transport.
      await progressState.opChain
      const messageId = progressState.messageId
      if (!agentActivityEnabled) {
        if (messageId == null) return
        try {
          const result = await client.invokeRaw(Method.DELETE_MESSAGES, {
            oneofKind: "deleteMessages",
            deleteMessages: { peerId: buildChatPeer(deliveryChatId), messageIds: [messageId] },
          })
          if (result.oneofKind !== "deleteMessages") {
            throw new Error(`inline progress placeholder: expected deleteMessages result, got ${String(result.oneofKind)}`)
          }
        } catch (error) {
          runtime.error?.(`inline progress placeholder cleanup failed: ${String(error)}`)
        } finally {
          progressState.messageId = null
          progressState.text = ""
        }
        return
      }
      if (messageId != null) {
        progressState.lastClosed = {
          messageId, chatId: deliveryChatId, lines: progressState.lines.slice(),
          elapsed: Math.max(0, (endedAt - (progressState.startedAt ?? endedAt)) / 1000),
          toolFailed: progressState.toolFailed,
          outcome,
        }
        progressState.pendingClosures.add(progressState.lastClosed)
        progressState.messageId = null
      }
      // A short block may close before its delayed first send. Its clock and
      // attention still belong to that block, never the next conversational step.
      progressState.text = ""
      progressState.startedAt = null
      progressState.toolFailed = false
      const row = progressState.lastClosed
      // A final dispatch error may arrive after the reply boundary closed its
      // activity row. Correct that row using its frozen duration and peer.
      if (row && messageId == null && outcome !== "success" && row.outcome !== outcome) {
        row.outcome = outcome
        progressState.pendingClosures.add(row)
      }
      for (const pending of progressState.pendingClosures) {
        // Editing the same frozen payload is idempotent. Keep failed closures
        // through rollovers and retry again at the reply/turn boundary.
        for (let attempt = 0; attempt < 2; attempt++) {
          try {
            const result = await client.invokeRaw(Method.EDIT_MESSAGE, {
              oneofKind: "editMessage",
              editMessage: {
                peerId: buildChatPeer(pending.chatId), messageId: pending.messageId,
                text: formatProgress(pending.lines, false, pending.elapsed, pending.outcome, pending.toolFailed),
                parseMarkdown: true,
              },
            })
            if (result.oneofKind !== "editMessage") {
              throw new Error(`inline activity: expected editMessage result, got ${String(result.oneofKind)}`)
            }
            progressState.pendingClosures.delete(pending)
            break
          } catch (error) {
            if (attempt === 1) runtime.error?.(`inline progress placeholder cleanup failed: ${String(error)}`)
          }
        }
      }
    }
    let finalDeliveredForCurrentAssistantMessage = false
    const clearEditStreamTimer = (): void => {
      if (editStreamState.timer == null) return
      clearTimeout(editStreamState.timer)
      editStreamState.timer = null
    }
    const nextEditStreamInterval = (requestDurationMs: number): number =>
      Math.min(
        INLINE_EDIT_STREAM_MAX_INTERVAL_MS,
        Math.max(INLINE_EDIT_STREAM_MIN_INTERVAL_MS, Math.ceil(requestDurationMs * 1.25)),
      )
    const sendEditStreamSnapshot = async (snapshot: InlineEditStreamSnapshot): Promise<void> => {
      if (abortSignal.aborted) return
      try {
        if (editStreamState.messageId == null) {
          let sent: Awaited<ReturnType<typeof client.sendMessage>>
          try {
            sent = await sendMessage({
              chatId: deliveryChatId,
              text: snapshot.text,
              ...(defaultReplyToMsgId != null ? { replyToMsgId: defaultReplyToMsgId } : {}),
              ...(snapshot.actions !== undefined ? { actions: snapshot.actions } : {}),
              parseMarkdown,
            })
          } catch (error) {
            if (isInlineSendOutcomeUnknown(error)) {
              // The SDK already replays SEND_MESSAGE with its durable randomId.
              // If that still ends ambiguously, a new final send could duplicate
              // a draft that the server accepted before the connection failed.
              editStreamState.initialSendMayHaveLanded = true
            }
            throw error
          }
          if (sent.messageId == null) {
            editStreamState.initialSendMayHaveLanded = true
            throw new Error("inline edit stream: sendMessage returned no messageId")
          }
          editStreamState.messageId = sent.messageId
          editStreamState.initialSendMayHaveLanded = false
          rememberSentBotMessage({
            chatId: deliveryChatId,
            messageId: sent.messageId,
            replyThreadContext: deliveryReplyThreadContext,
          })
        } else {
          const result = await client.invokeRaw(Method.EDIT_MESSAGE, {
            oneofKind: "editMessage",
            editMessage: {
              messageId: editStreamState.messageId,
              peerId: buildChatPeer(deliveryChatId),
              text: snapshot.text,
              parseMarkdown,
              ...(snapshot.actions !== undefined ? { actions: snapshot.actions } : {}),
            },
          })
          if (result.oneofKind !== "editMessage") {
            throw new Error(
              `inline edit stream: expected editMessage result, got ${String(result.oneofKind)}`,
            )
          }
        }
        editStreamState.accumulatedText = snapshot.text
        if (snapshot.actions !== undefined) {
          editStreamState.actionsFingerprint = snapshot.actionsFingerprint
        }
        publishStatus({ lastOutboundAt: Date.now() })
      } catch (error) {
        editStreamState.failed = true
        editStreamState.pendingSnapshot = null
        runtime.error?.(`inline edit stream failed: ${String(error)}`)
      }
    }
    const scheduleEditStreamDrain = (): void => {
      if (abortSignal.aborted) {
        editStreamState.pendingSnapshot = null
        clearEditStreamTimer()
        return
      }
      if (
        editStreamState.failed ||
        editStreamState.inFlight != null ||
        editStreamState.timer != null ||
        editStreamState.pendingSnapshot == null
      ) {
        return
      }

      const waitMs = Math.max(0, editStreamState.nextAllowedAt - Date.now())
      if (waitMs > 0) {
        editStreamState.timer = setTimeout(() => {
          editStreamState.timer = null
          scheduleEditStreamDrain()
        }, waitMs)
        return
      }

      const snapshot = editStreamState.pendingSnapshot
      editStreamState.pendingSnapshot = null
      const actionsUnchanged =
        snapshot.actions === undefined ||
        snapshot.actionsFingerprint === editStreamState.actionsFingerprint
      if (
        !snapshot.text ||
        (snapshot.text === editStreamState.accumulatedText && actionsUnchanged)
      ) return

      const startedAt = Date.now()
      const operation = sendEditStreamSnapshot(snapshot)
      editStreamState.inFlight = operation
      void operation.finally(() => {
        if (editStreamState.inFlight !== operation) return
        editStreamState.inFlight = null
        const completedAt = Date.now()
        const nextStartAt = startedAt + nextEditStreamInterval(completedAt - startedAt)
        editStreamState.nextAllowedAt = Math.max(completedAt, nextStartAt)
        scheduleEditStreamDrain()
      })
    }
    const settleEditStream = async (dropPending: boolean): Promise<void> => {
      if (dropPending) editStreamState.pendingSnapshot = null
      clearEditStreamTimer()
      while (true) {
        const inFlight = editStreamState.inFlight
        if (inFlight) {
          await inFlight
          if (dropPending) editStreamState.pendingSnapshot = null
          clearEditStreamTimer()
          continue
        }
        if (!dropPending && editStreamState.pendingSnapshot != null && !editStreamState.failed) {
          editStreamState.nextAllowedAt = 0
          scheduleEditStreamDrain()
          continue
        }
        return
      }
    }
    const partialMediaDeliveries = new Map<
      string,
      Promise<InlinePartialMediaDeliveryResult>
    >()
    const activePartialMediaDeliveries = new Set<Promise<InlinePartialMediaDeliveryResult>>()
    let partialMediaDeliveryTail: Promise<void> = Promise.resolve()
    let partialMediaReplyClaimed = false
    let partialMediaDelivered = false
    const recordPartialMediaDelivery = (messageId: bigint | null | undefined): void => {
      partialMediaDelivered = true
      try {
        rememberSentBotMessage({
          chatId: deliveryChatId,
          messageId,
          replyThreadContext: deliveryReplyThreadContext,
        })
        publishStatus({ lastOutboundAt: Date.now() })
      } catch (error) {
        // Delivery already committed. Local bookkeeping must never turn that
        // receipt into a second user-visible send.
        runtime.error?.(`inline partial media bookkeeping failed: ${String(error)}`)
      }
    }
    const deliverPartialMediaUrlFallback = async (params: {
      mediaUrl: string
      isFirstMediaForAnswer: boolean
      replyToMsgId: bigint | undefined
      attachActions: boolean
      actions: MessageActions | undefined
    }): Promise<InlinePartialMediaDeliveryResult> => {
      try {
        const sent = await sendMessage({
          chatId: deliveryChatId,
          text: `Attachment: ${params.mediaUrl}`,
          ...(params.isFirstMediaForAnswer && params.replyToMsgId != null
            ? { replyToMsgId: params.replyToMsgId }
            : {}),
          ...(params.attachActions && params.actions !== undefined
            ? { actions: params.actions }
            : {}),
          parseMarkdown,
        })
        recordPartialMediaDelivery(sent.messageId)
        return {
          mediaUrl: params.mediaUrl,
          messageId: sent.messageId ?? null,
          sent: true,
          usedUrlFallback: true,
          commitOutcomeUnknown: false,
        }
      } catch (deliveryError) {
        if (isInlineSendOutcomeUnknown(deliveryError)) {
          partialMediaDelivered = true
          runtime.error?.(
            `inline partial media fallback outcome is unknown; suppressing duplicate (${String(deliveryError)})`,
          )
          return {
            mediaUrl: params.mediaUrl,
            messageId: null,
            sent: true,
            usedUrlFallback: true,
            commitOutcomeUnknown: true,
          }
        }
        runtime.error?.(
          `inline partial media fallback failed (${String(deliveryError)})`,
        )
        return {
          mediaUrl: params.mediaUrl,
          messageId: null,
          sent: false,
          usedUrlFallback: false,
          commitOutcomeUnknown: false,
        }
      }
    }
    const deliverPartialMedia = async (params: {
      mediaUrl: string
      isFirstMediaForAnswer: boolean
      replyToMsgId: bigint | undefined
      attachActions: boolean
      actions: MessageActions | undefined
    }): Promise<InlinePartialMediaDeliveryResult> => {
      let media: Awaited<ReturnType<typeof uploadInlineMediaFromUrl>>
      try {
        media = await uploadInlineMediaFromUrl({
          client,
          cfg,
          accountId: account.accountId,
          mediaUrl: params.mediaUrl,
        })
      } catch (uploadError) {
        runtime.error?.(
          `inline partial media upload failed; falling back to url text (${String(uploadError)})`,
        )
        return deliverPartialMediaUrlFallback(params)
      }

      try {
        const sent = await sendMessage({
          chatId: deliveryChatId,
          media,
          ...(params.isFirstMediaForAnswer && params.replyToMsgId != null
            ? { replyToMsgId: params.replyToMsgId }
            : {}),
          ...(params.attachActions && params.actions !== undefined
            ? { actions: params.actions }
            : {}),
        })
        recordPartialMediaDelivery(sent.messageId)
        return {
          mediaUrl: params.mediaUrl,
          messageId: sent.messageId ?? null,
          sent: true,
          usedUrlFallback: false,
          commitOutcomeUnknown: false,
        }
      } catch (deliveryError) {
        if (isInlineSendOutcomeUnknown(deliveryError)) {
          partialMediaDelivered = true
          runtime.error?.(
            `inline partial media send outcome is unknown; suppressing duplicate (${String(deliveryError)})`,
          )
          return {
            mediaUrl: params.mediaUrl,
            messageId: null,
            sent: true,
            usedUrlFallback: false,
            commitOutcomeUnknown: true,
          }
        }
        runtime.error?.(
          `inline partial media send failed; falling back to url text (${String(deliveryError)})`,
        )
        return deliverPartialMediaUrlFallback(params)
      }
    }
    const startPartialMediaDeliveries = (
      payload: InlineReplyPayload,
      actions: MessageActions | undefined,
      hasVisibleText: boolean,
      replyToMsgId: bigint | undefined,
    ): void => {
      for (const mediaUrl of resolveInlinePayloadMediaUrls(payload)) {
        if (partialMediaDeliveries.has(mediaUrl)) continue
        const isFirstMediaForAnswer = !partialMediaReplyClaimed
        partialMediaReplyClaimed = true
        const attachActions = isFirstMediaForAnswer && !hasVisibleText && actions !== undefined
        const delivery = partialMediaDeliveryTail.then(() => deliverPartialMedia({
          mediaUrl,
          isFirstMediaForAnswer,
          replyToMsgId,
          attachActions,
          actions,
        }))
        // Telegram's durable media funnel commits in input order. Keep the same
        // ordering here while retaining URL dedupe across cumulative partials.
        partialMediaDeliveryTail = delivery.then(
          () => undefined,
          () => undefined,
        )
        partialMediaDeliveries.set(mediaUrl, delivery)
        activePartialMediaDeliveries.add(delivery)
        void delivery.then(() => {
          activePartialMediaDeliveries.delete(delivery)
        })
      }
    }
    const settlePartialMediaDeliveries = async (): Promise<void> => {
      await Promise.all(activePartialMediaDeliveries)
    }
    const resetEditStreamForAssistantMessage = async (): Promise<void> => {
      const hadPartialMedia = partialMediaDeliveries.size > 0
      await settleEditStream(true)
      await settlePartialMediaDeliveries()
      partialMediaDeliveries.clear()
      activePartialMediaDeliveries.clear()
      partialMediaDeliveryTail = Promise.resolve()
      partialMediaReplyClaimed = false
      const hasActiveState =
        editStreamState.messageId != null ||
        editStreamState.initialSendMayHaveLanded ||
        editStreamState.accumulatedText.length > 0 ||
        editStreamState.lastPartialText.length > 0 ||
        editStreamState.finalTextAccumulator.length > 0 ||
        hadPartialMedia
      if (!hasActiveState) return
      editStreamState.messageId = null
      editStreamState.initialSendMayHaveLanded = false
      editStreamState.accumulatedText = ""
      editStreamState.lastPartialText = ""
      editStreamState.finalTextAccumulator = ""
      editStreamState.failed = false
      editStreamState.pendingSnapshot = null
      editStreamState.nextAllowedAt = 0
      editStreamState.actionsFingerprint = null
      editStreamState.latestActions = undefined
      finalDeliveredForCurrentAssistantMessage = false
    }
    const resetEditStreamOnBoundary = async (): Promise<void> => {
      if (!streamViaEditMessage) return
      await resetEditStreamForAssistantMessage()
    }
    const handlePartialStreamPayload = (payload: InlineReplyPayload): void => {
      if (abortSignal.aborted || adoptingThread) return
      const visiblePayload = resolveInlineChatVisibleReplyPayload(payload)
      if (!visiblePayload) return
      const partialText = typeof visiblePayload.text === "string" ? visiblePayload.text : ""
      const nextText = sanitizeInlineDeliveryText(
        rewriteNumericMentionsToUsernames(
          partialText,
          senderProfilesById,
        ),
      ).trim() || editStreamState.accumulatedText
      const suppliedActions = resolveInlineReplyActions(visiblePayload as Record<string, unknown>)
      if (suppliedActions !== undefined) {
        editStreamState.latestActions = suppliedActions
      }
      const actions = suppliedActions ?? editStreamState.latestActions
      const actionsFingerprint = fingerprintInlineMessageActions(actions)

      if (!editStreamState.failed) {
        if (partialText && partialText !== editStreamState.lastPartialText) {
          editStreamState.lastPartialText = partialText
        }
        const pending = editStreamState.pendingSnapshot
        const actionsUnchanged =
          actions === undefined || actionsFingerprint === editStreamState.actionsFingerprint
        const matchesPending =
          pending?.text === nextText &&
          (actions === undefined || pending.actionsFingerprint === actionsFingerprint)
        if (
          nextText &&
          !matchesPending &&
          (nextText !== editStreamState.accumulatedText || !actionsUnchanged)
        ) {
          editStreamState.pendingSnapshot = {
            text: nextText,
            ...(actions !== undefined ? { actions } : {}),
            actionsFingerprint,
          }
          scheduleEditStreamDrain()
        }
      }

      let partialReplyToMsgId = defaultReplyToMsgId
      if (visiblePayload.replyToId != null && canReplyToSourceMessage) {
        try {
          partialReplyToMsgId = BigInt(visiblePayload.replyToId)
        } catch {
          // Ignore malformed producer reply targets and preserve the default route.
        }
      }
      startPartialMediaDeliveries(
        visiblePayload,
        actions,
        Boolean(nextText),
        partialReplyToMsgId,
      )
    }
    const buildInlineProgressLineForEntry = (
      input: Parameters<typeof buildChannelProgressDraftLineForEntry>[1],
      options?: Parameters<typeof buildChannelProgressDraftLineForEntry>[2],
    ): ChannelProgressDraftLine | undefined => {
      const line = buildChannelProgressDraftLineForEntry(
        account.config,
        normalizeInlineProgressToolInput(input),
        options,
      )
      relabelInlineCommandProgressLine(line, input)
      // Item titles are host-generated strings such as `command ${command}`,
      // not an agent description. Keep the description from the correlated start.
      const description = input.event === "tool"
        ? [input.args?.description, input.args?.title].find((value) => typeof value === "string" && value.trim())
        : undefined
      // Preserve an explicit agent description separately from the raw tool log.
      // Mutate the existing line so the host's WeakMap correlation survives.
      if (agentActivityEnabled && line && typeof description === "string" && description.trim()) {
        Object.assign(line, { activityTitle: description })
      }
      return line
    }

    let delivered = false
    const activeThreadRoute: ActiveInlineThreadRoute = {
      accountId: account.accountId,
      sessionKey: deliverySessionKey,
      sourceChatId: chatId,
      sourceMessageId: msg.id,
      sourceMessageSid: messageSid,
      parentPeer: {
        kind: isGroup ? "group" : "direct",
        id: isGroup ? String(effectiveChatId) : senderId,
      },
      threadId: deliveryReplyThreadContext?.childChatId,
      ...(agentActivityEnabled ? { runVisibleReply: async <T>(send: () => Promise<T>) => {
        const boundaryAt = performance.now()
        return enqueueActivityOperation(async () => {
          try {
            // Flush a delayed first row before placing its conversational reply.
            if (progressState.lines.length > 0 && !progressState.closing) await progressDraftGate.startNow()
            await cleanupInlineProgressPlaceholder("success", boundaryAt)
            const result = await send()
            delivered = true
            return result
          } finally {
            // Failed sends retain the closed logs and release later progress too.
            progressState.closing = false
            progressState.lines = []
            progressDraftGate = createChannelProgressDraftGate({ onStart: renderInlineProgressPlaceholder })
          }
        })
      } } : {}),
      onThreadAdopted: async (threadId: bigint) => {
        adoptingThread = true
        try {
          // Drain old-chat operations before changing IDs: Inline message IDs
          // are local to a chat, so an old draft cannot be edited in the child.
          await resetEditStreamForAssistantMessage().catch((error) =>
            runtime.error?.(`inline thread handoff stream reset failed: ${String(error)}`))
          await cleanupInlineProgressPlaceholder().catch((error) =>
            runtime.error?.(`inline thread handoff placeholder cleanup failed: ${String(error)}`))
          delivered = false
          partialMediaDelivered = false
          await sendDeliveryTyping(deliveryChatId, false)
            .catch((error) => runtime.error?.(`inline thread handoff typing stop failed: ${String(error)}`))
          deliveryChatId = threadId
          adoptedThreadThisTurn = true
          deliveryReplyThreadContext = {
            childChatId: threadId,
            parentChatId: chatId,
            parentChatKind: chatInfo.kind,
            ...(chatInfo.peerUserId != null ? { parentPeerUserId: chatInfo.peerUserId } : {}),
            parentChatTitle: effectiveGroupTitle,
            parentMessageId: msg.id,
            threadLabel: null,
            anchorMessage: msg,
          }
          canReplyToSourceMessage = false
          defaultReplyToMsgId = undefined
          ctxPayload.OriginatingTo = `inline:${String(threadId)}`
          ctxPayload.MessageThreadId = String(threadId)
          await botPresenceLifecycle.retarget(threadId).catch((error) =>
            runtime.error?.(`inline thread handoff presence retarget failed: ${String(error)}`))
          await sendDeliveryTyping(threadId, true)
            .catch((error) => runtime.error?.(`inline thread handoff typing start failed: ${String(error)}`))
          progressState.closing = false
          progressState.lines = []
          progressSeed = `${account.accountId}:${String(threadId)}:${String(msg.id)}`
          progressDraftGate = createChannelProgressDraftGate({ onStart: renderInlineProgressPlaceholder })
        } finally {
          adoptingThread = false
        }
      },
    }

    let activityRunId: string | undefined
    let activityHostOutcome: ActivityOutcome | undefined
    let activityHostEndedAt: number | undefined
    let activityTerminal: Promise<void> | undefined
    let resolveActivityTerminal: (() => void) | undefined
    const resetActivityTerminal = () => {
      activityHostOutcome = undefined
      activityHostEndedAt = undefined
      activityTerminal = new Promise<void>((resolve) => { resolveActivityTerminal = resolve })
    }
    const settleActivityTerminal = async () => {
      if (!agentActivityEnabled || !activityTerminal || activityHostOutcome || !core.events?.onAgentEvent) return
      if (progressState.messageId == null && !progressState.lastClosed && !progressDraftGate.hasStarted) return
      // /stop can settle channel dispatch before the admitted run emits its
      // terminal event. Drain that event before freezing the activity outcome.
      // Bound a missing host event so teardown cannot retain this listener.
      let timer: ReturnType<typeof setTimeout> | undefined
      try {
        await Promise.race([
          activityTerminal,
          new Promise<void>((resolve) => { timer = setTimeout(resolve, 2_000) }),
        ])
      } finally {
        if (timer) clearTimeout(timer)
      }
    }
    const replyOptions = {
      abortSignal,
      ...(agentActivityEnabled ? { onAgentRunStart: (runId: string) => {
        activityRunId = runId
        resetActivityTerminal()
      } } : {}),
      onObservedReplyDelivery: async () => {
        delivered = true
      },
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
            onPartialReply: async (payload: InlineReplyPayload) => {
              handlePartialStreamPayload(payload)
            },
          }
        : {}),
      ...(progressPlaceholderEnabled
        ? {
            onReasoningStream: async () => {
              botPresenceLifecycle.busy("review")
              await pushInlineProgressPlaceholder()
            },
          }
        : {}),
      onToolStart: async (payload: {
        itemId?: string
        toolCallId?: string
        name?: string
        phase?: string
        args?: Record<string, unknown>
        detailMode?: "explain" | "raw"
      }) => {
        const toolName = payload.name?.trim()
        if (toolName === "inline_bot_presence") {
          return
        }

        botPresenceLifecycle.busy("running")
        if (!(streamViaEditMessage || progressPlaceholderEnabled)) return
        if (streamViaEditMessage || !agentActivityEnabled) await resetEditStreamOnBoundary()
        await pushInlineProgressPlaceholder(
          buildInlineProgressLineForEntry(
            {
              event: "tool",
              ...(payload.itemId !== undefined ? { itemId: payload.itemId } : {}),
              ...(payload.toolCallId !== undefined ? { toolCallId: payload.toolCallId } : {}),
              ...(toolName ? { name: toolName } : {}),
              ...(payload.phase !== undefined ? { phase: payload.phase } : {}),
              ...(payload.args !== undefined ? { args: payload.args } : {}),
            },
            payload.detailMode ? { detailMode: payload.detailMode } : undefined,
          ),
          {
            ...(toolName ? { toolName } : {}),
            startImmediately: true,
          },
        )
      },
      onApprovalEvent: async (payload: {
        phase?: string
        title?: string
        command?: string
        reason?: string
        message?: string
      }) => {
        if (payload.phase !== "requested") return
        botPresenceLifecycle.busy("waiting")
        if (!progressPlaceholderEnabled) return
        await pushInlineProgressPlaceholder(
          buildChannelProgressDraftLine({
            event: "approval",
            ...(payload.phase !== undefined ? { phase: payload.phase } : {}),
            ...(payload.title !== undefined ? { title: payload.title } : {}),
            ...(payload.command !== undefined ? { command: payload.command } : {}),
            ...(payload.reason !== undefined ? { reason: payload.reason } : {}),
            ...(payload.message !== undefined ? { message: payload.message } : {}),
          }),
          { startImmediately: true },
        )
      },
      ...(progressPlaceholderEnabled
        ? {
            onItemEvent: async (payload: {
              itemId?: string
              toolCallId?: string
              commandBearing?: boolean
              kind?: string
              title?: string
              name?: string
              phase?: string
              status?: string
              summary?: string
              progressText?: string
              meta?: string
            }) => {
              await pushInlineProgressPlaceholder(
                buildInlineProgressLineForEntry({
                  event: "item",
                  ...(payload.itemId !== undefined ? { itemId: payload.itemId } : {}),
                  ...(payload.toolCallId !== undefined ? { toolCallId: payload.toolCallId } : {}),
                  ...(payload.commandBearing !== undefined ? { commandBearing: payload.commandBearing } : {}),
                  ...(payload.kind !== undefined ? { itemKind: payload.kind } : {}),
                  ...(payload.title !== undefined ? { title: payload.title } : {}),
                  ...(payload.name !== undefined ? { name: payload.name } : {}),
                  ...(payload.phase !== undefined ? { phase: payload.phase } : {}),
                  ...(payload.status !== undefined ? { status: payload.status } : {}),
                  ...(payload.summary !== undefined ? { summary: payload.summary } : {}),
                  ...(payload.progressText !== undefined ? { progressText: payload.progressText } : {}),
                  ...(payload.meta !== undefined ? { meta: payload.meta } : {}),
                }),
              )
            },
            onPlanUpdate: async (payload: {
              phase?: string | undefined
              title?: string | undefined
              explanation?: string | undefined
              steps?: AgentPlanStep[] | undefined
              source?: string | undefined
            }) => {
              if (payload.phase !== "update") return
              await pushInlineProgressPlaceholder(
                buildChannelProgressDraftLine({
                  event: "plan",
                  ...(payload.phase !== undefined ? { phase: payload.phase } : {}),
                  ...(payload.title !== undefined ? { title: payload.title } : {}),
                  ...(payload.explanation !== undefined ? { explanation: payload.explanation } : {}),
                  ...(payload.steps !== undefined ? { steps: payload.steps } : {}),
                }),
              )
            },
            onCommandOutput: async (payload: {
              itemId?: string
              toolCallId?: string
              phase?: string
              title?: string
              name?: string
              status?: string
              exitCode?: number | null
            }) => {
              if (payload.phase !== "end") return
              await pushInlineProgressPlaceholder(
                buildChannelProgressDraftLine({
                  event: "command-output",
                  ...(payload.itemId !== undefined ? { itemId: payload.itemId } : {}),
                  ...(payload.toolCallId !== undefined ? { toolCallId: payload.toolCallId } : {}),
                  ...(payload.phase !== undefined ? { phase: payload.phase } : {}),
                  ...(payload.title !== undefined ? { title: payload.title } : {}),
                  ...(payload.name !== undefined ? { name: payload.name } : {}),
                  ...(payload.status !== undefined ? { status: payload.status } : {}),
                  ...(payload.exitCode !== undefined ? { exitCode: payload.exitCode } : {}),
                }),
              )
            },
            onPatchSummary: async (payload: {
              phase?: string
              title?: string
              name?: string
              added?: string[]
              modified?: string[]
              deleted?: string[]
              summary?: string
            }) => {
              if (payload.phase !== "end") return
              await pushInlineProgressPlaceholder(
                buildChannelProgressDraftLine({
                  event: "patch",
                  ...(payload.phase !== undefined ? { phase: payload.phase } : {}),
                  ...(payload.title !== undefined ? { title: payload.title } : {}),
                  ...(payload.name !== undefined ? { name: payload.name } : {}),
                  ...(payload.added !== undefined ? { added: payload.added } : {}),
                  ...(payload.modified !== undefined ? { modified: payload.modified } : {}),
                  ...(payload.deleted !== undefined ? { deleted: payload.deleted } : {}),
                  ...(payload.summary !== undefined ? { summary: payload.summary } : {}),
                }),
              )
            },
          }
        : {}),
      onCompactionStart: async () => {
        botPresenceLifecycle.busy("review")
        if (!(streamViaEditMessage || progressPlaceholderEnabled)) return
        if (streamViaEditMessage || !agentActivityEnabled) await resetEditStreamOnBoundary()
        await pushInlineProgressPlaceholder("Compacting context", {
          startImmediately: true,
        })
      },
      onCompactionEnd: async () => {
        botPresenceLifecycle.busy("running")
        if (!(streamViaEditMessage || progressPlaceholderEnabled)) return
        if (streamViaEditMessage || !agentActivityEnabled) await resetEditStreamOnBoundary()
        await pushInlineProgressPlaceholder("Resuming", {
          startImmediately: true,
        })
      },
      ...(suppressDefaultToolProgressMessages
        ? { suppressDefaultToolProgressMessages: true }
        : {}),
      ...(progressPlaceholderEnabled
        ? { allowProgressCallbacksWhenSourceDeliverySuppressed: true }
        : {}),
      ...(typeof disableBlockStreaming === "boolean" ? { disableBlockStreaming } : {}),
    }

    const endActiveThreadRoute = beginInlineActiveThreadRoute(activeThreadRoute)
    // /stop aborts the host's run, not this channel's lifetime signal. Observe
    // only the run admitted for this turn through the public runtime event API.
    const unsubscribeActivity = agentActivityEnabled ? core.events?.onAgentEvent((event) => {
      if (!activityRunId || event.runId !== activityRunId || event.stream !== "lifecycle") return
      if (event.data.phase === "start") {
        resetActivityTerminal()
        return
      }
      const outcome = activityLifecycleOutcome(event.data)
      if (outcome) {
        activityHostOutcome = outcome
        activityHostEndedAt = performance.now()
        resolveActivityTerminal?.()
      }
    }) : undefined
    let activityTurnCompleted = false
    try {
      let skippedNonSilent = false
      let skippedSilently = false
      let failedNonSilent = false
      let dispatchError: unknown = null
      let dispatchResult: InlineDispatchResult = {}
      let streamedFinalEditRejected = false
      let undeliveredFinalText = ""
      let undeliveredFinalActions: MessageActions | undefined
      try {
        const dispatch = await dispatchInlineReplyWithSessionInitRetry({
          shouldRetry: () => !abortSignal.aborted && !delivered && !skippedNonSilent && !failedNonSilent,
          onRetry: (retry, delayMs) => {
            log?.warn(
              `[${account.accountId}] AGENT_DISPATCH_TRACE phase=session_init_conflict_retry ` +
              `retry=${retry} delay_ms=${delayMs}`,
            )
          },
          run: () => core.channel.reply.dispatchReplyWithBufferedBlockDispatcher({
            ctx: ctxPayload,
            cfg,
            dispatcherOptions: {
            ...dispatcherPipelineOptions,
            ...buildInlineTypingDispatcherOptions(typingCallbacks),
            deliver: async (
              payload: InlineReplyPayload,
              info?: InlineDispatchReplyInfo,
            ) => {
              if (abortSignal.aborted) return inlineReplyDeliveryResult(false)
              let payloadVisible = false
              const markPayloadVisible = () => {
                delivered = true
                payloadVisible = true
              }
              const finishPayload = () => {
                // Later tool work belongs below this conversational reply.
                if (agentActivityEnabled && payloadVisible && progressState.closing) {
                  progressState.closing = false
                  progressState.lines = []
                  progressDraftGate = createChannelProgressDraftGate({ onStart: renderInlineProgressPlaceholder })
                }
                return inlineReplyDeliveryResult(payloadVisible)
              }
              await activeThreadRoute.adoption
              const presenceSignal = resolveInlineBotPresenceSignal(payload)
              if (presenceSignal) {
                botPresenceLifecycle.express(presenceSignal)
              }

              const visiblePayload = resolveInlineChatVisibleReplyPayload(payload)
              if (!visiblePayload) return finishPayload()
              await drainActivityOperations()
              const payloadIsError = visiblePayload.isError === true || info?.kind === "error"
              await cleanupInlineProgressPlaceholder(payloadIsError ? "failure" : "success")
              // A hand-back needs no answer, so a failed run has nothing to report.
              // Runtimes that treat a silent reply as an empty response would
              // otherwise post their error into the shared chat.
              // Silence is a correct answer to a hand-back, but OpenClaw requires a
              // group reply and posts its "couldn't produce a reply" notice instead.
              if (botHandBack && (payloadIsError || isInlineHostNoReplyFallback(visiblePayload.text))) {
                log?.warn(
                  `[${account.accountId}] inline: dropped error reply to bot hand-back chat=${String(deliveryChatId)} msg=${String(msg.id)}`,
                )
                return finishPayload()
              }

              const payloadRecord = visiblePayload as InlineReplyPayload & {
                interactive?: unknown
                presentation?: unknown
                presentationTextMode?: "fallback"
              }
              const rawText =
                resolveInlineInteractiveTextFallback({
                  text: visiblePayload.text,
                  interactive: payloadRecord.interactive,
                  presentation: payloadRecord.presentation,
                  presentationTextMode: payloadRecord.presentationTextMode,
                }) ??
                visiblePayload.text ??
                ""
              const mediaList = resolveInlinePayloadMediaUrls(visiblePayload)
              const outboundText = sanitizeInlineDeliveryText(
                rewriteNumericMentionsToUsernames(rawText, senderProfilesById),
              )
              const suppliedOutboundActions = resolveInlineReplyActions(
                visiblePayload as Record<string, unknown>,
              )
              if (suppliedOutboundActions !== undefined) {
                editStreamState.latestActions = suppliedOutboundActions
              }
              const outboundActions = suppliedOutboundActions ?? editStreamState.latestActions
              const infoKind = typeof info?.kind === "string" ? info.kind : undefined

              let replyToMsgId: bigint | undefined
              if (visiblePayload.replyToId != null) {
                try {
                  replyToMsgId = canReplyToSourceMessage ? BigInt(visiblePayload.replyToId) : undefined
                } catch {
                  // ignore
                }
              }
              if (replyToMsgId == null && canReplyToSourceMessage && botAskedThisBot) {
                replyToMsgId = msg.id
              }

              const rememberSent = (messageId: bigint | null | undefined) => {
                rememberSentBotMessage({
                  chatId: deliveryChatId,
                  messageId,
                  replyThreadContext: deliveryReplyThreadContext,
                })
              }

              const sendTextFallback = async (
                text: string,
                includeReplyTo: boolean,
                includeActions: boolean,
              ): Promise<void> => {
                const outbound = sanitizeInlineDeliveryText(text)
                if (!outbound.trim()) return
                try {
                  const sent = await sendMessage({
                    chatId: deliveryChatId,
                    text: outbound,
                    ...(includeReplyTo && replyToMsgId != null ? { replyToMsgId } : {}),
                    ...(includeActions && outboundActions !== undefined ? { actions: outboundActions } : {}),
                    parseMarkdown,
                  })
                  markPayloadVisible()
                  try {
                    rememberSent(sent.messageId)
                  } catch (error) {
                    runtime.error?.(`inline text delivery bookkeeping failed: ${String(error)}`)
                  }
                } catch (error) {
                  if (!isInlineSendOutcomeUnknown(error)) throw error
                  markPayloadVisible()
                  runtime.error?.(
                    `inline text delivery outcome is unknown; suppressing duplicate (${String(error)})`,
                  )
                }
              }

              const updateStreamedMessage = async (text: string, actions?: MessageActions): Promise<boolean> => {
                await settleEditStream(true)
                if (editStreamState.messageId == null) return false
                const nextText = sanitizeInlineDeliveryText(text).trim()
                const textForEdit = nextText || editStreamState.accumulatedText
                if (!textForEdit && actions === undefined) return true
                const shouldSkipTextUpdate =
                  !editStreamState.failed && textForEdit === editStreamState.accumulatedText
                if (shouldSkipTextUpdate && actions === undefined) return true

                undeliveredFinalText = textForEdit
                undeliveredFinalActions = actions
                let result: Awaited<ReturnType<typeof client.invokeRaw>>
                try {
                  result = await client.invokeRaw(Method.EDIT_MESSAGE, {
                    oneofKind: "editMessage",
                    editMessage: {
                      messageId: editStreamState.messageId,
                      peerId: buildChatPeer(deliveryChatId),
                      text: textForEdit,
                      parseMarkdown,
                      ...(actions !== undefined ? { actions } : {}),
                    },
                  })
                } catch (error) {
                  // A definite edit rejection still needs the final answer via
                  // the ordinary send path. An unknown commit keeps the one
                  // existing bubble and must not create a duplicate.
                  streamedFinalEditRejected = !isInlineCommitOutcomeUnknown(error)
                  throw error
                }
                if (result.oneofKind !== "editMessage") {
                  streamedFinalEditRejected = true
                  throw new Error(
                    `inline edit stream: expected editMessage result, got ${String(result.oneofKind)}`,
                  )
                }
                if (!shouldSkipTextUpdate) {
                  editStreamState.accumulatedText = textForEdit
                  editStreamState.lastPartialText = textForEdit
                }
                if (actions !== undefined) {
                  editStreamState.actionsFingerprint = fingerprintInlineMessageActions(actions)
                  editStreamState.latestActions = actions
                }
                editStreamState.failed = false
                streamedFinalEditRejected = false
                undeliveredFinalText = ""
                undeliveredFinalActions = undefined
                return true
              }

              if (streamViaEditMessage) {
                await settleEditStream(true)
              }

              if (mediaList.length === 0) {
                if (shouldEditCallbackTargetInPlace && editStreamState.messageId != null) {
                  const callbackEditActions = outboundActions ?? { rows: [] }
                  if (!outboundText.trim() && outboundActions === undefined) {
                    return finishPayload()
                  }
                  await updateStreamedMessage(outboundText, callbackEditActions)
                  markPayloadVisible()
                  publishStatus({ lastOutboundAt: Date.now() })
                  return finishPayload()
                }
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
                    markPayloadVisible()
                    return finishPayload()
                  }
                  await updateStreamedMessage(editStreamState.finalTextAccumulator, outboundActions)
                  markPayloadVisible()
                  if (infoKind === "final") {
                    finalDeliveredForCurrentAssistantMessage = true
                  }
                  publishStatus({ lastOutboundAt: Date.now() })
                  return finishPayload()
                }
                if (!outboundText.trim()) return finishPayload()
                if (streamViaEditMessage && editStreamState.initialSendMayHaveLanded) {
                  markPayloadVisible()
                  return finishPayload()
                }
                await sendTextFallback(outboundText, true, true)
                publishStatus({ lastOutboundAt: Date.now() })
                return finishPayload()
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
                  isFirst &&
                  !(streamViaEditMessage && (
                    editStreamState.messageId != null || editStreamState.initialSendMayHaveLanded
                  ))
                    ? outboundText
                    : ""
                const partialDelivery = partialMediaDeliveries.get(mediaUrl)
                if (partialDelivery) {
                  const result = await partialDelivery
                  if (result.sent) {
                    markPayloadVisible()
                    if (result.commitOutcomeUnknown) {
                      // The first send may already be visible. Do not turn an
                      // unknown receipt into a duplicate caption/media bubble.
                      continue
                    }
                    const mediaText = result.usedUrlFallback
                      ? caption
                        ? `${caption}\n\nAttachment: ${mediaUrl}`
                        : `Attachment: ${mediaUrl}`
                      : caption
                    const shouldUpdateEarlyMedia =
                      isFirst &&
                      (Boolean(mediaText.trim()) ||
                        (shouldAttachActionsToMedia && outboundActions !== undefined))
                    if (shouldUpdateEarlyMedia && result.messageId != null) {
                      try {
                        const update = await client.invokeRaw(Method.EDIT_MESSAGE, {
                          oneofKind: "editMessage",
                          editMessage: {
                            messageId: result.messageId,
                            peerId: buildChatPeer(deliveryChatId),
                            text: mediaText,
                            parseMarkdown,
                            ...(shouldAttachActionsToMedia && outboundActions !== undefined
                              ? { actions: outboundActions }
                              : {}),
                          },
                        })
                        if (update.oneofKind !== "editMessage") {
                          throw new Error(
                            `inline early media: expected editMessage result, got ${String(update.oneofKind)}`,
                          )
                        }
                      } catch (error) {
                        runtime.error?.(
                          `inline early media finalization failed (${String(error)})`,
                        )
                        if (!isInlineCommitOutcomeUnknown(error)) {
                          await sendTextFallback(
                            caption || `Attachment: ${mediaUrl}`,
                            false,
                            shouldAttachActionsToMedia,
                          )
                        }
                      }
                    } else if (shouldUpdateEarlyMedia) {
                      await sendTextFallback(
                        caption || `Attachment: ${mediaUrl}`,
                        false,
                        shouldAttachActionsToMedia,
                      )
                    }
                    continue
                  }
                }
                let media: Awaited<ReturnType<typeof uploadInlineMediaFromUrl>>
                try {
                  media = await uploadInlineMediaFromUrl({
                    client,
                    cfg,
                    accountId: account.accountId,
                    mediaUrl,
                  })
                } catch (error) {
                  runtime.error?.(`inline media upload failed; falling back to url text (${String(error)})`)
                  const fallbackText = caption
                    ? `${caption}\n\nAttachment: ${mediaUrl}`
                    : `Attachment: ${mediaUrl}`
                  await sendTextFallback(fallbackText, isFirst, isFirst)
                  continue
                }

                try {
                  const sent = await sendMessage({
                    chatId: deliveryChatId,
                    ...(caption ? { text: caption } : {}),
                    media,
                    ...(isFirst && replyToMsgId != null ? { replyToMsgId } : {}),
                    ...(shouldAttachActionsToMedia && outboundActions !== undefined
                      ? { actions: outboundActions }
                      : {}),
                    ...(caption ? { parseMarkdown } : {}),
                  })
                  markPayloadVisible()
                  try {
                    rememberSent(sent.messageId)
                  } catch (error) {
                    runtime.error?.(`inline media delivery bookkeeping failed: ${String(error)}`)
                  }
                } catch (error) {
                  if (isInlineSendOutcomeUnknown(error)) {
                    markPayloadVisible()
                    runtime.error?.(
                      `inline media delivery outcome is unknown; suppressing duplicate (${String(error)})`,
                    )
                    continue
                  }
                  runtime.error?.(`inline media send failed; falling back to url text (${String(error)})`)
                  const fallbackText = caption
                    ? `${caption}\n\nAttachment: ${mediaUrl}`
                    : `Attachment: ${mediaUrl}`
                  await sendTextFallback(fallbackText, isFirst, isFirst)
                }
              }

              publishStatus({ lastOutboundAt: Date.now() })
              return finishPayload()
            },
            onSkip: (_payload, info) => {
              if (info?.reason === "silent") {
                skippedSilently = true
              } else {
                skippedNonSilent = true
              }
            },
            onError: (err, info) => {
              failedNonSilent = true
              botPresenceLifecycle.fail()
              runtime.error?.(`inline ${info?.kind ?? "final"} reply failed: ${String(err)}`)
            },
          },
            replyOptions,
          }),
        })
        dispatchResult = normalizeInlineDispatchResult(dispatch.result)
        if (dispatch.retries > 0) {
          log?.info(
            `[${account.accountId}] AGENT_DISPATCH_TRACE phase=session_init_conflict_recovered ` +
            `retries=${dispatch.retries}`,
          )
        }
      } catch (error) {
        dispatchError = error
        botPresenceLifecycle.fail()
        runtime.error?.(`inline dispatch failed: ${String(error)}`)
      }

      if (deferredTypingCleanup) {
        deferredTypingCleanup = false
        runTypingCleanup()
      }

      await settleEditStream(false)
      await settlePartialMediaDeliveries()
      if (partialMediaDelivered) {
        delivered = true
      }
      await drainActivityOperations()
      await settleActivityTerminal()
      const finalActivityOutcome = (): ActivityOutcome =>
        abortSignal.aborted || activityHostOutcome === "cancelled" ? "cancelled"
          : dispatchError != null || failedNonSilent || activityHostOutcome === "failure" ? "failure" : "success"
      const closedOutcome = finalActivityOutcome()
      await cleanupInlineProgressPlaceholder(closedOutcome, activityHostEndedAt)
      // An event can arrive at the bounded wait's deadline while the terminal
      // edit is in flight. Reconcile it against the same frozen row before exit.
      if (finalActivityOutcome() !== closedOutcome) {
        await cleanupInlineProgressPlaceholder(finalActivityOutcome(), activityHostEndedAt)
      }
      if (
        !delivered &&
        streamViaEditMessage &&
        (editStreamState.messageId != null || editStreamState.initialSendMayHaveLanded) &&
        !streamedFinalEditRejected
      ) {
        delivered = true
      }
      // Use the host's settled receipt and delivery counts, as native channels do.
      // A queued final alone is not proof of delivery after an error callback.
      const hostDeliveredReply = hasVisibleInboundReplyDispatch(
        { ...dispatchResult, queuedFinal: false },
        { fallbackDelivered: dispatchResult.noVisibleReplyFallbackDelivered === true },
      )
      const hostHandledTurn = hasFinalInboundReplyDispatch(dispatchResult) || hostDeliveredReply
      const deferredToActiveRun = dispatchResult.deferredToActiveRun != null
      const deliberateSilence =
        skippedSilently || dispatchResult.deliberateSilentTerminalReply === true
      const skipFallbackSuppressed =
        dispatchResult.sourceReplyDeliveryMode === "message_tool_only"
      const hostRequestedNoVisibleRecovery =
        dispatchResult.noVisibleReplyFallbackEligible === true
      const explicitFailure = dispatchError != null || failedNonSilent
      if (
        !abortSignal.aborted && dispatchResult.sendPolicyDenied !== true &&
        !delivered && !hostDeliveredReply && !deferredToActiveRun && !adoptingThread &&
        (explicitFailure ||
          (!hostHandledTurn &&
            !deliberateSilence && !skipFallbackSuppressed &&
            (skippedNonSilent || hostRequestedNoVisibleRecovery)))
      ) {
        botPresenceLifecycle.fail()
        const fallbackText =
          undeliveredFinalText.trim()
            ? undeliveredFinalText
            : dispatchError != null
            ? INLINE_REQUEST_ERROR_FALLBACK
            : EMPTY_RESPONSE_FALLBACK
        const sent = await sendMessage({
          chatId: deliveryChatId,
          text: fallbackText,
          ...(defaultReplyToMsgId != null ? { replyToMsgId: defaultReplyToMsgId } : {}),
          ...(undeliveredFinalActions !== undefined ? { actions: undeliveredFinalActions } : {}),
          parseMarkdown,
        })
        rememberSentBotMessage({
          chatId: deliveryChatId,
          messageId: sent.messageId,
          replyThreadContext: deliveryReplyThreadContext,
        })
        publishStatus({ lastOutboundAt: Date.now() })
      }
      activityTurnCompleted = true
    } finally {
      unsubscribeActivity?.()
      endActiveThreadRoute()
      if (agentActivityEnabled && !activityTurnCompleted && !abortSignal.aborted) {
        await cleanupInlineProgressPlaceholder("failure")
      }
      if (abortSignal.aborted) {
        if (agentActivityEnabled) await cleanupInlineProgressPlaceholder("cancelled")
        runTypingCleanup()
        botPresenceLifecycle.cleanup()
      }
      if (progressState.pendingClosures.size > 0) {
        await cleanupInlineProgressPlaceholder()
      }
      if (adoptedThreadThisTurn) {
        await sendDeliveryTyping(deliveryChatId, false).catch((error) =>
          runtime.error?.(`inline adopted thread typing cleanup failed: ${String(error)}`))
        botPresenceLifecycle.cleanup()
      }
      await setParentThreadCreationTyping(false)
      if (!abortSignal.aborted && callbackActionEvent && !callbackActionAnswered) {
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

  const inlineDebounceMsOverride = resolveInlineInboundDebounceMsOverride(account.config)
  const { debouncer: inboundDebouncer } = createChannelInboundDebouncer<InlineDebounceEntry>({
    cfg,
    channel: CHANNEL_ID,
    ...(inlineDebounceMsOverride !== undefined
      ? { debounceMsOverride: inlineDebounceMsOverride }
      : {}),
    serializeImmediate: true,
    buildKey: (entry) =>
      buildInlineDebounceKey({
        accountId: account.accountId,
        chatId: entry.chatId,
        senderId: entry.msg.fromId,
      }),
    shouldDebounce: (entry) => {
      const content = summarizeInlineMessageContent(entry.msg)
      return shouldDebounceTextInbound({
        text: buildInlineInboundBodyText(content),
        cfg,
        hasMedia: Boolean(content.media || content.attachments.length > 0),
        ...(botUsername ? { commandOptions: { botUsername } } : {}),
      })
    },
    onFlush: (entries, createFlush) => createFlush({
      dispatch: async () => {
        const last = entries.at(-1)
        if (!last) return

        if (entries.length === 1) {
          await handleInboundNow({
            chatId: last.chatId,
            msg: last.msg,
          })
          return
        }

        const combinedText = entries
          .map((entry) => buildInlineInboundBodyText(summarizeInlineMessageContent(entry.msg)))
          .filter(Boolean)
          .join("\n")
        if (!combinedText.trim()) return

        await handleInboundNow({
          chatId: last.chatId,
          msg: buildSyntheticInlineTextMessage({
            base: last.msg,
            text: combinedText,
            mentioned: entries.some((entry) => entry.msg.mentioned === true),
          }),
          messageIds: entries.map((entry) => String(entry.msg.id)),
          rawBodyOverride: combinedText,
        })
      },
    }),
    onError: (err, items) => {
      runtime.error?.(`inline debounce flush failed: ${String(err)}`)
      const chatId = items[0]?.chatId
      if (chatId == null) return
      void sendMessage({
        chatId,
        text: INLINE_DEBOUNCE_ERROR_FALLBACK,
        parseMarkdown: account.config.parseMarkdown ?? true,
      })
        .then(() => {
          publishStatus({ lastOutboundAt: Date.now() })
        })
        .catch((sendErr) => {
          runtime.error?.(`inline debounce fallback send failed: ${String(sendErr)}`)
        })
    },
  })

  const voiceTranscriptWaitMs = resolveInlineVoiceTranscriptWaitMs(account.config)
  const pendingVoiceMessages = new Map<string, InlinePendingVoiceMessage>()
  const suppressedVoiceMessageEditTimeouts = new Map<string, ReturnType<typeof setTimeout>>()
  const pendingInboundTasks = new Set<Promise<void>>()
  const inboundTaskChains = new Map<string, Promise<void>>()

  const isAuthorizedInlineControlActor = async (params: {
    chatId: bigint
    actorUserId: bigint
    resolvedContext?: InlineSystemEventContext
  }): Promise<boolean> => {
    const senderId = String(params.actorUserId)

    let chatInfo: CachedChatInfo
    if (params.resolvedContext) {
      chatInfo = params.resolvedContext.chatInfo
    } else {
      try {
        chatInfo = await resolveChatInfo(client, chatCache, params.chatId)
      } catch (err) {
        publishStatus({ lastError: `getChat failed: ${String(err)}` })
        return false
      }
    }

    let conversationKind = params.resolvedContext?.conversationKind ?? chatInfo.kind
    let isGroup = conversationKind !== "direct"
    let effectiveChatId = params.resolvedContext?.effectiveChatId
    if (effectiveChatId == null) {
      const replyThreadsEnabled = isInlineReplyThreadsEnabled({ cfg, accountId: account.accountId })
      let replyThreadContextFailed = false
      const replyThreadContext = await resolveInlineInboundReplyThreadContext({
        replyThreadsEnabled,
        client,
        chatId: params.chatId,
        chatInfo,
        chatCache,
        useCachedChatMetadata: true,
      }).catch((err) => {
        publishStatus({ lastError: `getChat (abort reply thread) failed: ${String(err)}` })
        replyThreadContextFailed = true
        return null
      })
      if (replyThreadContextFailed && chatInfo.parentChatId != null) return false
      effectiveChatId = replyThreadContext?.parentChatId ?? params.chatId
      conversationKind = replyThreadContext?.parentChatKind ?? chatInfo.kind
      isGroup = conversationKind !== "direct"
    }
    const dmPolicy = account.config.dmPolicy ?? "pairing"
    const defaultGroupPolicy = cfg.channels?.defaults?.groupPolicy
    const groupPolicy = account.config.groupPolicy ?? defaultGroupPolicy ?? INLINE_DEFAULT_GROUP_POLICY

    if (!isGroup && dmPolicy === "disabled") return false
    if (isGroup && groupPolicy === "disabled") return false

    const configAllowFrom = await resolveInlineAllowlist({
      cfg,
      accountId: account.accountId,
      entries: account.config.allowFrom,
      senderId,
    })
    const storeAllowFrom = await core.channel.pairing
      .readAllowFromStore({
        channel: CHANNEL_ID,
        accountId: account.accountId,
      })
      .catch(() => [])
    const effectiveAllowFrom = [...configAllowFrom, ...normalizeAllowlist(storeAllowFrom)].filter(Boolean)

    if (!isGroup) {
      return dmPolicy === "open" || allowlistMatch({ allowFrom: effectiveAllowFrom, senderId })
    }

    const groupSenderAllowlist = await resolveInlineGroupSenderAllowlist({
      cfg,
      account,
      groupId: String(effectiveChatId),
      senderId,
    })
    if (groupPolicy === "allowlist") {
      const groupAccess = resolveInlineGroupAccessPolicy({
        cfg,
        accountId: account.accountId,
        groupId: String(effectiveChatId),
        hasGroupAllowFrom: groupSenderAllowlist.raw.length > 0,
        groupPolicy,
      })
      if (groupAccess.allowlistEnabled && !groupAccess.allowed) return false
      if (
        groupSenderAllowlist.raw.length > 0 &&
        !allowlistMatch({ allowFrom: groupSenderAllowlist.expanded, senderId })
      ) {
        return false
      }
    }

    const allowTextCommands = core.channel.commands.shouldHandleTextCommands({
      cfg,
      surface: CHANNEL_ID,
      commandSource: "text",
    })
    if (!allowTextCommands) return false

    const effectiveGroupAllowFrom = groupSenderAllowlist.expanded.filter(Boolean)
    const effectiveGroupCommandAllowFrom = effectiveGroupAllowFrom
    const senderAllowedForCommands = allowlistMatch({
      allowFrom: effectiveGroupCommandAllowFrom,
      senderId,
    })
    const commandGate = resolveControlCommandGate({
      useAccessGroups: resolveUseAccessGroups(cfg),
      authorizers: [
        {
          configured: effectiveGroupCommandAllowFrom.length > 0,
          allowed: senderAllowedForCommands,
        },
      ],
      allowTextCommands,
      hasControlCommand: true,
    })

    return await resolveInlineCommandAuthorized({
      cfg,
      accountId: account.accountId,
      isGroup: true,
      chatId: String(effectiveChatId),
      senderId,
      commandAuthorized: commandGate.commandAuthorized,
    })
  }

  const isAuthorizedInlineAbortMessage = async (entry: InlineDebounceEntry): Promise<boolean> => {
    if (!isInlineAbortRequestMessage(entry.msg, botUsername, meId) || entry.msg.fromId == null) return false
    return await isAuthorizedInlineControlActor({
      chatId: entry.chatId,
      actorUserId: entry.msg.fromId,
    })
  }

  type OpenClawBotSettingsModelCatalog = {
    options: OpenClawBotChatSettingsOption[]
    didLoad: boolean
  }
  // Provider auth discovery can invoke host-specific credential paths. Keep
  // repeated panel opens and unrelated mutations off that slow path while the
  // live current model is still injected into every document below.
  const botSettingsModelCatalogSuccessCacheMs = 5 * 60_000
  const botSettingsModelCatalogFailureCacheMs = 5_000
  const botSettingsModelCatalogCache = new Map<string, {
    expiresAt: number
    catalog: OpenClawBotSettingsModelCatalog
  }>()
  const botSettingsModelCatalogLoads = new Map<
    string,
    Promise<OpenClawBotSettingsModelCatalog>
  >()

  const loadOpenClawBotSettingsModelCatalog = async (params: {
    cfg: OpenClawConfig
    agentId: string
  }): Promise<OpenClawBotSettingsModelCatalog> => {
    const loadCatalog = async (): Promise<OpenClawBotSettingsModelCatalog> => {
      const options = new Map<string, OpenClawBotChatSettingsOption>()
      // OpenClaw 2026.8 owns auth-aware catalog visibility, route compatibility,
      // aliases, and configured-model projection in this SDK helper.
      const { byProvider, providers } = await buildModelsProviderData(
        params.cfg,
        params.agentId,
      )
      for (const provider of [...providers].sort()) {
        for (const model of [...(byProvider.get(provider) ?? [])].sort()) {
          const value = `${provider}/${model}`
          options.set(value, { value, label: value })
          if (options.size >= 100) {
            return { options: [...options.values()], didLoad: true }
          }
        }
      }
      return { options: [...options.values()], didLoad: true }
    }

    let timeout: ReturnType<typeof setTimeout> | undefined
    try {
      return await Promise.race([
        loadCatalog(),
        new Promise<never>((_, reject) => {
          timeout = setTimeout(() => reject(new Error("model list timed out")), 5_000)
        }),
      ])
    } catch (error) {
      log?.warn(`inline agent settings model list unavailable: ${String(error)}`)
      return { options: [], didLoad: false }
    } finally {
      if (timeout) clearTimeout(timeout)
    }
  }

  const resolveOpenClawBotSettingsModelOptions = async (params: {
    cfg: OpenClawConfig
    agentId: string
    currentModel: string
  }): Promise<OpenClawBotChatSettingsOption[]> => {
    const startedAt = Date.now()
    const cached = botSettingsModelCatalogCache.get(params.agentId)
    let catalog: OpenClawBotSettingsModelCatalog
    let cacheResult: "hit" | "miss" | "shared"
    if (cached && cached.expiresAt > Date.now()) {
      catalog = cached.catalog
      cacheResult = "hit"
    } else {
      let load = botSettingsModelCatalogLoads.get(params.agentId)
      cacheResult = load ? "shared" : "miss"
      if (!load) {
        load = loadOpenClawBotSettingsModelCatalog(params)
        botSettingsModelCatalogLoads.set(params.agentId, load)
        const currentLoad = load
        const clearLoad = () => {
          if (botSettingsModelCatalogLoads.get(params.agentId) === currentLoad) {
            botSettingsModelCatalogLoads.delete(params.agentId)
          }
        }
        load.then(clearLoad, clearLoad)
      }
      catalog = await load
      botSettingsModelCatalogCache.set(params.agentId, {
        expiresAt: Date.now() + (
          catalog.options.length > 0
            ? botSettingsModelCatalogSuccessCacheMs
            : botSettingsModelCatalogFailureCacheMs
        ),
        catalog,
      })
    }

    const options = new Map<string, OpenClawBotChatSettingsOption>()
    const currentModelAvailable = catalog.options.some(
      (option) => option.value === params.currentModel,
    )
    options.set(params.currentModel, {
      value: params.currentModel,
      label: params.currentModel,
      ...(catalog.didLoad && !currentModelAvailable ? { disabled: true } : {}),
    })
    for (const option of catalog.options) {
      options.set(option.value, option)
      if (options.size >= 100) break
    }
    log?.info(
      `[${account.accountId}] AGENT_SETTINGS_TRACE phase=model_catalog cache=${cacheResult} ` +
      `options=${options.size} elapsed_ms=${Date.now() - startedAt}`,
    )
    return [...options.values()]
  }

  const resolveOpenClawBotSettingsReasoningOptions = async (params: {
    cfg: OpenClawConfig
    provider: string
    model: string
    currentLevel: string
  }): Promise<OpenClawBotChatSettingsOption[]> => {
    const command = findInlineNativeCommandFromBody("/think")
    const menu = command
      ? await resolveCommandArgMenuAsync({
          command,
          cfg: params.cfg,
          provider: params.provider,
          model: params.model,
        })
      : null
    const options = new Map<string, OpenClawBotChatSettingsOption>()
    options.set(params.currentLevel, { value: params.currentLevel, label: params.currentLevel })
    for (const choice of menu?.choices ?? []) {
      options.set(choice.value, { value: choice.value, label: choice.label })
    }
    return [...options.values()]
  }

  type ResolvedOpenClawBotSettings = {
    context: OpenClawBotChatSettingsContext
    ingress?: InlineSystemEventContext
  }

  const resolveOpenClawBotSettings = async (params: {
    chatId: bigint
    actorUserId: bigint
    eventKind: string
    modelOptions?: OpenClawBotChatSettingsOption[]
    replyThreads?: "auto" | "on"
  }): Promise<ResolvedOpenClawBotSettings> => {
    const ingress = await resolveInlineSystemEventContext({
      chatId: params.chatId,
      senderId: params.actorUserId,
      eventKind: params.eventKind,
    })
    if (!ingress) {
      return {
        context: {
          scopeId: `chat:${String(params.chatId)}`,
          access: "guideOnly",
          replyThreads: "auto",
        },
      }
    }

    const canSetDefaultModel = await isAuthorizedInlineControlActor({
      ...params,
      resolvedContext: ingress,
    })
    const currentConfig = resolveInlineLiveConfig(core.config.current()) as OpenClawConfig
    const modelContext = await resolveInlineCommandMenuModelContext({
      cfg: currentConfig,
      agentId: ingress.agentId,
      sessionKey: ingress.sessionKey,
    })
    const defaultModel = resolveDefaultModelForAgent({
      cfg: currentConfig,
      agentId: ingress.agentId,
    })
    const provider = modelContext.provider ?? defaultModel.provider
    const model = modelContext.model ?? defaultModel.model
    const currentModel = provider ? `${provider}/${model}` : model
    const activeModel = modelContext.activeModel
      ? modelContext.activeProvider
        ? `${modelContext.activeProvider}/${modelContext.activeModel}`
        : modelContext.activeModel
      : undefined
    const defaultModelValue = defaultModel.provider
      ? `${defaultModel.provider}/${defaultModel.model}`
      : defaultModel.model
    const reasoningLevel = resolveInlineThinkMenuCurrentLevel({
      cfg: currentConfig,
      agentId: ingress.agentId,
      provider,
      model,
      ...(modelContext.thinkingLevel ? { thinkingLevel: modelContext.thinkingLevel } : {}),
    })
    const modelOptions = params.modelOptions ?? await resolveOpenClawBotSettingsModelOptions({
      cfg: currentConfig,
      agentId: ingress.agentId,
      currentModel,
    })
    const replyMode = params.replyThreads == null
      ? resolveInlineThreadReplyMode({
          cfg: currentConfig,
          accountId: account.accountId,
          groupId: String(ingress.effectiveChatId),
        })
      : undefined
    return {
      ingress,
      context: {
        scopeId: `${account.accountId}:${String(ingress.effectiveChatId)}:${ingress.sessionKey}`,
        access: "full",
        isReplyThread: ingress.isReplyThread,
        currentModel,
        ...(activeModel ? { activeModel } : {}),
        defaultModel: defaultModelValue,
        modelOptions,
        reasoningLevel,
        reasoningOptions: await resolveOpenClawBotSettingsReasoningOptions({
          cfg: currentConfig,
          provider,
          model,
          currentLevel: reasoningLevel,
        }),
        ...(ingress.conversationKind === "direct"
          ? {}
          : { following: isInlineDialogFollowing(ingress.chatInfo.dialogFollowMode) }),
        replyThreads: params.replyThreads ?? replyMode ?? "auto",
        canSetDefaultModel,
      },
    }
  }

  const dispatchOpenClawSettingsCommand = async (params: {
    ingress: InlineSystemEventContext
    actorUserId: bigint
    chatId: bigint
    requestId: bigint
    command: string
  }): Promise<string | undefined> => {
    // The reply dispatcher owns OpenClaw's live session snapshot and command-side
    // hooks. A direct session-store patch can update disk without changing the
    // running session, which is the mismatch this path exists to prevent.
    const currentConfig = resolveInlineLiveConfig(core.config.current()) as OpenClawConfig
    const isGroup = params.ingress.conversationKind !== "direct"
    const ctx = core.channel.reply.finalizeInboundContext({
      Body: params.command,
      BodyForAgent: params.command,
      BodyForCommands: params.command,
      RawBody: params.command,
      CommandBody: params.command,
      From: isGroup
        ? `inline:chat:${String(params.ingress.effectiveChatId)}`
        : `inline:${String(params.actorUserId)}`,
      To: `inline:${String(params.ingress.effectiveChatId)}`,
      SessionKey: params.ingress.sessionKey,
      AgentId: params.ingress.agentId,
      AccountId: account.accountId,
      ChatType: isGroup ? "group" : "direct",
      SenderId: String(params.actorUserId),
      MessageSid: `agent-settings:${String(params.requestId)}`,
      Provider: CHANNEL_ID,
      Surface: CHANNEL_ID,
      ...(botUsername ? { BotUsername: botUsername } : {}),
      ...(isGroup
        ? {
            GroupSubject: params.ingress.chatInfo.title ?? String(params.ingress.effectiveChatId),
            WasMentioned: true,
          }
        : {}),
      ...(params.ingress.isReplyThread
        ? {
            ParentSessionKey: resolveInlineParentSessionKeyCandidate(
              params.ingress.sessionKey,
              undefined,
            ),
            MessageThreadId: String(params.chatId),
            ThreadParentId: String(params.ingress.effectiveChatId),
          }
        : {}),
      CommandAuthorized: true,
      CommandSource: "text",
      CommandTurn: {
        kind: "text-slash",
        source: "text",
        authorized: true,
        body: params.command,
      },
      Timestamp: Date.now(),
      OriginatingChannel: CHANNEL_ID,
      OriginatingTo: `inline:${String(params.ingress.effectiveChatId)}`,
    })
    let replyText: string | undefined
    await core.channel.reply.dispatchReplyWithBufferedBlockDispatcher({
      ctx,
      cfg: currentConfig,
      dispatcherOptions: {
        deliver: async (payload: InlineReplyPayload) => {
          const text = payload.text?.replace(/\s+/gu, " ").trim()
          if (text) replyText = text.slice(0, 300)
        },
      },
    })
    return replyText
  }

  const setOpenClawSessionModel = async (params: {
    ingress: InlineSystemEventContext
    actorUserId: bigint
    chatId: bigint
    requestId: bigint
    selection: string
  }): Promise<void> => {
    const separator = params.selection.indexOf("/")
    if (separator <= 0 || separator >= params.selection.length - 1) {
      throw new OpenClawBotChatSettingsMutationError("Choose a model from the available list.")
    }
    const commandReply = await dispatchOpenClawSettingsCommand({
      ...params,
      command: `/model ${params.selection}`,
    })

    const currentConfig = resolveInlineLiveConfig(core.config.current()) as OpenClawConfig
    const applied = await resolveInlineCommandMenuModelContext({
      cfg: currentConfig,
      agentId: params.ingress.agentId,
      sessionKey: params.ingress.sessionKey,
    })
    const appliedValue = applied.model
      ? applied.provider
        ? `${applied.provider}/${applied.model}`
        : applied.model
      : ""
    if (appliedValue !== params.selection) {
      throw new OpenClawBotChatSettingsMutationError(
        commandReply
          ? summarizeOpenClawCommandFailure(commandReply)
          : "OpenClaw did not apply the requested session model.",
      )
    }
  }

  const setOpenClawSessionReasoning = async (
    ingress: InlineSystemEventContext,
    reasoningLevel: string,
  ): Promise<void> => {
    const currentConfig = resolveInlineLiveConfig(core.config.current()) as OpenClawConfig
    const storePath = resolveStorePath(currentConfig.session?.store, { agentId: ingress.agentId })
    await applySessionEntryPatch({
      agentId: ingress.agentId,
      sessionKey: ingress.sessionKey,
      storePath,
      fallbackEntry: { sessionId: ingress.sessionKey, updatedAt: Date.now() },
      preserveActivity: true,
      patch: { thinkingLevel: reasoningLevel },
    })
  }

  const setOpenClawDefaultModel = async (
    ingress: InlineSystemEventContext,
    selection: string,
  ): Promise<void> => {
    cfg = await mutateInlineLiveConfig(core.config as never, (draft: OpenClawConfig) => {
      setOpenClawAgentDefaultModel(draft, ingress.agentId, selection)
    })
  }

  const answerOpenClawBotSettingsRequest = async (event: {
    requestId: bigint
    chatId: bigint
    actorUserId: bigint
    version: number
  }): Promise<void> => {
    const startedAt = Date.now()
    log?.info(
      `[${account.accountId}] AGENT_SETTINGS_TRACE request=${String(event.requestId)} ` +
      `phase=request_start chat=${String(event.chatId)}`,
    )
    let response
    try {
      if (event.version !== OPENCLAW_BOT_CHAT_SETTINGS_VERSION) {
        response = openClawBotChatSettingsProblem(
          BotChatSettingsProblem_Code.UNAVAILABLE,
          "This OpenClaw version supports agent settings V1 only.",
        )
      } else {
        const resolved = await resolveOpenClawBotSettings({
          chatId: event.chatId,
          actorUserId: event.actorUserId,
          eventKind: "bot.chatSettings.request",
        })
        response = {
          result: {
            oneofKind: "document" as const,
            document: buildOpenClawBotChatSettingsDocument(resolved.context),
          },
        }
      }
    } catch (error) {
      runtime.error?.(`inline agent settings request failed: ${String(error)}`)
      response = openClawBotChatSettingsProblem(
        BotChatSettingsProblem_Code.FAILED,
        classifyOpenClawBotSettingsError(error) ?? "OpenClaw could not load settings.",
      )
    }
    await client.answerBotChatSettings({ requestId: event.requestId, response }).then(() => {
      log?.info(
        `[${account.accountId}] AGENT_SETTINGS_TRACE request=${String(event.requestId)} ` +
        `phase=request_answer result=${response.result.oneofKind} elapsed_ms=${Date.now() - startedAt}`,
      )
    }).catch(() => {
      log?.warn(
        `[${account.accountId}] AGENT_SETTINGS_TRACE request=${String(event.requestId)} ` +
        `phase=request_answer_failed elapsed_ms=${Date.now() - startedAt}`,
      )
    })
  }

  const answerOpenClawBotSettingsMutation = async (event: {
    requestId: bigint
    chatId: bigint
    actorUserId: bigint
    version: number
    itemId: string
    value?: import("@inline-chat/realtime-sdk").BotChatSettingsValue
    documentRevision: string
  }): Promise<void> => {
    const startedAt = Date.now()
    log?.info(
      `[${account.accountId}] AGENT_SETTINGS_TRACE request=${String(event.requestId)} ` +
      `phase=mutation_start chat=${String(event.chatId)} item=${event.itemId}`,
    )
    let response
    try {
      const resolved = await resolveOpenClawBotSettings({
        chatId: event.chatId,
        actorUserId: event.actorUserId,
        eventKind: "bot.chatSettings.item.invoke",
      })
      if (!resolved.ingress) {
        response = openClawBotChatSettingsProblem(
          BotChatSettingsProblem_Code.FAILED,
          "This chat is not available to OpenClaw.",
          buildOpenClawBotChatSettingsDocument(resolved.context),
        )
      } else {
        const ingress = resolved.ingress
        let appliedReplyThreads: "auto" | "on" | undefined
        response = await invokeOpenClawBotChatSetting({
          context: resolved.context,
          mutators: {
            setModel: (value) => setOpenClawSessionModel({
              ingress,
              actorUserId: event.actorUserId,
              chatId: event.chatId,
              requestId: event.requestId,
              selection: value,
            }),
            setDefaultModel: () => setOpenClawDefaultModel(ingress, resolved.context.currentModel ?? ""),
            setReasoningLevel: (value) => setOpenClawSessionReasoning(ingress, value),
            setFollowing: async (value) => {
              await updateInlineFollowMode({
                client,
                target: ingress.conversationKind === "direct"
                  ? { userId: event.actorUserId }
                  : { chatId: event.chatId },
                command: value ? "follow" : "unfollow",
              })
              const cached = chatCache.get(event.chatId)
              if (cached) {
                chatCache.set(event.chatId, {
                  ...cached,
                  dialogFollowMode: value ? DialogFollowMode.FOLLOWING : 2 as DialogFollowMode,
                })
              }
            },
            setReplyThreads: async (value) => {
              cfg = await mutateInlineLiveConfig(core.config as never, (draft: OpenClawConfig) => setInlineThreadReplyMode({
                draft,
                accountId: account.accountId,
                groupId: String(ingress.effectiveChatId),
                mode: value,
              }))
              appliedReplyThreads = value
            },
            resolveContext: async () => (await resolveOpenClawBotSettings({
              chatId: event.chatId,
              actorUserId: event.actorUserId,
              eventKind: "bot.chatSettings.refresh",
              ...(resolved.context.modelOptions
                ? { modelOptions: resolved.context.modelOptions }
                : {}),
              ...(appliedReplyThreads ? { replyThreads: appliedReplyThreads } : {}),
            })).context,
          },
          itemId: event.itemId,
          ...(event.value ? { value: event.value } : {}),
          documentRevision: event.documentRevision,
        })
      }
    } catch (error) {
      runtime.error?.(`inline agent settings update failed: ${String(error)}`)
      response = openClawBotChatSettingsProblem(
        BotChatSettingsProblem_Code.FAILED,
        error instanceof OpenClawBotChatSettingsMutationError
          ? error.message
          : classifyOpenClawBotSettingsError(error) ??
            "OpenClaw could not update this setting. Try again.",
      )
    }
    await client.answerBotChatSettings({ requestId: event.requestId, response }).then(() => {
      const result = response.result.oneofKind === "problem"
        ? `problem:${String(response.result.problem.code)}`
        : response.result.oneofKind
      log?.info(
        `[${account.accountId}] AGENT_SETTINGS_TRACE request=${String(event.requestId)} ` +
        `phase=mutation_answer chat=${String(event.chatId)} item=${event.itemId} ` +
        `result=${result} elapsed_ms=${Date.now() - startedAt}`,
      )
    }).catch(() => {
      log?.warn(
        `[${account.accountId}] AGENT_SETTINGS_TRACE request=${String(event.requestId)} ` +
        `phase=mutation_answer_failed chat=${String(event.chatId)} item=${event.itemId} ` +
        `elapsed_ms=${Date.now() - startedAt}`,
      )
    })
  }

  const scheduleInboundTask = (
    label: string,
    run: () => Promise<void>,
    options?: { serialKey?: string },
  ): void => {
    if (abortSignal.aborted) return
    let task: Promise<void>
    try {
      if (options?.serialKey) {
        const serialKey = options.serialKey
        const previous = inboundTaskChains.get(serialKey) ?? Promise.resolve()
        task = previous.catch(() => undefined).then(() => {
          if (!abortSignal.aborted) return run()
        })
        const settled = task.catch(() => undefined)
        inboundTaskChains.set(serialKey, settled)
        const cleanup = () => {
          if (inboundTaskChains.get(serialKey) === settled) {
            inboundTaskChains.delete(serialKey)
          }
        }
        settled.then(cleanup, cleanup)
      } else {
        task = run()
      }
    } catch (error) {
      const message = String(error)
      publishStatus({ lastError: message })
      runtime.error?.(`inline ${label} failed: ${message}`)
      return
    }

    const tracked = task
      .catch((error) => {
        const message = String(error)
        publishStatus({ lastError: message })
        runtime.error?.(`inline ${label} failed: ${message}`)
      })
      .finally(() => {
        pendingInboundTasks.delete(tracked)
      })
    pendingInboundTasks.add(tracked)
    void tracked
  }

  const enqueueInboundMessage = async (entry: InlineDebounceEntry): Promise<void> => {
    await inboundDebouncer.enqueue(entry)
  }

  const scheduleInboundMessage = (entry: InlineDebounceEntry): void => {
    // /approve and /stop act on the run that is already going in this chat.
    // Queued behind it, an approval waits for the very run it would unblock.
    if (isInlineOutOfBandCommandText(entry.msg.message)) {
      scheduleImmediateInboundMessage(
        { chatId: entry.chatId, msg: entry.msg },
        "inline control command dispatch",
      )
      return
    }
    scheduleInboundTask(
      "inbound dispatch",
      async () => {
        await enqueueInboundMessage(entry)
      },
      {
        serialKey: buildInlineInboundTaskKey({
          accountId: account.accountId,
          chatId: entry.chatId,
        }),
      },
    )
  }

  const cancelPendingInlineDebounce = (entry: InlineDebounceEntry): void => {
    const key = buildInlineDebounceKey({
      accountId: account.accountId,
      chatId: entry.chatId,
      senderId: entry.msg.fromId,
    })
    if (!key) return
    inboundDebouncer.cancelKey(key)
  }

  const suppressInlineVoiceMessageEdit = (key: string): void => {
    const existing = suppressedVoiceMessageEditTimeouts.get(key)
    if (existing) {
      clearTimeout(existing)
    }
    const timeout = setTimeout(() => {
      suppressedVoiceMessageEditTimeouts.delete(key)
    }, MAX_INLINE_VOICE_TRANSCRIPT_WAIT_MS)
    timeout.unref?.()
    suppressedVoiceMessageEditTimeouts.set(key, timeout)
  }

  const cancelPendingInlineVoiceMessages = (entry: InlineDebounceEntry): void => {
    for (const [key, pending] of pendingVoiceMessages) {
      if (pending.chatId !== entry.chatId || pending.msg.fromId !== entry.msg.fromId) {
        continue
      }
      pendingVoiceMessages.delete(key)
      clearTimeout(pending.timeout)
      suppressInlineVoiceMessageEdit(key)
    }
  }

  const scheduleImmediateInboundMessage = (
    input: InlineParsedInboundEvent,
    label = "priority inbound dispatch",
    options?: { serializeWithChat?: boolean },
  ): void => {
    scheduleInboundTask(
      label,
      async () => {
        await handleInboundNow(input)
      },
      options?.serializeWithChat
        ? {
            serialKey: buildInlineInboundTaskKey({
              accountId: account.accountId,
              chatId: input.chatId,
            }),
          }
        : undefined,
    )
  }

  const flushPendingVoiceMessage = async (params: {
    key: string
    msg?: Message
  }): Promise<boolean> => {
    const pending = pendingVoiceMessages.get(params.key)
    if (!pending) return false
    pendingVoiceMessages.delete(params.key)
    clearTimeout(pending.timeout)
    const msg = params.msg ?? pending.msg
    if (
      isInlineAbortRequestMessage(msg, botUsername, meId) &&
      await isAuthorizedInlineAbortMessage({ chatId: pending.chatId, msg })
    ) {
      cancelPendingInlineDebounce({ chatId: pending.chatId, msg })
      cancelPendingInlineVoiceMessages({ chatId: pending.chatId, msg })
      scheduleImmediateInboundMessage(
        { chatId: pending.chatId, msg },
        "priority voice transcript abort dispatch",
      )
      return true
    }
    scheduleInboundMessage({ chatId: pending.chatId, msg })
    return true
  }

  const holdInlineVoiceMessage = (params: {
    chatId: bigint
    msg: Message
  }): void => {
    const key = buildInlineVoicePendingKey({
      chatId: params.chatId,
      messageId: params.msg.id,
    })
    const existing = pendingVoiceMessages.get(key)
    if (existing) {
      clearTimeout(existing.timeout)
    }

    const timeout = setTimeout(() => {
      void flushPendingVoiceMessage({ key })
    }, voiceTranscriptWaitMs)
    timeout.unref?.()
    pendingVoiceMessages.set(key, {
      chatId: params.chatId,
      msg: params.msg,
      timeout,
    })
  }

  const handlePendingInlineVoiceEdit = async (params: {
    chatId: bigint
    msg: Message
  }): Promise<boolean> => {
    const key = buildInlineVoicePendingKey({
      chatId: params.chatId,
      messageId: params.msg.id,
    })
    if (suppressedVoiceMessageEditTimeouts.has(key)) return true
    if (!pendingVoiceMessages.has(key)) return false

    const transcript = extractInlineVoiceTranscriptText(params.msg)
    if (!transcript) return true

    return flushPendingVoiceMessage({
      key,
      msg: buildInlineTranscriptTextMessage({
        base: params.msg,
        text: transcript,
      }),
    })
  }

  const clearPendingInlineVoiceMessages = (): void => {
    for (const pending of pendingVoiceMessages.values()) {
      clearTimeout(pending.timeout)
    }
    pendingVoiceMessages.clear()
    for (const timeout of suppressedVoiceMessageEditTimeouts.values()) {
      clearTimeout(timeout)
    }
    suppressedVoiceMessageEditTimeouts.clear()
  }

  const drainInboundTasks = async (): Promise<void> => {
    let timer: ReturnType<typeof setTimeout> | undefined
    const drained = (async () => {
      while (pendingInboundTasks.size > 0) {
        await Promise.allSettled(pendingInboundTasks)
      }
    })()
    // Match native channel shutdown: cooperative runs receive cancellation;
    // a host callback that ignores it must not hold the gateway restart forever.
    let onAbort: (() => void) | undefined
    try {
      await Promise.race([
        drained,
        new Promise<void>((resolve) => {
          onAbort = () => {
            timer = setTimeout(() => {
              log?.warn(`[${account.accountId}] inline shutdown grace expired with pending inbound work`)
              resolve()
            }, 15_000)
          }
          if (abortSignal.aborted) onAbort()
          else abortSignal.addEventListener("abort", onAbort, { once: true })
        }),
      ])
    } finally {
      clearTimeout(timer)
      if (onAbort) abortSignal.removeEventListener("abort", onAbort)
    }
  }

  let coldBootDropped = 0
  let coldBootDropLoggedAt = 0
  const loop = (async () => {
    try {
      await client.consumeEvents(async (event) => {
        if (abortSignal.aborted) {
          unshareClient()
          await client.close()
          return
        }
        const rawEvent = event as Record<string, unknown>

        if (
          account.config.dropPendingOnColdBoot !== false &&
          INLINE_COLD_BOOT_GATED_EVENTS.has(event.kind) &&
          Number(rawEvent.date) > 0 &&
          Number(rawEvent.date) < INLINE_PROCESS_STARTED_AT_SECONDS - INLINE_COLD_BOOT_CLOCK_SKEW_SECONDS
        ) {
          coldBootDropped += 1
          const now = Date.now()
          if (now - coldBootDropLoggedAt >= INLINE_COLD_BOOT_DROP_LOG_INTERVAL_MS) {
            coldBootDropLoggedAt = now
            log?.info(
              `[${account.accountId}] inline: dropped ${coldBootDropped} update(s) recorded before this gateway started`,
            )
          }
          return
        }

        if (event.kind === "bot.chatSettings.request") {
          scheduleInboundTask(
            "agent settings request",
            () => answerOpenClawBotSettingsRequest(event),
          )
          return
        }

        if (event.kind === "bot.chatSettings.item.invoke") {
          scheduleInboundTask(
            "agent settings update",
            () => answerOpenClawBotSettingsMutation(event),
            { serialKey: `agent-settings:${String(event.chatId)}` },
          )
          return
        }

        if (event.kind === "message.new") {
          const msg = {
            ...event.message,
            chatId: event.chatId,
          } as Message
          if (msg.out || msg.fromId === meId) return
          if (isInlineServiceMessage(msg)) return
          if (!claimInlineInboundMessageInstance({
            seen: seenInboundMessageInstances,
            chatId: event.chatId,
            message: msg,
          })) return
          if (
            isInlineAbortRequestMessage(msg, botUsername, meId) &&
            await isAuthorizedInlineAbortMessage({ chatId: event.chatId, msg })
          ) {
            cancelPendingInlineDebounce({ chatId: event.chatId, msg })
            cancelPendingInlineVoiceMessages({ chatId: event.chatId, msg })
            scheduleImmediateInboundMessage(
              { chatId: event.chatId, msg },
              "priority abort dispatch",
            )
            return
          }
          if (voiceTranscriptWaitMs > 0 && shouldWaitForInlineVoiceTranscript(msg)) {
            holdInlineVoiceMessage({
              chatId: event.chatId,
              msg,
            })
            return
          }
          scheduleInboundMessage({
            chatId: event.chatId,
            msg,
          })
          return
        }

        if (event.kind === "message.edit") {
          const msg = {
            ...event.message,
            chatId: event.chatId,
          } as Message
          if (msg.out || msg.fromId === meId) return
          if (isInlineServiceMessage(msg)) return
          if (await handlePendingInlineVoiceEdit({ chatId: event.chatId, msg })) {
            return
          }
          await queueInlineMessageLifecycleSystemEvent({
            action: "edited",
            chatId: event.chatId,
            messageIds: [msg.id],
            senderId: msg.fromId,
          })
          return
        }

        if (event.kind === "message.delete") {
          await queueInlineMessageLifecycleSystemEvent({
            action: "deleted",
            chatId: event.chatId,
            messageIds: event.messageIds,
          })
          return
        }

        if (event.kind === "reaction.add") {
          if (event.reaction.userId === meId) return
          const shouldQueue = await shouldQueueInlineReactionSystemEvent({
            chatId: event.chatId,
            messageId: event.reaction.messageId,
            senderId: event.reaction.userId,
          })
          if (!shouldQueue) return

          await queueInlineReactionSystemEvent({
            action: "added",
            chatId: event.chatId,
            messageId: event.reaction.messageId,
            senderId: event.reaction.userId,
            emoji: event.reaction.emoji,
          })
          return
        }

        if (event.kind === "reaction.delete") {
          if (event.userId === meId) return
          const shouldQueue = await shouldQueueInlineReactionSystemEvent({
            chatId: event.chatId,
            messageId: event.messageId,
            senderId: event.userId,
          })
          if (!shouldQueue) return

          await queueInlineReactionSystemEvent({
            action: "removed",
            chatId: event.chatId,
            messageId: event.messageId,
            senderId: event.userId,
            emoji: event.emoji,
          })
          return
        }

        if (rawEvent["kind"] === "chat.participant.add") {
          const eventChatId = rawEvent["chatId"] as bigint | undefined
          if (!eventChatId) return
          const participant = rawEvent["participant"] as { userId?: bigint; date?: bigint } | undefined
          const eventDate = rawEvent["date"] as bigint | undefined
          const recovered = await recoverInlineJoinMentions({
            chatId: eventChatId,
            ...(participant ? { participant } : {}),
            ...(eventDate != null ? { eventDate } : {}),
          })
          for (const msg of recovered) {
            if (!claimInlineInboundMessageInstance({
              seen: seenInboundMessageInstances,
              chatId: eventChatId,
              message: msg,
            })) continue
            // This is a bounded replay selected by the authoritative join
            // timestamp, not a new live typing burst. Send it through the same
            // semantic inbound owner immediately: the ordinary debounce timer
            // can otherwise delay recovery beyond the join-event lifetime and
            // make the mention disappear if the monitor stops meanwhile.
            scheduleImmediateInboundMessage(
              {
                chatId: eventChatId,
                msg: { ...msg, mentioned: true },
              },
              "inline join mention recovery",
              { serializeWithChat: true },
            )
          }
          return
        }

        if (rawEvent["kind"] === "message.action.invoke") {
          const actorUserId = rawEvent["actorUserId"] as bigint | undefined
          const interactionId = rawEvent["interactionId"] as bigint | undefined
          const actionId = rawEvent["actionId"] as string | undefined
          const targetMessageId = rawEvent["messageId"] as bigint | undefined
          const data = rawEvent["data"] as Uint8Array | undefined
          const eventChatId = rawEvent["chatId"] as bigint | undefined
          const eventDate = rawEvent["date"] as bigint | undefined

          if (!actorUserId || !interactionId || !actionId || !targetMessageId || !eventChatId || !eventDate || !data) {
            return
          }
          if (actorUserId === meId) return

          scheduleImmediateInboundMessage(
            {
              chatId: eventChatId,
              msg: {
                id: targetMessageId,
                chatId: eventChatId,
                date: eventDate,
                fromId: actorUserId,
                message: "",
                out: false,
                mentioned: false,
                replyToMsgId: targetMessageId,
              } as Message,
              callbackActionEvent: {
                interactionId,
                actionId,
                targetMessageId,
                data,
              },
            },
            "inline action dispatch",
            // Approval buttons carry their /approve command as callback data.
            isInlineOutOfBandCommandText(decodeInlineCallbackText(data)) ? undefined : { serializeWithChat: true },
          )
          return
        }
      })
    } catch (err) {
      publishStatus({ connected: false, lastError: String(err) })
      runtime.error?.(`inline monitor loop crashed: ${String(err)}`)
      unshareClient()
      await client.close().catch(() => {})
      throw err
    }
  })()

  const diagnosticsTimer = setInterval(() => {
    pushDiagnostics()
  }, 15_000)
  diagnosticsTimer.unref?.()

  let stopPromise: Promise<void> | null = null
  const stop = async () => {
    if (stopPromise) {
      await stopPromise
      return
    }
    stopPromise = (async () => {
      shutdown.abort()
      clearInterval(diagnosticsTimer)
      clearPendingInlineVoiceMessages()
      unshareClient()
      await client.close().catch(() => {})
      await loop.catch(() => {})
      await drainInboundTasks()
    })()
    await stopPromise
  }

  params.abortSignal.addEventListener(
    "abort",
    () => {
      void stop()
    },
    { once: true },
  )
  if (params.abortSignal.aborted) void stop()

  const done = loop.then(
    drainInboundTasks,
    async (error) => {
      await stop()
      throw error
    },
  )
  return { stop, done }
}
