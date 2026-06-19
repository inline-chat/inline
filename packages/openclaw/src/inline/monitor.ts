import { mkdir, stat } from "node:fs/promises"
import path from "node:path"
import {
  buildCommandTextFromArgs,
  findCommandByNativeName,
  formatCommandArgMenuTitle,
  listNativeCommandSpecsForConfig,
  parseCommandArgs,
  resolveCommandArgMenu,
} from "openclaw/plugin-sdk/native-command-registry"
import { CHANNEL_APPROVAL_NATIVE_RUNTIME_CONTEXT_CAPABILITY } from "openclaw/plugin-sdk/approval-handler-adapter-runtime"
import { registerChannelRuntimeContext } from "openclaw/plugin-sdk/channel-runtime-context"
import {
  resolveCommandAuthorization,
  resolveStoredModelOverride,
} from "openclaw/plugin-sdk/command-auth-native"
import { expandAllowFromWithAccessGroups } from "openclaw/plugin-sdk/security-runtime"
import { buildCommandsMessagePaginated } from "openclaw/plugin-sdk/command-status"
import { isAbortRequestText } from "openclaw/plugin-sdk/command-primitives-runtime"
import {
  createConnectedChannelStatusPatch,
  createTransportActivityStatusPatch,
} from "openclaw/plugin-sdk/gateway-runtime"
import {
  classifyChannelInboundEvent,
  createChannelInboundDebouncer,
  resolveUnmentionedGroupInboundPolicy,
  shouldDebounceTextInbound,
} from "openclaw/plugin-sdk/channel-inbound"
import {
  buildConfiguredModelCatalog,
  resolveAgentConfig,
  resolveDefaultModelForAgent,
  resolveThinkingDefault,
} from "openclaw/plugin-sdk/agent-runtime"
import {
  applyModelOverrideToSessionEntry,
  loadSessionStore,
  resolveSessionStoreEntry,
  resolveStorePath,
  updateSessionStore,
} from "openclaw/plugin-sdk/config-runtime"
import { buildModelsProviderData } from "openclaw/plugin-sdk/models-provider-runtime"
import { listSkillCommandsForAgents } from "openclaw/plugin-sdk/skill-commands-runtime"
import { getPluginCommandSpecs } from "openclaw/plugin-sdk/plugin-runtime"
import { isReasoningReplyPayload } from "openclaw/plugin-sdk/reply-payload"
import {
  buildChannelProgressDraftLine,
  buildChannelProgressDraftLineForEntry,
  createChannelProgressDraftGate,
  formatChannelProgressDraftText,
  isChannelProgressDraftWorkToolName,
  mergeChannelProgressDraftLine,
  resolveChannelProgressDraftMaxLines,
  resolveChannelStreamingPreviewToolProgress,
  type ChannelProgressDraftLine,
} from "openclaw/plugin-sdk/channel-streaming"
import {
  findCodeRegions,
  isInsideCode,
  normalizeLowercaseStringOrEmpty,
  stripReasoningTagsFromText,
} from "openclaw/plugin-sdk/text-runtime"
import {
  DEFAULT_GROUP_HISTORY_LIMIT,
  clearHistoryEntriesIfEnabled,
  createChannelReplyPipelineCompat,
  recordPendingHistoryEntryIfEnabled,
  type InlineTypingCallbacks,
} from "../sdk-runtime-compat.js"
import type { OpenClawConfig, PluginCommandContext } from "openclaw/plugin-sdk/core"
import type { ChannelRuntimeSurface } from "openclaw/plugin-sdk/channel-contract"
import type { RuntimeEnv } from "openclaw/plugin-sdk/runtime-env"
import {
  BotPresenceState_Kind,
  InlineSdkClient,
  JsonFileStateStore,
  Method,
  type Message,
  type MessageActions,
  type MessageActionResponseUi,
  type User,
} from "@inline-chat/realtime-sdk"
import { resolveInlineToken, type ResolvedInlineAccount } from "./accounts.js"
import { resolveInlineMessageActionsParam } from "./actions.js"
import {
  INLINE_DEFAULT_GROUP_POLICY,
  INLINE_DEFAULT_REQUIRE_MENTION,
} from "./config-schema.js"
import { isInlineExecApprovalHandlerConfigured } from "./exec-approvals.js"
import { buildInlineSystemPrompt, sanitizeInlineOutgoingText } from "./message-formatting.js"
import {
  resolveInlineGroupAllowFrom,
  resolveInlineGroupAccessPolicy,
  resolveInlineGroupRequireMention,
  resolveInlineGroupReplyThreadAutoCreateMinMessages,
  resolveInlineGroupReplyThreadMode,
  resolveInlineGroupReplyThreadParentHistoryLimit,
  resolveInlineGroupReplyThreadRequireExplicitMention,
  resolveInlineGroupSystemPrompt,
  type InlineReplyThreadMode,
} from "./policy.js"
import { getInlineRuntime } from "../runtime.js"
import { uploadInlineMediaFromUrl } from "./media.js"
import { summarizeInlineMessageContent } from "./message-content.js"
import {
  sanitizeInlineActionCallbackData,
  sanitizeInlineActionCopyText,
  sanitizeInlineActionLabel,
  sanitizeInlineVisibleText,
} from "./outbound-sanitize.js"
import { resolveInlineInteractiveTextFallback } from "./interactive-fallback.js"
import {
  buildInlineCommandsListChannelData,
  buildInlineModelProviderButtons,
  parseInlineCommandsPageCallback,
  type InlineReplyMarkupButton,
} from "./command-ui.js"
import {
  createInlineReplyThreadForMessage,
  isInlineReplyThreadsEnabled,
  loadInlineReplyThreadAnchorMessage,
  loadInlineReplyThreadMetadata,
} from "./reply-threads.js"
import {
  hasInlineThreadParticipationWithPersistence,
  recordInlineThreadParticipation,
} from "./thread-participation.js"
import {
  lookupInlineReplyThreadRoute,
  rememberInlineReplyThreadRoute,
  type InlineReplyThreadRouteRecord,
} from "./thread-routes.js"
import { resolveInlineThreadFreshness } from "./thread-freshness.js"
import {
  logInboundDrop,
  resolveChannelMediaMaxBytes,
  resolveControlCommandGate,
  resolveMentionGatingWithBypass,
} from "../openclaw-compat.js"
import {
  shouldSyncInlineNativeCommandsForAccount,
  shouldSyncInlineNativeSkillsForAccount,
} from "./bot-commands-sync.js"
import {
  handleInlineThreadReplyCommandWithConfigRuntime,
  listInlineBuiltinCommandSpecs,
} from "./threadreply-command.js"

const CHANNEL_ID = "inline" as const
const INLINE_NATIVE_COMMAND_PROVIDER = CHANNEL_ID
const INLINE_NATIVE_COMMAND_CALLBACK_PREFIX = "icmd:"
const INLINE_REQUEST_ERROR_FALLBACK =
  "OpenClaw could not process that request. Please try again."
const INLINE_DEBOUNCE_ERROR_FALLBACK =
  "OpenClaw could not process those messages. Please try again."
const DEFAULT_REPLY_THREAD_AUTO_CREATE_MIN_MESSAGES = 50
const DEFAULT_REPLY_THREAD_PARENT_HISTORY_LIMIT = 10
const DEFAULT_INLINE_VOICE_TRANSCRIPT_WAIT_MS = 8_000
const MAX_INLINE_VOICE_TRANSCRIPT_WAIT_MS = 60_000
const INLINE_BOT_PRESENCE_IDLE_DELAY_MS = 8_000
const INLINE_BOT_PRESENCE_FINISH_IDLE_DELAY_MS = 8_000
const INLINE_BOT_PRESENCE_GESTURE_MS = 1_400
const INLINE_BOT_PRESENCE_FAILED_MS = 8_000
const INLINE_BOT_PRESENCE_COMMENT_MAX_LENGTH = 30
const INLINE_REPLY_THREAD_SYSTEM_PROMPT =
  "Inline reply threads are scoped conversations: answer only the current reply-thread message and this thread's own history; use parent-chat context only as background, and do not answer unrelated questions from the parent chat or other reply threads."
const INLINE_REPLY_THREAD_NEGATION_RE =
  /\b(?:do\s+not|don't|dont|please\s+don't|please\s+dont|no\s+need\s+to)\s+(?:create|start|open|make|use|move|take|reply|respond|answer|send|thread)\b[^.!?\n]*\bthread\b|\b(?:reply|respond|answer|keep)\s+(?:here|in\s+the\s+main\s+chat|in\s+main\s+chat|in\s+the\s+parent\s+chat|in\s+parent\s+chat)\b/u
const INLINE_REPLY_THREAD_INTENT_RE =
  /\b(?:reply|respond|answer|send)\s+(?:in|inside|into|to)\s+(?:a\s+)?(?:(?:new|child|reply)\s+)?thread\b|\b(?:create|start|open|make|use)\s+(?:a\s+)?(?:(?:new|child|reply)\s+)?thread\b|\b(?:move|take)\s+(?:(?:this|it|the\s+answer|the\s+reply|the\s+response)\s+)?(?:to|into)\s+(?:a\s+)?(?:(?:new|child|reply)\s+)?thread\b|\bthread\s+(?:this|the\s+answer|the\s+reply|the\s+response)\b|\b(?:threaded\s+(?:reply|response)|(?:reply|respond|answer)\s+threaded)\b/u

type InlineBotPresenceKind =
  | "idle"
  | "happy"
  | "waving"
  | "jumping"
  | "failed"
  | "waiting"
  | "running"
  | "review"

type InlineBotPresenceSignal = {
  kind: InlineBotPresenceKind
  comment?: string
}

type InlineMonitorHandle = {
  stop: () => Promise<void>
  done: Promise<void>
}

type InlineMentionSource =
  | "explicit_bot"
  | "subteam"
  | "mention_pattern"
  | "implicit_thread"
  | "command_bypass"
  | "none"

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

type CachedChatInfo = {
  kind: "direct" | "group"
  title: string | null
  peerUserId?: bigint | null
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
  hasBotMessage: boolean
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

type InlineProgressPlaceholderState = {
  messageId: bigint | null
  text: string
  lines: Array<string | ChannelProgressDraftLine>
  opChain: Promise<void>
  closing: boolean
}

type InlinePendingHistoryEntry = {
  sender: string
  body: string
  timestamp?: number
  messageId?: string
}

type InlineUntrustedStructuredContextEntry = {
  label: string
  source: typeof CHANNEL_ID
  type: string
  payload: {
    summary: string
  }
}

type InlineReplyThreadContext = {
  childChatId: bigint
  parentChatId: bigint
  parentChatTitle: string | null
  parentMessageId: bigint | null
  threadLabel: string | null
  anchorMessage: Message | null
}

type InlineDispatchReplyInfo = {
  kind?: string
  reason?: string
}

type InlineReplyPayload = {
  text?: string
  mediaUrl?: string
  mediaUrls?: string[]
  replyToId?: string
  channelData?: Record<string, unknown>
  isReasoning?: boolean
}

function buildInlineTypingDispatcherOptions(typingCallbacks?: InlineTypingCallbacks) {
  if (!typingCallbacks) {
    return {}
  }
  return {
    typingCallbacks,
    onReplyStart: typingCallbacks.onReplyStart,
    ...(typingCallbacks.onIdle ? { onIdle: typingCallbacks.onIdle } : {}),
    ...(typingCallbacks.onCleanup ? { onCleanup: typingCallbacks.onCleanup } : {}),
  }
}

function uniqueInlineChatIds(chatIds: Array<bigint | null | undefined>): bigint[] {
  const seen = new Set<string>()
  const out: bigint[] = []
  for (const chatId of chatIds) {
    if (chatId == null) continue
    const key = String(chatId)
    if (seen.has(key)) continue
    seen.add(key)
    out.push(chatId)
  }
  return out
}

async function sendInlineTypingToChats(params: {
  client: Pick<InlineSdkClient, "sendTyping">
  chatIds: bigint[]
  typing: boolean
  onPartialError?: (chatId: bigint, error: unknown) => void
}): Promise<void> {
  if (params.chatIds.length === 0) return

  const failures: Array<{ chatId: bigint; error: unknown }> = []
  await Promise.all(
    params.chatIds.map(async (chatId) => {
      try {
        await params.client.sendTyping({ chatId, typing: params.typing })
      } catch (error) {
        failures.push({ chatId, error })
      }
    }),
  )
  if (failures.length === 0) return
  if (failures.length === params.chatIds.length) {
    throw failures[0]?.error ?? new Error("inline typing failed")
  }
  for (const failure of failures) {
    params.onPartialError?.(failure.chatId, failure.error)
  }
}

function inlineBotPresenceStateKind(kind: InlineBotPresenceKind): BotPresenceState_Kind {
  switch (kind) {
    case "idle":
      return BotPresenceState_Kind.IDLE
    case "happy":
      return BotPresenceState_Kind.HAPPY
    case "waving":
      return BotPresenceState_Kind.WAVING
    case "jumping":
      return BotPresenceState_Kind.JUMPING
    case "failed":
      return BotPresenceState_Kind.FAILED
    case "waiting":
      return BotPresenceState_Kind.WAITING
    case "running":
      return BotPresenceState_Kind.RUNNING
    case "review":
      return BotPresenceState_Kind.REVIEW
  }
}

function normalizeInlineBotPresenceKind(value: unknown): InlineBotPresenceKind | undefined {
  if (typeof value !== "string") return undefined
  switch (value.trim().toLowerCase()) {
    case "idle":
    case "happy":
    case "waving":
    case "jumping":
    case "failed":
    case "waiting":
    case "running":
    case "review":
      return value.trim().toLowerCase() as InlineBotPresenceKind
    default:
      return undefined
  }
}

function normalizeInlineBotPresenceComment(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined
  const text = value.replace(/\s+/g, " ").trim()
  if (!text) return undefined
  return Array.from(text).slice(0, INLINE_BOT_PRESENCE_COMMENT_MAX_LENGTH).join("")
}

function resolveInlineBotPresenceSignal(payload: InlineReplyPayload): InlineBotPresenceSignal | null {
  const channelData = isRecord(payload.channelData) ? payload.channelData : undefined
  const inlineData = channelData && isRecord(channelData.inline) ? channelData.inline : undefined
  const rawPresence = inlineData && isRecord(inlineData.botPresence) ? inlineData.botPresence : undefined
  if (!rawPresence) return null

  const kind = normalizeInlineBotPresenceKind(rawPresence.kind) ?? "happy"
  const comment = normalizeInlineBotPresenceComment(rawPresence.comment)
  return comment ? { kind, comment } : { kind }
}

async function sendInlineBotPresenceToChats(params: {
  client: Pick<InlineSdkClient, "invokeRaw">
  chatIds: bigint[]
  kind: InlineBotPresenceKind
  comment?: string
  onPartialError?: (chatId: bigint, error: unknown) => void
}): Promise<void> {
  if (params.chatIds.length === 0) return

  const failures: Array<{ chatId: bigint; error: unknown }> = []
  await Promise.all(
    params.chatIds.map(async (chatId) => {
      try {
        await params.client.invokeRaw(Method.SET_BOT_PRESENCE_STATE, {
          oneofKind: "setBotPresenceState",
          setBotPresenceState: {
            peerId: {
              type: {
                oneofKind: "chat",
                chat: { chatId },
              },
            },
            state: {
              kind: inlineBotPresenceStateKind(params.kind),
              ...(params.comment ? { comment: params.comment } : {}),
            },
          },
        })
      } catch (error) {
        failures.push({ chatId, error })
      }
    }),
  )
  if (failures.length === 0) return
  if (failures.length === params.chatIds.length) {
    throw failures[0]?.error ?? new Error("inline bot presence failed")
  }
  for (const failure of failures) {
    params.onPartialError?.(failure.chatId, failure.error)
  }
}

async function sendInlineTypingAndBotPresenceToChats(params: {
  client: Pick<InlineSdkClient, "invokeRaw" | "sendTyping">
  chatIds: bigint[]
  typing: boolean
  presenceKind: InlineBotPresenceKind
  onTypingPartialError?: (chatId: bigint, error: unknown) => void
  onPresencePartialError?: (chatId: bigint, error: unknown) => void
  onPresenceError?: (error: unknown) => void
}): Promise<void> {
  let typingError: unknown = null
  await Promise.all([
    sendInlineTypingToChats({
      client: params.client,
      chatIds: params.chatIds,
      typing: params.typing,
      ...(params.onTypingPartialError ? { onPartialError: params.onTypingPartialError } : {}),
    }).catch((error) => {
      typingError = error
    }),
    sendInlineBotPresenceToChats({
      client: params.client,
      chatIds: params.chatIds,
      kind: params.presenceKind,
      ...(params.onPresencePartialError ? { onPartialError: params.onPresencePartialError } : {}),
    }).catch((error) => {
      params.onPresenceError?.(error)
    }),
  ])

  if (typingError != null) {
    throw typingError
  }
}

function createInlineBotPresenceLifecycle(params: {
  client: Pick<InlineSdkClient, "invokeRaw">
  chatIds: bigint[]
  onPartialError: (chatId: bigint, error: unknown) => void
  onError: (error: unknown) => void
}) {
  let active = false
  let finishing = false
  let idleTimer: ReturnType<typeof setTimeout> | undefined
  let gestureTimer: ReturnType<typeof setTimeout> | undefined
  let currentKind: InlineBotPresenceKind | undefined
  let currentComment: string | undefined
  let busyKind: InlineBotPresenceKind = "running"
  let busyComment: string | undefined
  let sendChain: Promise<void> = Promise.resolve()

  const clearIdleTimer = () => {
    if (!idleTimer) return
    clearTimeout(idleTimer)
    idleTimer = undefined
  }

  const clearGestureTimer = () => {
    if (!gestureTimer) return
    clearTimeout(gestureTimer)
    gestureTimer = undefined
  }

  const send = (kind: InlineBotPresenceKind, comment?: string): Promise<void> => {
    if (currentKind === kind && currentComment === comment) return Promise.resolve()
    currentKind = kind
    currentComment = comment
    sendChain = sendChain
      .catch(() => {})
      .then(() =>
        sendInlineBotPresenceToChats({
          client: params.client,
          chatIds: params.chatIds,
          kind,
          ...(comment ? { comment } : {}),
          onPartialError: params.onPartialError,
        }).catch(params.onError),
      )
    return sendChain
  }

  const scheduleIdle = (delayMs = INLINE_BOT_PRESENCE_IDLE_DELAY_MS) => {
    clearIdleTimer()
    idleTimer = setTimeout(() => {
      idleTimer = undefined
      active = false
      finishing = false
      busyKind = "running"
      busyComment = undefined
      void send("idle")
    }, delayMs)
    idleTimer.unref?.()
  }

  const showBusy = async (kind: InlineBotPresenceKind, comment?: string): Promise<void> => {
    if (!active || finishing) return
    clearIdleTimer()
    clearGestureTimer()
    busyKind = kind
    busyComment = comment
    await send(kind, comment)
  }

  const gesture = (
    kind: InlineBotPresenceKind,
    resumeKind = busyKind,
    comment?: string,
    resumeComment = busyComment,
  ) => {
    if (params.chatIds.length === 0) return
    clearIdleTimer()
    clearGestureTimer()
    active = true
    void send(kind, comment)
    gestureTimer = setTimeout(() => {
      gestureTimer = undefined
      if (!active || finishing) return
      void send(resumeKind, resumeComment)
    }, INLINE_BOT_PRESENCE_GESTURE_MS)
    gestureTimer.unref?.()
  }

  return {
    start: async (cue?: InlineBotPresenceSignal | null) => {
      if (params.chatIds.length === 0) return
      clearIdleTimer()
      if (active && !finishing) return
      active = true
      finishing = false
      const cueKind = cue?.kind
      busyKind = cueKind === "review" ? "review" : "running"
      busyComment = undefined
      if (cueKind === "waving") {
        gesture("waving", busyKind)
        return
      }
      await send(busyKind, busyComment)
    },
    busy: (kind: InlineBotPresenceKind, comment?: string) => {
      void showBusy(kind, comment)
    },
    gesture: (kind: InlineBotPresenceKind, comment?: string) => {
      gesture(kind, busyKind, comment)
    },
    express: (signal: InlineBotPresenceSignal) => {
      if (signal.kind === "failed") {
        if (params.chatIds.length === 0) return
        clearIdleTimer()
        clearGestureTimer()
        active = true
        finishing = true
        void send("failed", signal.comment).finally(() => scheduleIdle(INLINE_BOT_PRESENCE_FAILED_MS))
        return
      }
      if (params.chatIds.length === 0) return
      clearIdleTimer()
      clearGestureTimer()
      active = true
      finishing = true
      void send(signal.kind, signal.comment).finally(() => scheduleIdle())
    },
    finish: () => {
      if (!active || finishing) return
      finishing = true
      clearGestureTimer()
      scheduleIdle(INLINE_BOT_PRESENCE_FINISH_IDLE_DELAY_MS)
    },
    fail: (comment?: string) => {
      if (params.chatIds.length === 0) return
      clearIdleTimer()
      clearGestureTimer()
      active = true
      finishing = true
      void send("failed", comment).finally(() => scheduleIdle(INLINE_BOT_PRESENCE_FAILED_MS))
    },
    cleanup: () => {
      if (!active) return
      if (finishing) return
      clearIdleTimer()
      clearGestureTimer()
      active = false
      void send("idle").finally(() => {
        finishing = false
        busyKind = "running"
        busyComment = undefined
      })
    },
  }
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

function formatInlineOperationError(operation: string, error: unknown): string {
  const detail = summarizeSdkMeta(error) || String(error)
  return `${operation} failed: ${detail}`
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
const REASONING_MESSAGE_PREFIX = "Reasoning:\n"
const REASONING_TAG_PREFIXES = [
  "<think",
  "<thinking",
  "<thought",
  "<antthinking",
  "</think",
  "</thinking",
  "</thought",
  "</antthinking",
]
const THINKING_TAG_RE = /<\s*(\/?)\s*(?:think(?:ing)?|thought|antthinking)\b[^<>]*>/gi

function normalizeAllowEntry(raw: string): string {
  const withoutChannel = raw.trim().replace(/^inline:/i, "").trim()
  if (/^chat:/i.test(withoutChannel)) {
    return withoutChannel
  }
  return withoutChannel.replace(/^user:/i, "").trim()
}

function resolveInlinePayloadMediaUrls(payload: InlineReplyPayload): string[] {
  if (payload.mediaUrls?.length) return payload.mediaUrls
  if (payload.mediaUrl) return [payload.mediaUrl]
  return []
}

function isPartialReasoningTagPrefix(text: string): boolean {
  const trimmed = normalizeLowercaseStringOrEmpty(text.trimStart())
  if (!trimmed.startsWith("<")) return false
  if (trimmed.includes(">")) return false
  return REASONING_TAG_PREFIXES.some((prefix) => prefix.startsWith(trimmed))
}

type InlineReasoningSplit = {
  reasoningText?: string
  answerText?: string
}

function formatInlineReasoningMessage(text: string): string {
  const trimmed = text.trim()
  if (!trimmed) return ""
  const italicLines = trimmed
    .split("\n")
    .map((line) => (line ? `_${line}_` : line))
    .join("\n")
  return `${REASONING_MESSAGE_PREFIX}${italicLines}`
}

function extractInlineThinkingFromTaggedStreamOutsideCode(text: string): string {
  if (!text) return ""
  const codeRegions = findCodeRegions(text)
  let result = ""
  let lastIndex = 0
  let inThinking = false
  THINKING_TAG_RE.lastIndex = 0
  for (const match of text.matchAll(THINKING_TAG_RE)) {
    const idx = match.index ?? 0
    if (isInsideCode(idx, codeRegions)) continue
    if (inThinking) {
      result += text.slice(lastIndex, idx)
    }
    const isClose = match[1] === "/"
    inThinking = !isClose
    lastIndex = idx + match[0].length
  }
  if (inThinking) {
    result += text.slice(lastIndex)
  }
  return result.trim()
}

function splitInlineReasoningText(text?: string, isReasoning?: boolean): InlineReasoningSplit {
  if (typeof text !== "string") return {}

  const trimmed = text.trim()
  if (isPartialReasoningTagPrefix(trimmed)) {
    return {}
  }
  if (
    trimmed.startsWith(REASONING_MESSAGE_PREFIX) &&
    trimmed.length > REASONING_MESSAGE_PREFIX.length
  ) {
    return { reasoningText: trimmed }
  }

  const taggedReasoning = extractInlineThinkingFromTaggedStreamOutsideCode(text)
  const strippedAnswer = stripReasoningTagsFromText(text, { mode: "strict", trim: "both" })

  if (isReasoning === true) {
    return {
      reasoningText: formatInlineReasoningMessage(
        taggedReasoning || strippedAnswer || text,
      ),
    }
  }
  if (!taggedReasoning && strippedAnswer === text) {
    return { answerText: text }
  }
  const reasoningText = taggedReasoning
    ? formatInlineReasoningMessage(taggedReasoning)
    : undefined
  return {
    ...(reasoningText ? { reasoningText } : {}),
    ...(strippedAnswer ? { answerText: strippedAnswer } : {}),
  }
}

function resolveInlineChatVisibleReplyPayload<T extends InlineReplyPayload>(payload: T): T | null {
  const mediaUrls = resolveInlinePayloadMediaUrls(payload)
  if (isReasoningReplyPayload(payload)) {
    return mediaUrls.length > 0 ? { ...payload, text: undefined } : null
  }

  if (typeof payload.text !== "string") {
    return payload
  }

  const internal = sanitizeInlineVisibleText(payload.text)
  if (internal.shouldSkip) {
    return mediaUrls.length > 0 ? { ...payload, text: undefined } : null
  }
  if (isPartialReasoningTagPrefix(internal.text.trim())) {
    return mediaUrls.length > 0 ? { ...payload, text: undefined } : null
  }

  const split = splitInlineReasoningText(internal.text, payload.isReasoning)
  if (split.answerText !== undefined) {
    if (split.answerText === payload.text) {
      return payload
    }
    return {
      ...payload,
      text: split.answerText || undefined,
    }
  }
  if (!split.reasoningText) {
    return payload
  }
  return mediaUrls.length > 0 ? { ...payload, text: undefined } : null
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

function resolveInlineCommandAuthorized(params: {
  cfg: OpenClawConfig
  accountId: string
  isGroup: boolean
  chatId: string
  senderId: string
  commandAuthorized: boolean
}): boolean {
  return resolveCommandAuthorization({
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
  }).isAuthorizedSender
}

async function resolveChatInfo(
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
  }
  cache.set(chatId, info)
  return info
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

function describeInlineParticipantAddSystemEvent(params: {
  channelLabel: string
  recentLines: string[]
  priorMentionLines: string[]
}): string {
  const lines = [`Inline bot was added as a participant in ${params.channelLabel}.`]
  if (params.priorMentionLines.length > 0) {
    lines.push(
      "The bot was mentioned before it joined. Respond to the prior mention(s) that still need attention, then introduce yourself briefly.",
    )
    lines.push(`Prior bot mentions before join:\n${params.priorMentionLines.join("\n")}`)
  } else {
    lines.push("Introduce yourself briefly, then wait for the next user request.")
  }
  if (params.recentLines.length > 0) {
    lines.push(`Recent messages before join:\n${params.recentLines.join("\n")}`)
  }
  return lines.join("\n")
}

function buildInlineParticipantAddContextKey(params: {
  chatId: bigint
  userId: bigint
  participantDate?: bigint
  seq?: number
}): string {
  return [
    "inline:participant:added",
    String(params.chatId),
    String(params.userId),
    params.participantDate != null ? String(params.participantDate) : String(params.seq ?? 0),
  ].join(":")
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

function isInlineAbortRequestMessage(msg: Message, botUsername: string | undefined): boolean {
  const text = typeof msg.message === "string" ? msg.message : ""
  return isAbortRequestText(text, botUsername ? { botUsername } : undefined)
}

function findInlineNativeCommandFromBody(commandBody: string): NonNullable<ReturnType<typeof findCommandByNativeName>> | null {
  const match = commandBody.trim().match(/^\/([^\s]+)(?:\s+[\s\S]*)?$/)
  if (!match?.[1]) return null
  return findCommandByNativeName(match[1], INLINE_NATIVE_COMMAND_PROVIDER) ?? null
}

function resolveInlineCommandNameFromBody(commandBody: string): string | null {
  const match = commandBody.trim().match(/^\/([^\s]+)(?:\s+[\s\S]*)?$/)
  const raw = match?.[1]?.trim().toLowerCase()
  return raw || null
}

function buildInlineNativeCommandCallbackData(commandText: string): string {
  return `${INLINE_NATIVE_COMMAND_CALLBACK_PREFIX}${commandText}`
}

function parseInlineNativeCommandCallbackData(raw: string | undefined): string | null {
  if (!raw) return null
  const trimmed = raw.trim()
  if (!trimmed.startsWith(INLINE_NATIVE_COMMAND_CALLBACK_PREFIX)) return null
  const commandText = trimmed.slice(INLINE_NATIVE_COMMAND_CALLBACK_PREFIX.length).trim()
  return commandText.startsWith("/") ? commandText : null
}

function listHostInlinePluginCommandSpecs(cfg: OpenClawConfig): Array<{ name: string; description: string }> {
  return getPluginCommandSpecs("inline", { config: cfg })
}

function listInlinePluginCommandSpecs(cfg: OpenClawConfig): Array<{ name: string; description: string }> {
  return [
    ...listHostInlinePluginCommandSpecs(cfg),
    ...listInlineBuiltinCommandSpecs(),
  ]
}

function hasInlineCommandSpec(
  specs: Array<{ name: string }>,
  commandName: string,
): boolean {
  const normalized = commandName.trim().toLowerCase()
  if (!normalized) return false
  return specs.some((spec) => spec.name.trim().toLowerCase() === normalized)
}

function isInlineThreadReplyCommandBody(commandBody: string): boolean {
  return resolveInlineCommandNameFromBody(commandBody) === "threadreply"
}

function parseInlineCommandArgs(commandBody: string): string {
  const match = commandBody.trim().match(/^\/[^\s]+(?:\s+([\s\S]*))?$/)
  return match?.[1]?.trim() ?? ""
}

function isInlineNativeCommandBody(params: {
  cfg: OpenClawConfig
  account: ResolvedInlineAccount
  commandBody: string
  agentId: string
}): boolean {
  if (!shouldSyncInlineNativeCommandsForAccount({ cfg: params.cfg, account: params.account })) {
    return false
  }
  const commandName = resolveInlineCommandNameFromBody(params.commandBody)
  if (!commandName) return false

  const skillCommands = shouldSyncInlineNativeSkillsForAccount({
    cfg: params.cfg,
    account: params.account,
  })
    ? listSkillCommandsForAgents({
        cfg: params.cfg,
        agentIds: [params.agentId],
      })
    : []
  const commandSpecs = listNativeCommandSpecsForConfig(params.cfg, {
    skillCommands,
    provider: INLINE_NATIVE_COMMAND_PROVIDER,
  })
  for (const spec of commandSpecs) {
    if (spec.name.trim().toLowerCase() === commandName) return true
  }
  for (const spec of listInlinePluginCommandSpecs(params.cfg)) {
    if (spec.name.trim().toLowerCase() === commandName) return true
  }
  return false
}

function escapeInlineRegExp(raw: string): string {
  return raw.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
}

function stripInlineBotMention(raw: string, botUsername: string | undefined): string {
  const username = normalizeInlineUsername(botUsername)
  if (!username) return raw
  const mention = new RegExp(`(^|\\s)@${escapeInlineRegExp(username)}(?=$|[\\s,.:;!?])(?:[\\s,.:;!?]+)?`, "gi")
  return raw.replace(mention, "$1").replace(/[ \t]{2,}/g, " ").trim()
}

function stripInlineBotMentionEntityText(text: string | null, botUsername: string | undefined): string | null {
  const username = normalizeInlineUsername(botUsername)?.toLowerCase()
  if (!text || !username) return text
  const token = `@${username}`
  const parts = text
    .split(" | ")
    .filter((part) => {
      const normalized = part.trim().toLowerCase()
      return normalized !== `username mention "${token}"` && !normalized.startsWith(`mention "${token}"`)
    })
  const next = parts.join(" | ").trim()
  return next || null
}

function collectInlineMentionedUserIds(
  content: ReturnType<typeof summarizeInlineMessageContent> | null,
): string[] {
  const ids = new Set<string>()
  for (const entity of content?.entities ?? []) {
    if (entity.type !== "mention" || !entity.userId) continue
    ids.add(entity.userId)
  }
  return [...ids]
}

function resolveInlineMentionSource(params: {
  nativeMentioned: boolean
  patternMentioned: boolean
  implicitMention: boolean
  shouldBypassMention: boolean
  wasMentioned: boolean
}): InlineMentionSource {
  if (params.nativeMentioned) return "explicit_bot"
  if (params.shouldBypassMention) return "command_bypass"
  if (params.patternMentioned) return "mention_pattern"
  if (params.implicitMention) return "implicit_thread"
  if (params.wasMentioned) return "mention_pattern"
  return "none"
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

type InlineModelPickerCallback =
  | { type: "providers" | "back" }
  | { type: "list"; provider: string; page: number }
  | { type: "select"; provider?: string; model: string }

type InlineModelPickerSelection =
  | { kind: "resolved"; provider: string; model: string }
  | { kind: "ambiguous"; model: string }

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

const INLINE_ACTION_MAX_ROWS = 8
const INLINE_ACTION_MAX_PER_ROW = 8
const INLINE_CALLBACK_TOAST_MAX_LENGTH = 256

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

function normalizeInlineCallbackToastText(raw: unknown): string | undefined {
  if (typeof raw !== "string") return undefined

  const visible = sanitizeInlineVisibleText(raw)
  if (visible.shouldSkip) return undefined

  const text = visible.text.replace(/\s+/g, " ").trim()
  if (!text) return undefined

  if (text.length <= INLINE_CALLBACK_TOAST_MAX_LENGTH) {
    return text
  }

  return text.slice(0, INLINE_CALLBACK_TOAST_MAX_LENGTH).trimEnd()
}

function resolveInlineCallbackResponseUi(data: Uint8Array): MessageActionResponseUi | undefined {
  const decoded = callbackDataToUtf8(data)
  if (!decoded) return undefined

  let parsed: unknown
  try {
    parsed = JSON.parse(decoded)
  } catch {
    return undefined
  }

  if (!isRecord(parsed)) return undefined

  const text =
    normalizeInlineCallbackToastText(parsed.callbackToast) ??
    normalizeInlineCallbackToastText(parsed.callback_toast) ??
    normalizeInlineCallbackToastText(parsed.toast)

  if (!text) return undefined

  return {
    kind: {
      oneofKind: "toast",
      toast: { text },
    },
  }
}

function normalizeOptionalString(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined
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

  return (
    config.streaming === undefined &&
    config.streamMode === undefined &&
    config.streamViaEditMessage !== true
  )
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

function resolveInlineCommandMenuModelContext(params: {
  cfg: OpenClawConfig
  agentId: string
  sessionKey: string
}): { provider?: string; model?: string; thinkingLevel?: string } {
  if (!params.sessionKey.trim()) {
    return {}
  }
  try {
    const storePath = resolveStorePath(params.cfg.session?.store, { agentId: params.agentId })
    const defaultModel = resolveDefaultModelForAgent({
      cfg: params.cfg,
      agentId: params.agentId,
    })
    const store = loadSessionStore(storePath)
    const entry = resolveSessionStoreEntry({ store, sessionKey: params.sessionKey }).existing
    const thinkingLevel = normalizeOptionalString(entry?.thinkingLevel)
    if (entry?.modelOverrideSource === "auto" && normalizeOptionalString(entry.modelOverride)) {
      return {
        provider: defaultModel.provider,
        model: defaultModel.model,
        ...(thinkingLevel ? { thinkingLevel } : {}),
      }
    }
    const override = resolveStoredModelOverride({
      ...(entry ? { sessionEntry: entry } : {}),
      sessionStore: store,
      sessionKey: params.sessionKey,
      defaultProvider: defaultModel.provider,
    })
    if (override?.model) {
      return {
        provider: override.provider || defaultModel.provider,
        model: override.model,
        ...(thinkingLevel ? { thinkingLevel } : {}),
      }
    }
    const provider =
      normalizeOptionalString(entry?.providerOverride) ??
      normalizeOptionalString(entry?.modelProvider)
    const model =
      normalizeOptionalString(entry?.modelOverride) ?? normalizeOptionalString(entry?.model)
    return {
      ...(provider ? { provider } : {}),
      ...(model ? { model } : {}),
      ...(thinkingLevel ? { thinkingLevel } : {}),
    }
  } catch {
    return {}
  }
}

function resolveInlineThinkMenuCurrentLevel(params: {
  cfg: OpenClawConfig
  agentId: string
  provider?: string
  model?: string
  thinkingLevel?: string
}): string {
  const explicit = normalizeOptionalString(params.thinkingLevel)
  if (explicit) return explicit

  const agentThinkingDefault = normalizeOptionalString(
    resolveAgentConfig(params.cfg, params.agentId)?.thinkingDefault,
  )
  if (agentThinkingDefault) return agentThinkingDefault

  const defaultModel = resolveDefaultModelForAgent({
    cfg: params.cfg,
    agentId: params.agentId,
  })
  return resolveThinkingDefault({
    cfg: params.cfg,
    provider: params.provider ?? defaultModel.provider,
    model: params.model ?? defaultModel.model,
    catalog: buildConfiguredModelCatalog({ cfg: params.cfg }),
  })
}

function formatInlineCommandArgMenuTitle(params: {
  command: NonNullable<ReturnType<typeof findCommandByNativeName>>
  menu: NonNullable<ReturnType<typeof resolveCommandArgMenu>>
  currentThinkingLevel?: string
}): string {
  const title = formatCommandArgMenuTitle({ command: params.command, menu: params.menu })
  if (params.command.key !== "think" || !params.currentThinkingLevel) {
    return title
  }
  return `Current thinking level: ${params.currentThinkingLevel}.\n${title}`
}

function resolveInlineNativeCommandMenu(params: {
  commandBody: string
  cfg: OpenClawConfig
  agentId: string
  sessionKey: string
}): {
  title: string
  buttons: InlineReplyMarkupButton[][]
} | null {
  const normalized = params.commandBody.trim()
  const match = normalized.match(/^\/([^\s]+)(?:\s+([\s\S]+))?$/)
  if (!match?.[1]) return null

  const command = findInlineNativeCommandFromBody(normalized)
  if (!command) return null

  const args = parseCommandArgs(command, match[2])
  const menuNeedsModelContext =
    command.argsMenu &&
    !(args?.raw && !args.values) &&
    command.args?.some(
      (arg) => typeof arg.choices === "function" && args?.values?.[arg.name] == null,
    )
  const menuModelContext = menuNeedsModelContext
    ? resolveInlineCommandMenuModelContext({
        cfg: params.cfg,
        agentId: params.agentId,
        sessionKey: params.sessionKey,
      })
    : {}
  const menu = resolveCommandArgMenu({
    command,
    ...(args ? { args } : {}),
    cfg: params.cfg,
    ...menuModelContext,
  })
  if (!menu) return null

  const currentThinkingLevel =
    command.key === "think"
      ? resolveInlineThinkMenuCurrentLevel({
          cfg: params.cfg,
          agentId: params.agentId,
          ...menuModelContext,
        })
      : undefined
  const title = formatInlineCommandArgMenuTitle({
    command,
    menu,
    ...(currentThinkingLevel ? { currentThinkingLevel } : {}),
  })
  const rows: InlineReplyMarkupButton[][] = []
  for (let index = 0; index < menu.choices.length; index += 2) {
    const slice = menu.choices.slice(index, index + 2)
    rows.push(
      slice.map((choice) => ({
        text: choice.label,
        callback_data: buildInlineNativeCommandCallbackData(
          buildCommandTextFromArgs(command, {
            values: { [menu.arg.name]: choice.value },
          }),
        ),
      })),
    )
  }

  return { title, buttons: rows }
}

function mapInlineModelPickerCallbackToCommand(raw: string): string | undefined {
  const callback = parseInlineModelPickerCallback(raw)
  if (!callback) return undefined
  switch (callback.type) {
    case "providers":
    case "back":
      return "/models"
    case "list":
      return `/models ${callback.provider} ${String(callback.page)}`
    case "select":
      return callback.provider ? `/model ${callback.provider}/${callback.model}` : `/model ${callback.model}`
  }
}

function parseInlineModelPickerCallback(raw: string): InlineModelPickerCallback | null {
  const trimmed = raw.trim()
  if (!trimmed) return null

  if (trimmed === "mdl_prov") return { type: "providers" }
  if (trimmed === "mdl_back") return { type: "back" }

  const listMatch = trimmed.match(/^mdl_list_([a-z0-9_.-]+)_(\d+)$/i)
  if (listMatch?.[1] && listMatch[2]) {
    const provider = listMatch[1].trim()
    const page = Number.parseInt(listMatch[2], 10)
    if (provider && Number.isFinite(page) && page > 0) {
      return { type: "list", provider, page }
    }
  }

  const standardSelectionMatch = trimmed.match(/^mdl_sel_(.+)$/)
  if (standardSelectionMatch?.[1]?.trim()) {
    const modelRef = standardSelectionMatch[1].trim()
    const slashIndex = modelRef.indexOf("/")
    if (slashIndex > 0 && slashIndex < modelRef.length - 1) {
      return {
        type: "select",
        provider: modelRef.slice(0, slashIndex),
        model: modelRef.slice(slashIndex + 1),
      }
    }
  }

  const compactSelectionMatch = trimmed.match(/^mdl_sel\/(.+)$/)
  if (compactSelectionMatch?.[1]?.trim()) {
    return { type: "select", model: compactSelectionMatch[1].trim() }
  }

  return null
}

function resolveInlineModelPickerSelection(params: {
  callback: Extract<InlineModelPickerCallback, { type: "select" }>
  providers: readonly string[]
  byProvider: ReadonlyMap<string, ReadonlySet<string>>
}): InlineModelPickerSelection {
  if (params.callback.provider) {
    return {
      kind: "resolved",
      provider: params.callback.provider,
      model: params.callback.model,
    }
  }

  const matchingProviders = params.providers.filter((id) => params.byProvider.get(id)?.has(params.callback.model))
  if (matchingProviders.length === 1 && matchingProviders[0]) {
    return {
      kind: "resolved",
      provider: matchingProviders[0],
      model: params.callback.model,
    }
  }

  return {
    kind: "ambiguous",
    model: params.callback.model,
  }
}

function normalizeInlineActionCallbackData(raw: string): string {
  const trimmed = raw.trim()
  if (!trimmed) return ""
  const nativeCommandText = parseInlineNativeCommandCallbackData(trimmed)
  if (nativeCommandText) return nativeCommandText
  return mapInlineModelPickerCallbackToCommand(trimmed) ?? trimmed
}

function normalizeCompatibleButtonCallbackData(raw: string): string {
  const trimmed = raw.trim()
  if (!trimmed) return ""
  if (parseInlineModelPickerCallback(trimmed)) return trimmed
  return normalizeInlineActionCallbackData(trimmed)
}

type InlineParsedReplyActionButton =
  | {
      text: string
      kind: "callback"
      callbackData: string
    }
  | {
      text: string
      kind: "copyText"
      copyText: string
    }

function normalizeReplyMarkupButtonsWith(
  raw: unknown,
  options?: { mapCallbackData?: (value: string) => string },
): InlineParsedReplyActionButton[][] {
  if (!Array.isArray(raw)) return []

  const rows: InlineParsedReplyActionButton[][] = []
  for (const candidateRow of raw) {
    if (!Array.isArray(candidateRow)) continue
    const row: InlineParsedReplyActionButton[] = []
    for (const candidateButton of candidateRow) {
      if (!isRecord(candidateButton)) continue
      const text = sanitizeInlineActionLabel(
        typeof candidateButton.text === "string" ? candidateButton.text : "",
      )
      const callbackDataRaw =
        typeof candidateButton.callback_data === "string" ? candidateButton.callback_data.trim() : ""
      const mappedCallbackData = options?.mapCallbackData
        ? options.mapCallbackData(callbackDataRaw)
        : callbackDataRaw
      const callbackData = sanitizeInlineActionCallbackData(mappedCallbackData)
      const copyText = sanitizeInlineActionCopyText(
        typeof candidateButton.copy_text === "string"
          ? candidateButton.copy_text
          : typeof candidateButton.copyText === "string"
            ? candidateButton.copyText
            : "",
      )
      if (!text) continue
      if (callbackData) {
        row.push({ text, kind: "callback", callbackData })
      } else if (copyText) {
        row.push({ text, kind: "copyText", copyText })
      }
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
    // Backwards compatibility for replies emitted before Inline had its own command surface.
    rawButtons = telegramData.buttons
    hasExplicitButtons = true
    mapCallbackData = normalizeCompatibleButtonCallbackData
  } else if (Object.prototype.hasOwnProperty.call(payload, "buttons")) {
    rawButtons = payload.buttons
    hasExplicitButtons = true
  }

  if (!hasExplicitButtons) {
    return resolveInlineMessageActionsParam(payload)
  }

  const rows = normalizeReplyMarkupButtonsWith(
    rawButtons,
    mapCallbackData ? { mapCallbackData } : undefined,
  )
  return {
    rows: rows.map((row, rowIndex) => ({
      actions: row.map((button, buttonIndex) => ({
        actionId: `btn_${rowIndex + 1}_${buttonIndex + 1}`,
        text: button.text,
        action:
          button.kind === "callback"
            ? {
                oneofKind: "callback" as const,
                callback: {
                  data: new TextEncoder().encode(button.callbackData),
                },
              }
            : {
                oneofKind: "copyText" as const,
                copyText: {
                  text: button.copyText,
                },
              },
      })),
    })),
  }
}

async function answerInlineMessageAction(
  client: InlineSdkClient,
  interactionId: bigint,
  ui?: MessageActionResponseUi,
): Promise<void> {
  const withAnswer = client as InlineSdkClient & {
    answerMessageAction?: (params: { interactionId: bigint; ui?: MessageActionResponseUi }) => Promise<void>
    invokeUncheckedRaw?: (
      method: Method,
      input?: {
        oneofKind?: string
        answerMessageAction?: { interactionId: bigint; ui?: MessageActionResponseUi }
      },
    ) => Promise<unknown>
  }

  if (typeof withAnswer.answerMessageAction === "function") {
    await withAnswer.answerMessageAction({ interactionId, ...(ui ? { ui } : {}) })
    return
  }

  const answerMethod = (Method as Record<string, unknown>)["ANSWER_MESSAGE_ACTION"]
  if (typeof answerMethod === "number" && typeof withAnswer.invokeUncheckedRaw === "function") {
    await withAnswer.invokeUncheckedRaw(answerMethod as Method, {
      oneofKind: "answerMessageAction",
      answerMessageAction: { interactionId, ...(ui ? { ui } : {}) },
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

function buildInlineSenderName(params: {
  firstName: string | undefined
  lastName: string | undefined
}): string | undefined {
  const name = [params.firstName, params.lastName].filter(Boolean).join(" ").trim()
  return name || undefined
}

function mergeInlineSenderProfile(params: {
  senderProfilesById: Map<string, SenderProfile>
  user: User
}): void {
  const userId = String(params.user.id)
  if (!userId) return

  const nextName = buildInlineSenderName({ firstName: params.user.firstName, lastName: params.user.lastName })
  const nextUsername = normalizeInlineUsername(params.user.username)
  const previous = params.senderProfilesById.get(userId)
  const mergedName = nextName ?? previous?.name
  const mergedUsername = nextUsername ?? previous?.username

  if (!mergedName && !mergedUsername) return
  params.senderProfilesById.set(userId, {
    ...(mergedName ? { name: mergedName } : {}),
    ...(mergedUsername ? { username: mergedUsername } : {}),
  })
}

function resolveInlineSystemPrompt(params: {
  account: ResolvedInlineAccount
  groupId?: string
  replyThread?: boolean
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
  ]
    .filter((entry): entry is string => Boolean(entry))
    .join("\n\n")
}

function hasExplicitInlineReplyThreadIntent(raw: string): boolean {
  const text = normalizeLowercaseStringOrEmpty(raw).replace(/\s+/g, " ").trim()
  if (!text) return false
  if (INLINE_REPLY_THREAD_NEGATION_RE.test(text)) return false
  return INLINE_REPLY_THREAD_INTENT_RE.test(text)
}

function shouldCreateInlineReplyThreadDelivery(params: {
  mode: InlineReplyThreadMode
  explicitThreadIntent: boolean
  messageId: bigint
  minMessages: number
}): boolean {
  if (params.mode === "main") return false
  if (params.explicitThreadIntent) return true
  return (
    params.mode === "thread" &&
    shouldAutoCreateInlineReplyThread({
      messageId: params.messageId,
      minMessages: params.minMessages,
    })
  )
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

function rememberInlineBotDelivery(params: {
  botMessageIdsByChat: Map<string, string[]>
  chatId: bigint
  messageId: bigint
  accountId: string
  agentId: string
  replyThreadContext?: InlineReplyThreadContext | null
}): void {
  rememberBotMessageId(params.botMessageIdsByChat, params.chatId, params.messageId)
  if (!params.replyThreadContext || params.chatId !== params.replyThreadContext.childChatId) return
  recordInlineThreadParticipation(
    params.accountId,
    params.replyThreadContext.parentChatId,
    params.replyThreadContext.childChatId,
    { agentId: params.agentId },
  )
  rememberInlineReplyThreadRoute({
    accountId: params.accountId,
    parentChatId: params.replyThreadContext.parentChatId,
    threadId: params.replyThreadContext.childChatId,
    parentMessageId: params.replyThreadContext.parentMessageId,
    threadLabel: params.replyThreadContext.threadLabel,
    agentId: params.agentId,
  })
}

function hasBotMessageId(cache: Map<string, string[]>, chatId: bigint, messageId: bigint): boolean {
  const key = String(chatId)
  return (cache.get(key) ?? []).includes(String(messageId))
}

function hasKnownBotMessageInChat(cache: Map<string, string[]>, chatId: bigint): boolean {
  return (cache.get(String(chatId)) ?? []).length > 0
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

function buildInlineReplyThreadLabel(params: {
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
  return resolveInlineSenderLabel({
    senderId,
    senderName: profile?.name,
    senderUsername: profile?.username,
  })
}

function resolveInlineSenderLabel(params: {
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

function resolveInlineConversationLabel(params: {
  isGroup: boolean
  groupTitle?: string | null
  groupId: string
  senderLabel: string
}): string {
  if (!params.isGroup) return params.senderLabel
  const title = params.groupTitle?.trim()
  return title ? `${title} id:${params.groupId}` : `group:${params.groupId}`
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
  if (entry.messageId) return `id:${entry.messageId}:ts:${entry.timestamp ?? "unknown"}`
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
  const hasBotMessage = params.historyContext.hasBotMessage || params.anchorMessage.fromId === params.meId
  if (!entry.inboundEntry || !entry.line) {
    return {
      ...params.historyContext,
      hasBotMessage,
    }
  }

  return {
    ...params.historyContext,
    inboundHistory: [entry.inboundEntry, ...params.historyContext.inboundHistory],
    hasBotMessage,
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

function prependInlineParentHistoryContext(params: {
  historyContext: HistoryContext
  parentHistoryContext: HistoryContext
}): HistoryContext {
  return {
    ...params.historyContext,
    inboundHistory: [
      ...params.parentHistoryContext.inboundHistory,
      ...params.historyContext.inboundHistory,
    ],
    hasBotMessage: params.historyContext.hasBotMessage || params.parentHistoryContext.hasBotMessage,
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

function buildInlineUntrustedStructuredContext(params: {
  currentAttachmentText: string | null
  currentEntityText: string | null
  currentBody: string
  historyAttachmentText: string | null
  historyEntityText: string | null
}): InlineUntrustedStructuredContextEntry[] {
  const entries: InlineUntrustedStructuredContextEntry[] = []
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
  return entries
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
      const fetchedContentType = fetched.contentType ?? candidate.mimeType ?? undefined
      const saved = await params.core.channel.media.saveMediaBuffer(
        fetched.buffer,
        fetchedContentType,
        "inbound",
        params.maxBytes,
        fetched.fileName ?? candidate.fileName ?? undefined,
      )
      const contentType = saved.contentType ?? fetchedContentType
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

async function resolveInlineReplyThreadContextFromRoute(params: {
  route: InlineReplyThreadRouteRecord
  client: InlineSdkClient
  chatCache: Map<bigint, CachedChatInfo>
  fallbackParentChatTitle: string | null
}): Promise<InlineReplyThreadContext | null> {
  const parentChatId = parseCachedInlineId(params.route.parentChatId)
  const childChatId = parseCachedInlineId(params.route.threadId)
  if (parentChatId == null || childChatId == null) {
    return null
  }
  const parentMessageId = parseCachedInlineId(params.route.parentMessageId)
  const parentChatInfo = await resolveChatInfo(params.client, params.chatCache, parentChatId).catch(() => ({
    kind: "group" as const,
    title: params.fallbackParentChatTitle,
  }))
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
    parentChatTitle: parentChatInfo.title ?? params.fallbackParentChatTitle,
    parentMessageId,
    threadLabel: buildInlineReplyThreadLabel({
      title: labelSource,
      anchorMessage,
    }),
    anchorMessage,
  }
}

function normalizeInlineReplyThreadMode(raw: unknown): InlineReplyThreadMode {
  return raw === "thread" || raw === "main" ? raw : "auto"
}

function shouldAutoCreateInlineReplyThread(params: {
  messageId: bigint
  minMessages: number
}): boolean {
  if (params.minMessages <= 0) return true
  return params.messageId >= BigInt(params.minMessages)
}

async function buildReplyThreadParentHistoryContext(params: {
  client: InlineSdkClient
  replyThreadContext: InlineReplyThreadContext
  parentHistoryLimit: number
  senderProfilesById: Map<string, SenderProfile>
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
  let hasBotMessage = hasKnownBotMessageInChat(params.botMessageIdsByChat, params.chatId)
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
          hasBotMessage = true
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
      hasBotMessage = hasBotMessage || repliedToBot
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
      hasBotMessage,
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
    hasBotMessage,
  }
}

function buildInlineRecentHistoryLines(params: {
  messages: Message[]
  senderProfilesById: Map<string, SenderProfile>
  meId: bigint
  maxLines: number
}): string[] {
  if (params.maxLines <= 0) return []

  return params.messages
    .slice()
    .sort((a, b) => {
      const byDate = Number(a.date - b.date)
      if (byDate !== 0) return byDate
      if (a.id === b.id) return 0
      return a.id < b.id ? -1 : 1
    })
    .map((message) => buildInlineHistoryEntryPayload({
      message,
      senderProfilesById: params.senderProfilesById,
      meId: params.meId,
    }))
    .map((entry) => entry.line ?? entry.attachmentLine ?? entry.entityLine)
    .filter((line): line is string => Boolean(line))
    .slice(-params.maxLines)
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
  const { cfg, account, runtime, abortSignal, log, statusSink } = params
  const core = getInlineRuntime()

  if (!account.configured || !account.baseUrl) {
    throw new Error(`Inline not configured for account "${account.accountId}" (missing baseUrl or token)`)
  }
  const token = await resolveInlineToken(account)

  const stateDir = core.state.resolveStateDir()
  const statePath = path.join(stateDir, "channels", "inline", `${account.accountId}.json`)
  const hasExistingState = await stat(statePath).then(() => true).catch(() => false)
  await mkdir(path.dirname(statePath), { recursive: true })

  let client: InlineSdkClient | null = null
  const pushDiagnostics = (patch?: Parameters<StatusSink>[0]) => {
    statusSink?.({
      ...patch,
      ...(client ? { diagnostics: client.getDiagnostics() } : {}),
    })
  }
  const sdkLog = {
    debug: (msg: string, meta?: unknown) => log?.debug?.(formatSdkLogLine(msg, meta)),
    info: (msg: string, meta?: unknown) => log?.info(formatSdkLogLine(msg, meta)),
    warn: (msg: string, meta?: unknown) => {
      const line = formatSdkLogLine(msg, meta)
      log?.warn(line)
      pushDiagnostics({ lastError: line })
    },
    error: (msg: string, meta?: unknown) => {
      const line = formatSdkLogLine(msg, meta)
      log?.error(line)
      pushDiagnostics({ lastError: line })
    },
  }

  client = new InlineSdkClient({
    baseUrl: account.baseUrl,
    token,
    logger: sdkLog,
    state: new JsonFileStateStore(statePath),
    catchUpUserFromStart: hasExistingState,
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
    })
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
    throw new Error(message)
  }
  if (!meUser) {
    throw new Error("inline startup getMe failed: missing user")
  }
  const meId = meUser.id
  const botUsername = normalizeInlineUsername(meUser.username)?.toLowerCase()
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
  const senderProfilesById = new Map<string, SenderProfile>()
  const botMessageIdsByChat = new Map<string, string[]>()
  const groupPendingHistories = new Map<string, InlinePendingHistoryEntry[]>()
  const hydratedParticipantChats = new Set<string>()
  const participantFetches = new Map<string, Promise<void>>()
  let cachedDirectoryUserProfilesHydrated = false
  let cachedDirectoryUserProfilesFetch: Promise<void> | null = null
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
        mergeInlineSenderProfile({ senderProfilesById, user })
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

  const hydrateCachedDirectoryUserProfiles = async (): Promise<void> => {
    if (cachedDirectoryUserProfilesHydrated) return
    if (cachedDirectoryUserProfilesFetch) return cachedDirectoryUserProfilesFetch

    const run = (async () => {
      const result = await client.invokeRaw(Method.GET_CHATS, {
        oneofKind: "getChats",
        getChats: {},
      })
      if (result.oneofKind !== "getChats") return

      for (const user of result.getChats.users ?? []) {
        mergeInlineSenderProfile({ senderProfilesById, user })
      }
      cachedDirectoryUserProfilesHydrated = true
    })()
      .catch((err) => {
        statusSink?.({ lastError: `getChats failed: ${String(err)}` })
      })
      .finally(() => {
        cachedDirectoryUserProfilesFetch = null
      })

    cachedDirectoryUserProfilesFetch = run
    await run
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
      chatInfo = { kind: "group", title: null }
      statusSink?.({ lastError: `getChat failed: ${String(err)}` })
    }

    const isGroup = chatInfo.kind !== "direct"
    const replyThreadsEnabled = isInlineReplyThreadsEnabled({ cfg, accountId: account.accountId })
    const replyThreadContext = await resolveInlineInboundReplyThreadContext({
      replyThreadsEnabled,
      client,
      chatId: params.chatId,
      chatInfo,
      chatCache,
    }).catch((err) => {
      statusSink?.({ lastError: `getChat (system event reply thread) failed: ${String(err)}` })
      return null
    })
    const effectiveChatId = replyThreadContext?.parentChatId ?? params.chatId
    const effectiveChatInfo =
      replyThreadContext?.parentChatId != null
        ? { ...chatInfo, title: replyThreadContext.parentChatTitle ?? chatInfo.title }
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
      return {
        channelLabel: formatInlineSystemEventChannelLabel({
          chatInfo: effectiveChatInfo,
          effectiveChatId,
        }),
        sessionKey: replyThreadContext
          ? buildInlineReplyThreadSessionKey(route.sessionKey, replyThreadContext.childChatId)
          : route.sessionKey,
      }
    }

    const peerUserId = senderId ?? (chatInfo.peerUserId != null ? String(chatInfo.peerUserId) : null)
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
    return {
      channelLabel: formatInlineSystemEventChannelLabel({
        chatInfo,
        effectiveChatId: params.chatId,
      }),
      sessionKey: route.sessionKey,
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
    statusSink?.({
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
    statusSink?.({
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

    await hydrateChatParticipants(params.chatId)
    const senderId = String(params.senderId)
    const chatInfo = chatCache.get(params.chatId)
    let senderProfile = senderProfilesById.get(senderId)
    if (chatInfo?.kind === "direct" && !senderProfile?.name) {
      await hydrateCachedDirectoryUserProfiles()
      senderProfile = senderProfilesById.get(senderId)
    }
    const senderLabel = resolveInlineSenderLabel({
      senderId,
      senderName: senderProfile?.name ?? (chatInfo?.kind === "direct" ? chatInfo.title ?? undefined : undefined),
      senderUsername: senderProfile?.username,
    })

    const eventOptions = {
      sessionKey: ingress.sessionKey,
      contextKey: buildInlineReactionContextKey(params),
      // Older OpenClaw hosts use these compatibility fields to keep
      // untrusted reaction events from inheriting owner authority.
      forceSenderIsOwnerFalse: true,
      trusted: false,
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

  const queueInlineParticipantAddSystemEvent = async (params: {
    chatId: bigint
    participant?: { userId?: bigint; date?: bigint }
    seq?: number
  }): Promise<void> => {
    const participant = params.participant
    if (!participant || participant.userId !== meId) return

    const inboundAt = Date.now()
    statusSink?.({
      lastInboundAt: inboundAt,
      lastEventAt: inboundAt,
      ...createTransportActivityStatusPatch(inboundAt),
    })

    const ingress = await resolveInlineSystemEventContext({
      chatId: params.chatId,
      senderId: null,
      eventKind: "participant.add",
    })
    if (!ingress) return

    await hydrateChatParticipants(params.chatId)
    const recentMessages = await loadChatHistoryMessages({
      client,
      chatId: params.chatId,
      limit: 10,
    }).catch((err) => {
      statusSink?.({ lastError: `getChatHistory (participant add) failed: ${String(err)}` })
      return null
    })
    const freshness = resolveInlineThreadFreshness({
      messages: recentMessages,
      botUserId: meId,
      botUsername,
      participantDate: participant.date,
    })
    if (freshness.kind !== "existing") return

    const recentLines = buildInlineRecentHistoryLines({
      messages: freshness.preJoinMessages,
      senderProfilesById,
      meId,
      maxLines: 10,
    })
    const priorMentionLines = buildInlineRecentHistoryLines({
      messages: freshness.priorMentionMessages,
      senderProfilesById,
      meId,
      maxLines: 10,
    })

    const contextKey = buildInlineParticipantAddContextKey({
      chatId: params.chatId,
      userId: meId,
      ...(participant.date != null ? { participantDate: participant.date } : {}),
      ...(params.seq != null ? { seq: params.seq } : {}),
    })
    core.system.enqueueSystemEvent(
      describeInlineParticipantAddSystemEvent({
        channelLabel: ingress.channelLabel,
        recentLines,
        priorMentionLines,
      }),
      {
        sessionKey: ingress.sessionKey,
        contextKey,
        forceSenderIsOwnerFalse: true,
        trusted: false,
      },
    )
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
      statusSink?.({ lastError: `getChatHistory (reaction target) failed: ${String(err)}` })
      return false
    })
  }

  const handleInboundNow = async (input: InlineParsedInboundEvent): Promise<void> => {
    const chatId = input.chatId
    const msg = input.msg
    const rawBodyOverride = input.rawBodyOverride ?? null
    const callbackActionEvent = input.callbackActionEvent ?? null
    let rawBody = ""
    let currentContent: ReturnType<typeof summarizeInlineMessageContent> | null = null
    let currentAttachmentText: string | null = null
    let currentEntityText: string | null = null

    if (!callbackActionEvent) {
      if (rawBodyOverride != null) {
        rawBody = rawBodyOverride.trim()
      } else {
        currentContent = summarizeInlineMessageContent(msg)
        rawBody = buildInlineInboundBodyText(currentContent)
        currentAttachmentText = currentContent.attachmentText || null
        currentEntityText = currentContent.entityText || null
      }
      if (!rawBody) return
    }

    const inboundAt = Date.now()
    statusSink?.({
      lastInboundAt: inboundAt,
      lastEventAt: inboundAt,
      ...createTransportActivityStatusPatch(inboundAt),
    })

    let chatInfo: CachedChatInfo
    try {
      chatInfo = await resolveChatInfo(client, chatCache, chatId)
    } catch (err) {
      // Default conservative behavior if metadata fetch fails.
      chatInfo = { kind: "group", title: null }
      statusSink?.({ lastError: `getChat failed: ${String(err)}` })
    }

    const isGroup = chatInfo.kind !== "direct"
    const inlineThreadDefaults = (cfg.channels?.inline ?? {}) as {
      replyThreadMode?: unknown
      replyThreadAutoCreateMinMessages?: number
      replyThreadRequireExplicitMention?: boolean
      replyThreadParentHistoryLimit?: number
    }
    const replyThreadsEnabled = isInlineReplyThreadsEnabled({ cfg, accountId: account.accountId })
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
    const replyThreadMode =
      isGroup && replyThreadsEnabled
        ? resolveInlineGroupReplyThreadMode({
            cfg,
            accountId: account.accountId,
            groupId: String(effectiveChatId),
            defaultMode: normalizeInlineReplyThreadMode(
              account.config.replyThreadMode ?? inlineThreadDefaults.replyThreadMode,
            ),
          })
        : "auto"
    const replyThreadAutoCreateMinMessages =
      isGroup && replyThreadsEnabled
        ? resolveInlineGroupReplyThreadAutoCreateMinMessages({
            cfg,
            accountId: account.accountId,
            groupId: String(effectiveChatId),
            defaultMinMessages:
              account.config.replyThreadAutoCreateMinMessages ??
              inlineThreadDefaults.replyThreadAutoCreateMinMessages ??
              DEFAULT_REPLY_THREAD_AUTO_CREATE_MIN_MESSAGES,
          })
        : DEFAULT_REPLY_THREAD_AUTO_CREATE_MIN_MESSAGES
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
      isGroup && replyThreadsEnabled
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
    const senderId = String(msg.fromId)
    await hydrateChatParticipants(chatId)
    let senderProfile = senderProfilesById.get(senderId)
    if (!isGroup && !senderProfile?.name) {
      await hydrateCachedDirectoryUserProfiles()
      senderProfile = senderProfilesById.get(senderId)
    }
    const senderUsername = senderProfile?.username
    const senderName = senderProfile?.name ?? (!isGroup ? chatInfo.title ?? undefined : undefined)
    if (callbackActionEvent) {
      const actor =
        senderUsername != null && senderUsername.length > 0
          ? `@${senderUsername}`
          : senderName ?? `user:${senderId}`
      rawBody = `${actor} pressed "${callbackActionEvent.actionId}" on message #${String(callbackActionEvent.targetMessageId)}`
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
    const callbackCommandBody = callbackActionEvent
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
    const normalizedCommandBody = callbackCommandBody ?? normalizeInlineCommandBody(rawBody, botUsername)
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
    const inboundSessionKey =
      replyThreadContext && isGroup
        ? buildInlineReplyThreadSessionKey(route.sessionKey, replyThreadContext.childChatId)
        : route.sessionKey
    if (replyThreadContext && isGroup) {
      rememberInlineReplyThreadRoute({
        accountId: account.accountId,
        parentChatId: replyThreadContext.parentChatId,
        threadId: replyThreadContext.childChatId,
        parentMessageId: replyThreadContext.parentMessageId,
        threadLabel: replyThreadContext.threadLabel,
        agentId: route.agentId,
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
        replyThreadContext: params.replyThreadContext ?? null,
      })
    }
    const hasTextControlCommand = core.channel.text.hasControlCommand(
      callbackCommandBody ?? rawBody,
      cfg,
      botUsername ? { botUsername } : undefined,
    )
    const isRegisteredNativeCommand = isInlineNativeCommandBody({
      cfg,
      account,
      commandBody: normalizedCommandBody,
      agentId: route.agentId,
    })
    const hasControlCommand = hasTextControlCommand || isRegisteredNativeCommand
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
    const useAccessGroups = cfg.commands?.useAccessGroups !== false
    const allowForCommands = isGroup ? effectiveGroupCommandAllowFrom : effectiveAllowFrom
    const senderAllowedForCommands = allowlistMatch({ allowFrom: allowForCommands, senderId })
    const commandGate = resolveControlCommandGate({
      useAccessGroups,
      authorizers: [{ configured: allowForCommands.length > 0, allowed: senderAllowedForCommands }],
      allowTextCommands,
      hasControlCommand,
    })
    const commandAuthorized = resolveInlineCommandAuthorized({
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
        if (groupAccess.allowlistEnabled && !groupAccess.allowed && !nativeMentioned) {
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
          return
        }
      }
    }

    if (isGroup && shouldBlockControlCommand) {
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

    const mentionRegexes = core.channel.mentions.buildMentionRegexes(cfg, route.agentId)
    const patternMentioned = mentionRegexes.length
      ? core.channel.mentions.matchesMentionPatterns(rawBody, mentionRegexes)
      : false
    const wasMentioned = nativeMentioned || patternMentioned
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
      statusSink?.({ lastError: `getChatHistory failed: ${String(err)}` })
      return {
        historyText: null,
        attachmentText: null,
        entityText: null,
        inboundHistory: [],
        repliedToBot: false,
        replyToSenderId: null,
        hasBotMessage: false,
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
    const hasReplyThreadParticipation =
      isGroup &&
      replyThreadContext != null &&
      !replyThreadRequireExplicitMention &&
      (effectiveHistoryContext.hasBotMessage ||
        await hasInlineThreadParticipationWithPersistence({
          accountId: account.accountId,
          parentChatId: replyThreadContext.parentChatId,
          threadId: replyThreadContext.childChatId,
        }))
    const replyThreadImplicitMention = hasReplyThreadParticipation
    const replyToBotImplicitMention =
      isGroup &&
      (account.config.replyToBotWithoutMention ?? false) &&
      msg.replyToMsgId != null &&
      effectiveHistoryContext.repliedToBot
    const implicitMention =
      (callbackActionEvent != null && isGroup) ||
      replyThreadImplicitMention ||
      replyToBotImplicitMention

    const requireMention = isGroup
      ? resolveInlineGroupRequireMention({
          cfg,
          groupId: String(effectiveChatId),
          accountId: account.accountId,
          requireMentionDefault: account.config.requireMention ?? INLINE_DEFAULT_REQUIRE_MENTION,
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
    const implicitMentionKinds =
      isGroup && implicitMention
        ? [
            ...(callbackActionEvent != null ? ["message_action"] : []),
            ...(replyThreadImplicitMention ? ["reply_thread"] : []),
            ...(replyToBotImplicitMention ? ["reply_to_bot"] : []),
          ]
        : []
    const mentionedUserIds = isGroup ? collectInlineMentionedUserIds(currentContent) : []
    const mentionSource = isGroup
      ? resolveInlineMentionSource({
          nativeMentioned,
          patternMentioned,
          implicitMention,
          shouldBypassMention: mentionGate.shouldBypassMention,
          wasMentioned: mentionGate.effectiveWasMentioned,
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
        runtime.error?.("inline /threadreply fallback unavailable: runtime config API missing")
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
        const resultRecord = result as Record<string, unknown>
        const actions = resolveInlineReplyActions(resultRecord)
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
                  `inline /threadreply edit: expected editMessage result, got ${String(editResult.oneofKind)}`,
                )
              }
              delivered = true
            } catch (error) {
              runtime.error?.(`inline /threadreply edit failed; falling back to send (${String(error)})`)
            }
          }
          if (!delivered) {
            const sent = await client.sendMessage({
              chatId,
              text,
              ...(actions ? { actions } : {}),
              parseMarkdown,
            })
            rememberSentBotMessage({ chatId, messageId: sent.messageId, replyThreadContext })
          }
          statusSink?.({ lastOutboundAt: Date.now() })
        }

        await answerCallbackIfNeeded().catch((error) => {
          runtime.error?.(`inline callback answer failed: ${String(error)}`)
        })
        return
      }
    }
    const commandsPageCallback = callbackActionEvent
      ? parseInlineCommandsPageCallback(callbackDataToUtf8(callbackActionEvent.data))
      : null
    if (shouldEditCallbackTargetInPlace && callbackActionEvent && commandsPageCallback) {
      if (commandsPageCallback.page === "noop") return

      const agentId = commandsPageCallback.agentId ?? route.agentId
      const paginated = buildCommandsMessagePaginated(
        cfg,
        listSkillCommandsForAgents({
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
      }) ?? { rows: [] }
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
        const sent = await client.sendMessage({
          chatId,
          text,
          actions,
          parseMarkdown,
        })
        rememberSentBotMessage({ chatId, messageId: sent.messageId, replyThreadContext })
      }
      statusSink?.({ lastOutboundAt: Date.now() })
      return
    }

    const nativeCommandMenu = resolveInlineNativeCommandMenu({
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
      })
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
        const sent = await client.sendMessage({
          chatId,
          text: menuText,
          ...(menuActions ? { actions: menuActions } : {}),
        })
        rememberSentBotMessage({ chatId, messageId: sent.messageId, replyThreadContext })
      }
      statusSink?.({ lastOutboundAt: Date.now() })
      await answerCallbackIfNeeded().catch((error) => {
        runtime.error?.(`inline callback answer failed: ${String(error)}`)
      })
      return
    }

    const modelPickerCallbackData = callbackActionEvent ? callbackDataToUtf8(callbackActionEvent.data) : undefined
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
        }) ?? { rows: [] }
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
          const sent = await client.sendMessage({
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
            const storePath = core.channel.session.resolveStorePath(cfg.session?.store, {
              agentId: route.agentId,
            })
            const resolvedDefault = resolveDefaultModelForAgent({
              cfg,
              agentId: route.agentId,
            })
            const isDefaultSelection =
              selection.provider === resolvedDefault.provider && selection.model === resolvedDefault.model

            await updateSessionStore(storePath, (store) => {
              const entry = store[inboundSessionKey] ?? {
                sessionId: inboundSessionKey,
                updatedAt: Date.now(),
              }
              store[inboundSessionKey] = entry
              applyModelOverrideToSessionEntry({
                entry,
                selection: {
                  provider: selection.provider,
                  model: selection.model,
                  isDefault: isDefaultSelection,
                },
              })
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

      statusSink?.({ lastOutboundAt: Date.now() })
      await answerCallbackIfNeeded().catch((error) => {
        runtime.error?.(`inline callback answer failed: ${String(error)}`)
      })
      return
    }

    let deliveryReplyThreadContext = replyThreadContext
    const explicitReplyThreadIntent =
      isGroup &&
      replyThreadsEnabled &&
      !deliveryReplyThreadContext &&
      hasExplicitInlineReplyThreadIntent(rawBody)
    const shouldCreateDeliveryThread =
      isGroup &&
      replyThreadsEnabled &&
      !deliveryReplyThreadContext &&
      shouldCreateInlineReplyThreadDelivery({
        mode: replyThreadMode,
        explicitThreadIntent: explicitReplyThreadIntent,
        messageId: msg.id,
        minMessages: replyThreadAutoCreateMinMessages,
      }) &&
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
        statusSink?.({ lastError: `reply-thread route lookup failed: ${String(error)}` })
        runtime.error?.(`inline reply-thread route lookup failed: ${String(error)}`)
        return null
      })
      if (cachedRoute) {
        deliveryReplyThreadContext = await resolveInlineReplyThreadContextFromRoute({
          route: cachedRoute,
          client,
          chatCache,
          fallbackParentChatTitle: effectiveGroupTitle,
        }).catch((error) => {
          statusSink?.({ lastError: `reply-thread route restore failed: ${String(error)}` })
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
        statusSink?.({ lastError: `createSubthread failed: ${String(error)}` })
        runtime.error?.(`inline create reply thread failed: ${String(error)}`)
        return null
      })

      if (createdThread) {
        deliveryReplyThreadContext = {
          childChatId: createdThread.childChatId,
          parentChatId: createdThread.parentChatId,
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
          fallbackParentChatTitle: effectiveGroupTitle,
        }).catch(() => null)
      }
    }
    if (shouldCreateDeliveryThread && !deliveryReplyThreadContext) {
      runtime.error?.("inline create reply thread failed; falling back to parent chat delivery")
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
          hasBotMessage: effectiveHistoryContext.hasBotMessage,
        },
        anchorMessage: deliveryReplyThreadContext.anchorMessage,
        parentChatId: deliveryReplyThreadContext.parentChatId,
        senderProfilesById,
        meId,
      })
    }
    if (deliveryReplyThreadContext) {
      const parentHistoryContext = await buildReplyThreadParentHistoryContext({
        client,
        replyThreadContext: deliveryReplyThreadContext,
        parentHistoryLimit: replyThreadParentHistoryLimit,
        senderProfilesById,
        meId,
        botMessageIdsByChat,
      }).catch((err) => {
        statusSink?.({ lastError: `getChatHistory (reply thread parent) failed: ${String(err)}` })
        return null
      })
      if (parentHistoryContext) {
        effectiveHistoryContext = prependInlineParentHistoryContext({
          historyContext: effectiveHistoryContext,
          parentHistoryContext,
        })
      }
    }

    const deliveryChatId = deliveryReplyThreadContext?.childChatId ?? chatId
    const typingChatIds = uniqueInlineChatIds([
      deliveryChatId,
      !replyThreadContext && deliveryReplyThreadContext ? deliveryReplyThreadContext.parentChatId : null,
    ])
    const deliverySessionKey =
      deliveryReplyThreadContext && isGroup
        ? buildInlineReplyThreadSessionKey(route.sessionKey, deliveryReplyThreadContext.childChatId)
        : route.sessionKey
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
    const untrustedStructuredContext = buildInlineUntrustedStructuredContext({
      currentAttachmentText,
      currentEntityText: currentEntityTextForAgent,
      currentBody,
      historyAttachmentText: effectiveHistoryContext.attachmentText,
      historyEntityText: effectiveHistoryContext.entityText,
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
    const systemPrompt = resolveInlineSystemPrompt({
      account,
      ...(isGroup ? { groupId: String(effectiveChatId) } : {}),
      replyThread: Boolean(deliveryReplyThreadContext),
    })
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
      BodyForCommands: normalizedCommandBody,
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
      ...(untrustedStructuredContext.length > 0
        ? { UntrustedStructuredContext: untrustedStructuredContext }
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
      ...buildInlineInboundMediaPayload(inboundMedia),
      Timestamp: timestamp || Date.now(),
      ...(isGroup ? { WasMentioned: mentionGate.effectiveWasMentioned } : {}),
      ...(isGroup
        ? {
            ExplicitlyMentionedBot: nativeMentioned,
            ...(mentionedUserIds.length > 0 ? { MentionedUserIds: mentionedUserIds } : {}),
            ...(implicitMentionKinds.length > 0 ? { ImplicitMentionKinds: implicitMentionKinds } : {}),
            MentionSource: mentionSource,
          }
        : {}),
      CommandAuthorized: commandAuthorized,
      GroupSystemPrompt: systemPrompt,
      OriginatingChannel: CHANNEL_ID,
      OriginatingTo: `inline:${String(effectiveChatId)}`,
    })

    await core.channel.session.recordInboundSession({
      storePath,
      sessionKey: ctxPayload.SessionKey ?? deliverySessionKey,
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
        start: () =>
          sendInlineTypingToChats({
            client,
            chatIds: typingChatIds,
            typing: true,
            onPartialError: (chatId, error) =>
              runtime.error?.(`inline typing start failed for chat ${String(chatId)}: ${String(error)}`),
          }),
        stop: () =>
          sendInlineTypingToChats({
            client,
            chatIds: typingChatIds,
            typing: false,
            onPartialError: (chatId, error) =>
              runtime.error?.(`inline typing stop failed for chat ${String(chatId)}: ${String(error)}`),
          }),
        onStartError: (err) => runtime.error?.(`inline typing start failed: ${String(err)}`),
        onStopError: (err) => runtime.error?.(`inline typing stop failed: ${String(err)}`),
      },
    })
    const onModelSelected = replyPipeline.onModelSelected
    const rawTypingCallbacks = replyPipeline.typingCallbacks
    const botPresenceLifecycle = createInlineBotPresenceLifecycle({
      client,
      chatIds: typingChatIds,
      onPartialError: (chatId, error) =>
        runtime.error?.(`inline bot presence failed for chat ${String(chatId)}: ${String(error)}`),
      onError: (error) => runtime.error?.(`inline bot presence failed: ${String(error)}`),
    })
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
                  rawTypingCallbacks.onCleanup?.()
                  botPresenceLifecycle.cleanup()
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
    const canReplyToSourceMessage = deliveryChatId === chatId
    const defaultReplyToMsgId =
      canReplyToSourceMessage && isGroup && msg.replyToMsgId != null ? msg.id : undefined
    const inlineBlockStreamingEnabled = resolveInlineBlockStreamingEnabled(account.config)
    const disableBlockStreaming =
      progressPlaceholderEnabled || streamViaEditMessage
        ? true
        : typeof inlineBlockStreamingEnabled === "boolean"
        ? !inlineBlockStreamingEnabled
        : undefined
    const editStreamState: InlineEditStreamState = {
      messageId: shouldEditCallbackTargetInPlace ? callbackActionEvent?.targetMessageId ?? null : null,
      accumulatedText: callbackTargetMessage?.message ?? "",
      lastPartialText: "",
      finalTextAccumulator: "",
      failed: false,
      opChain: Promise.resolve(),
    }
    const progressSeed = `${account.accountId}:${String(deliveryChatId)}:${String(msg.id)}`
    const progressState: InlineProgressPlaceholderState = {
      messageId: null,
      text: "",
      lines: [],
      opChain: Promise.resolve(),
      closing: false,
    }
    const renderInlineProgressPlaceholder = async (): Promise<void> => {
      if (!progressPlaceholderEnabled || progressState.closing) return
      const text = sanitizeInlineDeliveryText(
        formatChannelProgressDraftText({
          entry: account.config,
          lines: progressState.lines,
          seed: progressSeed,
        }),
      ).trim()
      if (!text || text === progressState.text) return

      progressState.opChain = progressState.opChain
        .then(async () => {
          if (progressState.closing || text === progressState.text) return
          if (progressState.messageId == null) {
            const sent = await client.sendMessage({
              chatId: deliveryChatId,
              text,
              sendMode: "silent",
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
              },
            })
            if (result.oneofKind !== "editMessage") {
              throw new Error(
                `inline progress placeholder: expected editMessage result, got ${String(result.oneofKind)}`,
              )
            }
          }
          progressState.text = text
          statusSink?.({ lastOutboundAt: Date.now() })
        })
        .catch((error) => {
          runtime.error?.(`inline progress placeholder failed: ${String(error)}`)
        })

      await progressState.opChain
    }
    const progressDraftGate = createChannelProgressDraftGate({
      onStart: renderInlineProgressPlaceholder,
    })
    const pushInlineProgressPlaceholder = async (
      line?: string | ChannelProgressDraftLine,
      options?: { toolName?: string; startImmediately?: boolean },
    ): Promise<void> => {
      if (!progressPlaceholderEnabled || progressState.closing) return
      if (options?.toolName !== undefined && !isChannelProgressDraftWorkToolName(options.toolName)) {
        return
      }

      const normalized = typeof line === "string" ? line.replace(/\s+/g, " ").trim() : line?.text.trim()
      if (line && !normalized) return
      if (progressToolProgressEnabled && line && normalized) {
        const nextLines = mergeChannelProgressDraftLine(progressState.lines, line, {
          maxLines: resolveChannelProgressDraftMaxLines(account.config),
        })
        if (nextLines !== progressState.lines) {
          progressState.lines = nextLines
        }
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
    }
    const cleanupInlineProgressPlaceholder = async (): Promise<void> => {
      progressDraftGate.cancel()
      progressState.closing = true
      await progressState.opChain

      const messageId = progressState.messageId
      if (messageId == null) return

      try {
        const result = await client.invokeRaw(Method.DELETE_MESSAGES, {
          oneofKind: "deleteMessages",
          deleteMessages: {
            peerId: buildChatPeer(deliveryChatId),
            messageIds: [messageId],
          },
        })
        if (result.oneofKind !== "deleteMessages") {
          throw new Error(
            `inline progress placeholder: expected deleteMessages result, got ${String(result.oneofKind)}`,
          )
        }
      } catch (error) {
        runtime.error?.(`inline progress placeholder cleanup failed: ${String(error)}`)
      } finally {
        progressState.messageId = null
        progressState.text = ""
      }
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
    const handlePartialStreamPayload = async (payload: InlineReplyPayload): Promise<void> => {
      const visiblePayload = resolveInlineChatVisibleReplyPayload(payload)
      if (!visiblePayload) return
      if (editStreamState.failed) return
      if (resolveInlinePayloadMediaUrls(visiblePayload).length > 0) return
      const partialText = typeof visiblePayload.text === "string" ? visiblePayload.text : ""
      if (!partialText || partialText === editStreamState.lastPartialText) return
      editStreamState.lastPartialText = partialText

      const nextText = sanitizeInlineDeliveryText(
        rewriteNumericMentionsToUsernames(
          extractCompleteParagraphText(partialText),
          senderProfilesById,
        ),
      ).trim()
      if (!nextText || nextText === editStreamState.accumulatedText) return

      editStreamState.opChain = editStreamState.opChain.then(async () => {
        if (editStreamState.failed) return
        if (!nextText || nextText === editStreamState.accumulatedText) return

        try {
          if (editStreamState.messageId == null) {
            const sent = await client.sendMessage({
              chatId: deliveryChatId,
              text: nextText,
              ...(defaultReplyToMsgId != null ? { replyToMsgId: defaultReplyToMsgId } : {}),
              parseMarkdown,
            })
            if (sent.messageId == null) {
              throw new Error("inline edit stream: sendMessage returned no messageId")
            }
            editStreamState.messageId = sent.messageId
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
    const buildInlineProgressLineForEntry = (
      input: Parameters<typeof buildChannelProgressDraftLineForEntry>[1],
      options?: Parameters<typeof buildChannelProgressDraftLineForEntry>[2],
    ): ChannelProgressDraftLine | undefined =>
      buildChannelProgressDraftLineForEntry(account.config, input, options)

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
      ...(progressPlaceholderEnabled
        ? {
            onReasoningStream: async () => {
              botPresenceLifecycle.busy("review")
              await pushInlineProgressPlaceholder()
            },
          }
        : {}),
      onToolStart: async (payload: {
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
        await resetEditStreamOnBoundary()
        await pushInlineProgressPlaceholder(
          buildInlineProgressLineForEntry(
            {
              event: "tool",
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
              phase?: string
              title?: string
              explanation?: string
              steps?: string[]
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
        await resetEditStreamOnBoundary()
        await pushInlineProgressPlaceholder("Compacting context", {
          startImmediately: true,
        })
      },
      onCompactionEnd: async () => {
        botPresenceLifecycle.busy("running")
        if (!(streamViaEditMessage || progressPlaceholderEnabled)) return
        await resetEditStreamOnBoundary()
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
            ...dispatcherPipelineOptions,
            ...buildInlineTypingDispatcherOptions(typingCallbacks),
            deliver: async (
              payload: InlineReplyPayload,
              info?: InlineDispatchReplyInfo,
            ) => {
              const presenceSignal = resolveInlineBotPresenceSignal(payload)
              if (presenceSignal) {
                botPresenceLifecycle.express(presenceSignal)
              }

              const visiblePayload = resolveInlineChatVisibleReplyPayload(payload)
              if (!visiblePayload) return
              await cleanupInlineProgressPlaceholder()

              const payloadRecord = visiblePayload as InlineReplyPayload & {
                interactive?: unknown
                presentation?: unknown
              }
              const rawText =
                resolveInlineInteractiveTextFallback({
                  text: visiblePayload.text,
                  interactive: payloadRecord.interactive,
                  presentation: payloadRecord.presentation,
                }) ??
                visiblePayload.text ??
                ""
              const mediaList = resolveInlinePayloadMediaUrls(visiblePayload)
              const outboundText = sanitizeInlineDeliveryText(
                rewriteNumericMentionsToUsernames(rawText, senderProfilesById),
              )
              const outboundActions = resolveInlineReplyActions(visiblePayload as Record<string, unknown>)
              const infoKind = typeof info?.kind === "string" ? info.kind : undefined

              let replyToMsgId: bigint | undefined
              if (visiblePayload.replyToId != null) {
                try {
                  replyToMsgId = canReplyToSourceMessage ? BigInt(visiblePayload.replyToId) : undefined
                } catch {
                  // ignore
                }
              }
              // Keep reply chains threaded when inbound is a reply in group chats.
              if (replyToMsgId == null && canReplyToSourceMessage && isGroup && msg.replyToMsgId != null) {
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
                const sent = await client.sendMessage({
                  chatId: deliveryChatId,
                  text: outbound,
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
                const nextText = sanitizeInlineDeliveryText(text).trim()
                const textForEdit = nextText || editStreamState.accumulatedText
                if (!textForEdit && actions === undefined) return true
                const shouldSkipTextUpdate =
                  !editStreamState.failed && textForEdit === editStreamState.accumulatedText
                if (shouldSkipTextUpdate && actions === undefined) return true

                const result = await client.invokeRaw(Method.EDIT_MESSAGE, {
                  oneofKind: "editMessage",
                  editMessage: {
                    messageId: editStreamState.messageId,
                    peerId: buildChatPeer(deliveryChatId),
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
                if (shouldEditCallbackTargetInPlace && editStreamState.messageId != null) {
                  const callbackEditActions = outboundActions ?? { rows: [] }
                  if (!outboundText.trim() && outboundActions === undefined) {
                    return
                  }
                  await updateStreamedMessage(outboundText, callbackEditActions)
                  delivered = true
                  statusSink?.({ lastOutboundAt: Date.now() })
                  return
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
                    chatId: deliveryChatId,
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
              botPresenceLifecycle.fail()
              runtime.error?.(`inline ${info?.kind ?? "final"} reply failed: ${String(err)}`)
            },
          },
          replyOptions,
        })
      } catch (error) {
        dispatchError = error
        botPresenceLifecycle.fail()
        runtime.error?.(`inline dispatch failed: ${String(error)}`)
      }

      await cleanupInlineProgressPlaceholder()
      if (!delivered && streamViaEditMessage && editStreamState.messageId != null) {
        delivered = true
      }
      if (!delivered && (dispatchError != null || skippedNonSilent || failedNonSilent)) {
        botPresenceLifecycle.fail()
        const fallbackText =
          dispatchError != null
            ? INLINE_REQUEST_ERROR_FALLBACK
            : EMPTY_RESPONSE_FALLBACK
        const sent = await client.sendMessage({
          chatId: deliveryChatId,
          text: fallbackText,
          ...(defaultReplyToMsgId != null ? { replyToMsgId: defaultReplyToMsgId } : {}),
          parseMarkdown,
        })
        rememberSentBotMessage({
          chatId: deliveryChatId,
          messageId: sent.messageId,
          replyThreadContext: deliveryReplyThreadContext,
        })
        statusSink?.({ lastOutboundAt: Date.now() })
      }
    } finally {
      await setParentThreadCreationTyping(false)
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
    onFlush: async (entries) => {
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
      if (!combinedText.trim()) {
        return
      }

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
    onError: (err, items) => {
      runtime.error?.(`inline debounce flush failed: ${String(err)}`)
      const chatId = items[0]?.chatId
      if (chatId == null) return
      void client
        .sendMessage({
          chatId,
          text: INLINE_DEBOUNCE_ERROR_FALLBACK,
        })
        .then(() => {
          statusSink?.({ lastOutboundAt: Date.now() })
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

  const isAuthorizedInlineAbortMessage = async (entry: InlineDebounceEntry): Promise<boolean> => {
    if (!isInlineAbortRequestMessage(entry.msg, botUsername)) return false

    const senderId = entry.msg.fromId != null ? String(entry.msg.fromId) : null
    if (!senderId) return false

    let chatInfo: CachedChatInfo
    try {
      chatInfo = await resolveChatInfo(client, chatCache, entry.chatId)
    } catch (err) {
      chatInfo = { kind: "group", title: null }
      statusSink?.({ lastError: `getChat failed: ${String(err)}` })
    }

    const isGroup = chatInfo.kind !== "direct"
    const replyThreadsEnabled = isInlineReplyThreadsEnabled({ cfg, accountId: account.accountId })
    const replyThreadContext = await resolveInlineInboundReplyThreadContext({
      replyThreadsEnabled,
      client,
      chatId: entry.chatId,
      chatInfo,
      chatCache,
    }).catch((err) => {
      statusSink?.({ lastError: `getChat (abort reply thread) failed: ${String(err)}` })
      return null
    })
    const effectiveChatId = replyThreadContext?.parentChatId ?? entry.chatId
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
      const nativeMentioned = entry.msg.mentioned === true
      const groupAccess = resolveInlineGroupAccessPolicy({
        cfg,
        accountId: account.accountId,
        groupId: String(effectiveChatId),
        hasGroupAllowFrom: groupSenderAllowlist.raw.length > 0,
        groupPolicy,
      })
      if (groupAccess.allowlistEnabled && !groupAccess.allowed && !nativeMentioned) return false
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
      useAccessGroups: cfg.commands?.useAccessGroups !== false,
      authorizers: [
        {
          configured: effectiveGroupCommandAllowFrom.length > 0,
          allowed: senderAllowedForCommands,
        },
      ],
      allowTextCommands,
      hasControlCommand: true,
    })

    return resolveInlineCommandAuthorized({
      cfg,
      accountId: account.accountId,
      isGroup: true,
      chatId: String(effectiveChatId),
      senderId,
      commandAuthorized: commandGate.commandAuthorized,
    })
  }

  const scheduleInboundTask = (
    label: string,
    run: () => Promise<void>,
    options?: { serialKey?: string },
  ): void => {
    let task: Promise<void>
    try {
      if (options?.serialKey) {
        const serialKey = options.serialKey
        const previous = inboundTaskChains.get(serialKey) ?? Promise.resolve()
        task = previous.catch(() => undefined).then(run)
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
      statusSink?.({ lastError: message })
      runtime.error?.(`inline ${label} failed: ${message}`)
      return
    }

    const tracked = task
      .catch((error) => {
        const message = String(error)
        statusSink?.({ lastError: message })
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
      isInlineAbortRequestMessage(msg, botUsername) &&
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
    while (pendingInboundTasks.size > 0) {
      await Promise.allSettled(pendingInboundTasks)
    }
  }

  const loop = (async () => {
    try {
      for await (const event of client.events()) {
        if (abortSignal.aborted) break
        const rawEvent = event as Record<string, unknown>

        if (event.kind === "message.new") {
          const msg = {
            ...event.message,
            chatId: event.chatId,
          } as Message
          if (msg.out || msg.fromId === meId) continue
          if (
            isInlineAbortRequestMessage(msg, botUsername) &&
            await isAuthorizedInlineAbortMessage({ chatId: event.chatId, msg })
          ) {
            cancelPendingInlineDebounce({ chatId: event.chatId, msg })
            cancelPendingInlineVoiceMessages({ chatId: event.chatId, msg })
            scheduleImmediateInboundMessage(
              { chatId: event.chatId, msg },
              "priority abort dispatch",
            )
            continue
          }
          if (voiceTranscriptWaitMs > 0 && shouldWaitForInlineVoiceTranscript(msg)) {
            holdInlineVoiceMessage({
              chatId: event.chatId,
              msg,
            })
            continue
          }
          scheduleInboundMessage({
            chatId: event.chatId,
            msg,
          })
          continue
        }

        if (event.kind === "message.edit") {
          const msg = {
            ...event.message,
            chatId: event.chatId,
          } as Message
          if (msg.out || msg.fromId === meId) continue
          if (await handlePendingInlineVoiceEdit({ chatId: event.chatId, msg })) {
            continue
          }
          await queueInlineMessageLifecycleSystemEvent({
            action: "edited",
            chatId: event.chatId,
            messageIds: [msg.id],
            senderId: msg.fromId,
          })
          continue
        }

        if (event.kind === "message.delete") {
          await queueInlineMessageLifecycleSystemEvent({
            action: "deleted",
            chatId: event.chatId,
            messageIds: event.messageIds,
          })
          continue
        }

        if (event.kind === "reaction.add") {
          if (event.reaction.userId === meId) continue
          const shouldQueue = await shouldQueueInlineReactionSystemEvent({
            chatId: event.chatId,
            messageId: event.reaction.messageId,
            senderId: event.reaction.userId,
          })
          if (!shouldQueue) continue

          await queueInlineReactionSystemEvent({
            action: "added",
            chatId: event.chatId,
            messageId: event.reaction.messageId,
            senderId: event.reaction.userId,
            emoji: event.reaction.emoji,
          })
          continue
        }

        if (event.kind === "reaction.delete") {
          if (event.userId === meId) continue
          const shouldQueue = await shouldQueueInlineReactionSystemEvent({
            chatId: event.chatId,
            messageId: event.messageId,
            senderId: event.userId,
          })
          if (!shouldQueue) continue

          await queueInlineReactionSystemEvent({
            action: "removed",
            chatId: event.chatId,
            messageId: event.messageId,
            senderId: event.userId,
            emoji: event.emoji,
          })
          continue
        }

        if (rawEvent["kind"] === "chat.participant.add") {
          const eventChatId = rawEvent["chatId"] as bigint | undefined
          if (!eventChatId) continue
          const participant = rawEvent["participant"] as { userId?: bigint; date?: bigint } | undefined
          const seq = rawEvent["seq"] as number | undefined
          await queueInlineParticipantAddSystemEvent({
            chatId: eventChatId,
            ...(participant ? { participant } : {}),
            ...(seq != null ? { seq } : {}),
          })
          continue
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
            continue
          }
          if (actorUserId === meId) continue

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
            { serializeWithChat: true },
          )
          continue
        }
      }
    } catch (err) {
      statusSink?.({ lastError: String(err) })
      runtime.error?.(`inline monitor loop crashed: ${String(err)}`)
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
      clearInterval(diagnosticsTimer)
      clearPendingInlineVoiceMessages()
      await client.close().catch(() => {})
      await loop.catch(() => {})
      await drainInboundTasks()
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

  const done = loop.catch(() => {}).then(drainInboundTasks)
  return { stop, done }
}
