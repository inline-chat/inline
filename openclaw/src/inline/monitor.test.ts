import os from "node:os"
import path from "node:path"
import { describe, expect, it, vi } from "vitest"
import {
  INLINE_ACTION_CALLBACK_DATA_MAX_BYTES,
  INLINE_ACTION_LABEL_MAX_LENGTH,
} from "./outbound-sanitize"

const modelRuntimeMocks = vi.hoisted(() => ({
  buildModelsProviderData: vi.fn(),
  resolveDefaultModelForAgent: vi.fn(),
  getSessionEntry: vi.fn(),
  patchSessionEntry: vi.fn(),
  applyModelOverrideToSessionEntry: vi.fn(),
}))

const SET_BOT_PRESENCE_STATE = 59
const BOT_PRESENCE_IDLE = 2
const BOT_PRESENCE_HAPPY = 3
const BOT_PRESENCE_WAVING = 4
const BOT_PRESENCE_JUMPING = 5
const BOT_PRESENCE_FAILED = 6
const BOT_PRESENCE_WAITING = 7
const BOT_PRESENCE_RUNNING = 8
const BOT_PRESENCE_REVIEW = 9

vi.mock("openclaw/plugin-sdk/models-provider-runtime", async () => {
  const actual = await vi.importActual<typeof import("openclaw/plugin-sdk/models-provider-runtime")>(
    "openclaw/plugin-sdk/models-provider-runtime",
  )
  return {
    ...actual,
    buildModelsProviderData: modelRuntimeMocks.buildModelsProviderData,
  }
})

vi.mock("openclaw/plugin-sdk/agent-runtime", async () => {
  const actual = await vi.importActual<typeof import("openclaw/plugin-sdk/agent-runtime")>(
    "openclaw/plugin-sdk/agent-runtime",
  )
  return {
    ...actual,
    resolveDefaultModelForAgent: modelRuntimeMocks.resolveDefaultModelForAgent,
  }
})

vi.mock("openclaw/plugin-sdk/session-store-runtime", async () => {
  const actual = await vi.importActual<typeof import("openclaw/plugin-sdk/session-store-runtime")>(
    "openclaw/plugin-sdk/session-store-runtime",
  )
  return {
    ...actual,
    getSessionEntry: modelRuntimeMocks.getSessionEntry,
    patchSessionEntry: modelRuntimeMocks.patchSessionEntry,
  }
})

vi.mock("openclaw/plugin-sdk/model-session-runtime", async () => {
  const actual = await vi.importActual<typeof import("openclaw/plugin-sdk/model-session-runtime")>(
    "openclaw/plugin-sdk/model-session-runtime",
  )
  return {
    ...actual,
    applyModelOverrideToSessionEntry: modelRuntimeMocks.applyModelOverrideToSessionEntry,
  }
})

type MonitorHarness = {
  monitorInlineProvider: typeof import("./monitor")["monitorInlineProvider"]
  calls: {
    sendMessage: ReturnType<typeof vi.fn>
    invokeRaw: ReturnType<typeof vi.fn>
    uploadFile: ReturnType<typeof vi.fn>
    fetchRemoteMedia: ReturnType<typeof vi.fn>
    saveMediaBuffer: ReturnType<typeof vi.fn>
    resolveAgentRoute: ReturnType<typeof vi.fn>
    recordInboundSession: ReturnType<typeof vi.fn>
    finalizeInboundContext: ReturnType<typeof vi.fn>
    dispatchReply: ReturnType<typeof vi.fn>
    enqueueSystemEvent: ReturnType<typeof vi.fn>
    answerMessageAction: ReturnType<typeof vi.fn>
    closeClient: ReturnType<typeof vi.fn>
    upsertPairingRequest: ReturnType<typeof vi.fn>
    buildPairingReply: ReturnType<typeof vi.fn>
    readAllowFromStore: ReturnType<typeof vi.fn>
  }
}

type MonitorSetup = {
  me?: {
    userId?: bigint
    username?: string
  }
  events: Array<
    | {
        kind: "message.new"
        chatId: bigint
        message: {
          id: bigint
          date: bigint
          fromId: bigint
          message: string
          out?: boolean
          mentioned?: boolean
          replyToMsgId?: bigint
        }
        seq?: number
      }
    | {
        kind: "message.edit"
        chatId: bigint
        message: {
          id: bigint
          date: bigint
          fromId: bigint
          message: string
          out?: boolean
          mentioned?: boolean
          replyToMsgId?: bigint
        }
        seq?: number
      }
    | {
        kind: "message.delete"
        chatId: bigint
        messageIds: bigint[]
        seq?: number
        date?: bigint
      }
    | {
        kind: "reaction.add"
        chatId: bigint
        reaction: {
          emoji: string
          userId: bigint
          messageId: bigint
          chatId: bigint
          date: bigint
        }
        seq?: number
        date?: bigint
      }
    | {
        kind: "reaction.delete"
        chatId: bigint
        emoji: string
        userId: bigint
        messageId: bigint
        seq?: number
        date?: bigint
      }
    | {
        kind: "chat.participant.add"
        chatId: bigint
        participant?: {
          userId?: bigint
          date?: bigint
        }
        seq?: number
        date?: bigint
      }
    | {
        kind: "message.action.invoke"
        chatId: bigint
        interactionId: bigint
        messageId: bigint
        actorUserId: bigint
        actionId: string
        data: Uint8Array
        seq?: number
        date?: bigint
      }
  >
  chats: Record<string, {
    kind: "direct" | "group"
    title?: string
    peerUserId?: bigint
    parentChatId?: bigint
    parentMessageId?: bigint
    lastMsgId?: bigint
    dialogFollowMode?: number
  }>
  participants?: Record<string, Array<{ id: bigint; username?: string; firstName?: string; lastName?: string }>>
  directoryUsers?: Array<{ id: bigint; username?: string; firstName?: string; lastName?: string }>
  historyByChat?: Record<string, Array<{
    id: bigint
    date: bigint
    fromId: bigint
    message?: string
    out?: boolean
    replyToMsgId?: bigint
    entities?: unknown
  }>>
  mediaByUrl?: Record<string, { contentType?: string; fileName?: string; buffer?: Uint8Array | Buffer }>
  mentionRegexes?: RegExp[]
  matchesMentionPatterns?: (text: string, regexes: RegExp[]) => boolean
  sendTyping?: (params: { chatId: bigint; typing: boolean }) => Promise<void>
  hasControlCommand?: (text?: string) => boolean
  shouldHandleTextCommands?: (params: {
    cfg: unknown
    surface: string
    commandSource?: "text" | "native"
  }) => boolean
  skillCommands?: Array<{ name: string; description: string }>
  pluginCommands?: Array<{ name: string; description: string }>
  dispatchReplyPayload?: {
    text?: string
    replyToId?: string
    mediaUrl?: string
    mediaUrls?: string[]
    isReasoning?: boolean
    buttons?: Array<Array<{ text?: string; callback_data?: string }>>
    interactive?: unknown
    channelData?: Record<string, unknown>
  }
  dispatchReplyPayloads?: Array<{
    text?: string
    replyToId?: string
    mediaUrl?: string
    mediaUrls?: string[]
    isReasoning?: boolean
    buttons?: Array<Array<{ text?: string; callback_data?: string }>>
    interactive?: unknown
    channelData?: Record<string, unknown>
  }>
  replyPipeline?: {
    onModelSelected?: (ctx: unknown) => void
    responsePrefix?: string
    responsePrefixContextProvider?: () => unknown
    transformReplyPayload?: (payload: Record<string, unknown>) => Record<string, unknown> | null
    typingCallbacks?: {
      onReplyStart: () => Promise<void>
      onIdle?: () => void
      onCleanup?: () => void
    }
  }
  dispatchTypingLifecycle?: boolean
  partialReplies?: Array<{ text?: string; mediaUrls?: string[]; isReasoning?: boolean }>
  reasoningReplies?: Array<{ text?: string; mediaUrls?: string[]; isReasoning?: boolean }>
  partialRepliesConcurrent?: boolean
  assistantMessageStartBeforePayloadIndexes?: number[]
  toolStartBeforePayloadIndexes?: number[]
  itemEventBeforePayloadIndexes?: number[]
  compactionStartBeforePayloadIndexes?: number[]
  compactionEndBeforePayloadIndexes?: number[]
  payloadInfoKinds?: Array<"final" | "partial" | "error">
  skipInfos?: Array<{ reason?: string }>
  dispatchErrorInfos?: Array<{ kind?: string }>
  resolveControlCommandGate?: (params: any) => { shouldBlock: boolean; commandAuthorized: boolean }
  dispatchReplyBlocker?: (params: {
    ctx: unknown
    dispatcherOptions: any
    replyOptions: any
  }) => Promise<void> | void
  captureSdkLogger?: (logger: {
    debug?: (msg: string, meta?: unknown) => void
    info?: (msg: string, meta?: unknown) => void
    warn?: (msg: string, meta?: unknown) => void
    error?: (msg: string, meta?: unknown) => void
  }) => void
  getDiagnostics?: () => unknown
  sendMessageDelayMs?: number
  runtimeConfig?: Record<string, unknown>
  createSubthreadError?: string
  getMeError?: Error
  openKeyedStore?: ReturnType<typeof vi.fn>
}

function buildAccount(overrides?: {
  dmPolicy?: "pairing" | "allowlist" | "open" | "disabled"
  groupPolicy?: "allowlist" | "open" | "disabled"
  allowFrom?: string[]
  groupAllowFrom?: string[]
  systemPrompt?: string
  groups?: Record<string, {
    requireMention?: boolean
    replyThreadMode?: "auto" | "thread" | "main"
    replyThreadAutoCreateMinMessages?: number
    replyThreadRequireExplicitMention?: boolean
    replyThreadParentHistoryLimit?: number
    systemPrompt?: string
    tools?: { allow?: string[]; deny?: string[] }
    toolsBySender?: Record<string, { allow?: string[]; deny?: string[] }>
  }>
  replyThreadMode?: "auto" | "thread" | "main"
  replyThreadAutoCreateMinMessages?: number
  replyThreadRequireExplicitMention?: boolean
  replyThreadParentHistoryLimit?: number
  requireMention?: boolean
  replyToBotWithoutMention?: boolean
  historyLimit?: number
  dmHistoryLimit?: number
  parseMarkdown?: boolean
  reactionNotifications?: "off" | "own" | "all" | "allowlist"
  reactionAllowlist?: string[]
  streaming?: boolean | string | Record<string, unknown>
  streamMode?: "off" | "partial" | "block" | "progress"
  blockStreaming?: boolean
  streamViaEditMessage?: boolean
  mediaMaxMb?: number
  debounceMs?: number
  voiceTranscriptWaitMs?: number
  replyThreads?: boolean
  commands?: { native?: boolean | "auto"; nativeSkills?: boolean | "auto" }
  execApprovals?: Record<string, unknown>
}) {
  return {
    accountId: "default",
    name: "default",
    enabled: true,
    configured: true,
    baseUrl: "https://api.inline.chat",
    token: "token",
    tokenFile: null,
    config: {
      enabled: true,
      baseUrl: "https://api.inline.chat",
      token: "token",
      tokenFile: undefined,
      dmPolicy: overrides?.dmPolicy ?? "open",
      allowFrom: overrides?.allowFrom ?? [],
      groupPolicy: overrides?.groupPolicy ?? "open",
      groupAllowFrom: overrides?.groupAllowFrom ?? [],
      systemPrompt: overrides?.systemPrompt,
      groups: overrides?.groups,
      requireMention: overrides?.requireMention ?? true,
      replyThreadMode: overrides?.replyThreadMode,
      replyThreadAutoCreateMinMessages: overrides?.replyThreadAutoCreateMinMessages,
      replyThreadRequireExplicitMention: overrides?.replyThreadRequireExplicitMention,
      replyThreadParentHistoryLimit: overrides?.replyThreadParentHistoryLimit,
      replyToBotWithoutMention: overrides?.replyToBotWithoutMention,
      historyLimit: overrides?.historyLimit,
      dmHistoryLimit: overrides?.dmHistoryLimit,
      parseMarkdown: overrides?.parseMarkdown ?? true,
      reactionNotifications: overrides?.reactionNotifications,
      reactionAllowlist: overrides?.reactionAllowlist,
      streaming: overrides?.streaming,
      streamMode: overrides?.streamMode,
      blockStreaming: overrides?.blockStreaming,
      streamViaEditMessage: overrides?.streamViaEditMessage,
      mediaMaxMb: overrides?.mediaMaxMb,
      debounceMs: overrides?.debounceMs,
      voiceTranscriptWaitMs: overrides?.voiceTranscriptWaitMs,
      commands: overrides?.commands,
      execApprovals: overrides?.execApprovals,
      capabilities: overrides?.replyThreads != null ? { replyThreads: overrides.replyThreads } : undefined,
      textChunkLimit: 4000,
    },
  } as any
}

async function waitFor(assertion: () => void, timeoutMs = 5_000): Promise<void> {
  const start = Date.now()
  let lastError: unknown
  while (Date.now() - start <= timeoutMs) {
    try {
      assertion()
      return
    } catch (err) {
      lastError = err
      await new Promise((resolve) => setTimeout(resolve, 10))
    }
  }
  throw lastError
}

async function waitForMockPromise(mock: ReturnType<typeof vi.fn>, callIndex = 0): Promise<void> {
  await waitFor(() => {
    expect(mock.mock.results[callIndex]?.type).toBe("return")
  })
  const result = mock.mock.results[callIndex]
  if (result?.type === "return") {
    await result.value
  }
}

async function setupMonitorHarness(setup: MonitorSetup): Promise<MonitorHarness> {
  vi.resetModules()
  const stateDir = path.join(
    os.tmpdir(),
    "openclaw-inline-tests",
    `${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}`,
  )

  const resolveMockModelRef = (cfg?: any) => {
    const raw = typeof cfg?.agents?.defaults?.model === "string" ? cfg.agents.defaults.model.trim() : ""
    const slashIndex = raw.indexOf("/")
    if (slashIndex > 0 && slashIndex < raw.length - 1) {
      return {
        provider: raw.slice(0, slashIndex),
        model: raw.slice(slashIndex + 1),
      }
    }
    return {
      provider: "openai",
      model: "gpt-4.1",
    }
  }

  modelRuntimeMocks.buildModelsProviderData.mockReset().mockImplementation(async (cfg?: any) => {
    const ref = resolveMockModelRef(cfg)
    return {
      byProvider: new Map([[ref.provider, new Set([ref.model])]]),
      providers: [ref.provider],
      resolvedDefault: ref,
    }
  })
  modelRuntimeMocks.resolveDefaultModelForAgent.mockReset().mockImplementation(({ cfg }: any) => resolveMockModelRef(cfg))
  modelRuntimeMocks.getSessionEntry.mockReset().mockReturnValue(undefined)
  modelRuntimeMocks.patchSessionEntry.mockReset().mockImplementation(async ({ fallbackEntry, update }: any) => {
    const entry = structuredClone(fallbackEntry ?? { sessionId: "test-session", updatedAt: 1 })
    return await update(entry, { existingEntry: fallbackEntry ? undefined : entry })
  })
  modelRuntimeMocks.applyModelOverrideToSessionEntry.mockReset().mockImplementation(({ entry, selection }: any) => {
    entry.provider = selection.provider
    entry.model = selection.model
    entry.isDefault = selection.isDefault
    return { updated: true }
  })
  let runtimeConfig = structuredClone(setup.runtimeConfig ?? {})
  const mutateConfigFile = vi.fn(async ({ mutate }: any) => {
    const draft = structuredClone(runtimeConfig)
    await mutate(draft)
    runtimeConfig = draft
    return { nextConfig: runtimeConfig }
  })

  let nextSentMessageId = 1n
  const sendMessage = vi.fn(async () => {
    if (setup.sendMessageDelayMs != null && setup.sendMessageDelayMs > 0) {
      await new Promise((resolve) => setTimeout(resolve, setup.sendMessageDelayMs))
    }
    const messageId = nextSentMessageId
    nextSentMessageId += 1n
    return { messageId }
  })
  const sendTyping = vi.fn(setup.sendTyping ?? (async () => {}))
  const uploadFile = vi.fn(async () => ({ fileUniqueId: "INP_1", photoId: 200n }))
  const answerMessageAction = vi.fn(async () => {})
  const closeClient = vi.fn(async () => {})
  const fetchRemoteMedia = vi.fn(async ({ url }: { url: string }) => {
    const media = setup.mediaByUrl?.[url]
    return {
      buffer: Buffer.from(media?.buffer ?? [1, 2, 3]),
      contentType: media?.contentType ?? "image/jpeg",
      fileName: media?.fileName,
    }
  })
  const saveMediaBuffer = vi.fn(
    async (
      _buffer: Buffer,
      contentType?: string,
      _subdir?: string,
      _maxBytes?: number,
      originalFilename?: string,
    ) => ({
      id: "saved-media",
      path: originalFilename ? `/tmp/${originalFilename}` : "/tmp/saved-media.bin",
      size: 3,
      contentType,
    }),
  )
  const resolveAgentRoute = vi.fn((input: any) => ({
    agentId: "main",
    channel: "inline",
    accountId: input.accountId ?? "default",
    sessionKey: `agent:main:inline:${String(input.peer?.kind ?? "unknown")}:${String(input.peer?.id ?? "unknown")}`,
    mainSessionKey: "agent:main:main",
    matchedBy: "default",
  }))
  const recordInboundSession = vi.fn(async () => {})
  const finalizeInboundContext = vi.fn((ctx: any) => ctx)
  const enqueueSystemEvent = vi.fn(() => true)
  const dispatchReply = vi.fn(async ({ ctx, dispatcherOptions, replyOptions }: any) => {
    await setup.dispatchReplyBlocker?.({ ctx, dispatcherOptions, replyOptions })
    if (setup.dispatchTypingLifecycle) {
      await (dispatcherOptions.onReplyStart ?? dispatcherOptions.typingCallbacks?.onReplyStart)?.()
    }
    if (setup.partialRepliesConcurrent) {
      await Promise.all((setup.partialReplies ?? []).map((partial) => replyOptions?.onPartialReply?.(partial)))
    } else {
      for (const partial of setup.partialReplies ?? []) {
        await replyOptions?.onPartialReply?.(partial)
      }
    }
    for (const partial of setup.reasoningReplies ?? []) {
      await replyOptions?.onReasoningStream?.(partial)
    }
    if ((setup.reasoningReplies?.length ?? 0) > 0) {
      await replyOptions?.onReasoningEnd?.()
    }
    const payloads = [...(setup.dispatchReplyPayloads ?? []), ...(setup.dispatchReplyPayload ? [setup.dispatchReplyPayload] : [])]
    for (let index = 0; index < payloads.length; index += 1) {
      if (setup.assistantMessageStartBeforePayloadIndexes?.includes(index)) {
        await replyOptions?.onAssistantMessageStart?.()
      }
      if (setup.toolStartBeforePayloadIndexes?.includes(index)) {
        await replyOptions?.onToolStart?.({ name: "exec", args: { command: "ls" } })
      }
      if (setup.itemEventBeforePayloadIndexes?.includes(index)) {
        await replyOptions?.onItemEvent?.({
          kind: "command",
          name: "exec",
          phase: "end",
          status: "done",
          progressText: "listed files",
        })
      }
      if (setup.compactionStartBeforePayloadIndexes?.includes(index)) {
        await replyOptions?.onCompactionStart?.()
      }
      if (setup.compactionEndBeforePayloadIndexes?.includes(index)) {
        await replyOptions?.onCompactionEnd?.()
      }
      const payload = payloads[index]
      if (!payload) continue
      const transformed = dispatcherOptions.transformReplyPayload?.(payload) ?? payload
      const kind = setup.payloadInfoKinds?.[index]
      if (kind) {
        await dispatcherOptions.deliver(transformed, { kind })
      } else {
        await dispatcherOptions.deliver(transformed)
      }
    }
    for (const skipInfo of setup.skipInfos ?? []) {
      await dispatcherOptions.onSkip?.({ isError: false }, skipInfo)
    }
    for (const errInfo of setup.dispatchErrorInfos ?? []) {
      await dispatcherOptions.onError?.(new Error("dispatch error"), { kind: errInfo.kind ?? "final" })
    }
    if (setup.dispatchTypingLifecycle) {
      ;(dispatcherOptions.onIdle ?? dispatcherOptions.typingCallbacks?.onIdle)?.()
      ;(dispatcherOptions.onCleanup ?? dispatcherOptions.typingCallbacks?.onCleanup)?.()
    }
  })
  const upsertPairingRequest = vi.fn(async () => ({ code: "PAIR-123", created: true }))
  const buildPairingReply = vi.fn(() => "PAIRING_REPLY")
  const readAllowFromStore = vi.fn(async () => [])
  const invokeRaw = vi.fn(async (
    method: number,
    input: {
      oneofKind?: string
      getMe?: Record<string, never>
      getChatParticipants?: { chatId?: bigint }
      getChats?: Record<string, never>
      getChatHistory?: { peerId?: { type?: { oneofKind?: string; chat?: { chatId?: bigint } } } }
      getChat?: { peerId?: { type?: { oneofKind?: string; chat?: { chatId?: bigint } } } }
      editMessage?: {
        messageId?: bigint
        peerId?: { type?: { oneofKind?: string; chat?: { chatId?: bigint } } }
        text?: string
        parseMarkdown?: boolean
      }
      getMessages?: {
        peerId?: { type?: { oneofKind?: string; chat?: { chatId?: bigint } } }
        messageIds?: bigint[]
      }
      createSubthread?: {
        parentChatId?: bigint
        parentMessageId?: bigint
      }
    },
  ) => {
    if (method === 1 && input?.oneofKind === "getMe") {
      if (setup.getMeError) {
        throw setup.getMeError
      }
      return {
        oneofKind: "getMe",
        getMe: {
          user: {
            id: setup.me?.userId ?? 777n,
            ...(setup.me?.username ? { username: setup.me.username } : {}),
          },
        },
      }
    }
    if (method === 17 && input?.oneofKind === "getChats") {
      return {
        oneofKind: "getChats",
        getChats: {
          chats: [],
          dialogs: [],
          users: setup.directoryUsers ?? [],
        },
      }
    }
    if (method === 13 && input?.oneofKind === "getChatParticipants") {
      const chatId = String(input.getChatParticipants?.chatId ?? "")
      return {
        oneofKind: "getChatParticipants",
        getChatParticipants: {
          participants: [],
          users: setup.participants?.[chatId] ?? [],
        },
      }
    }
    if (method === 5 && input?.oneofKind === "getChatHistory") {
      const chatId = String(input.getChatHistory?.peerId?.type?.chat?.chatId ?? "")
      return {
        oneofKind: "getChatHistory",
        getChatHistory: {
          messages: setup.historyByChat?.[chatId] ?? [],
        },
      }
    }
    if (method === 25 && input?.oneofKind === "getChat") {
      const chatId = String(input.getChat?.peerId?.type?.chat?.chatId ?? "")
      const info = setup.chats[chatId]
      if (!info) {
        return {
          oneofKind: "getChat",
          getChat: {},
        }
      }
      if (info.kind === "direct") {
        return {
          oneofKind: "getChat",
          getChat: {
            chat: {
              id: BigInt(chatId),
              title: info.title ?? `chat-${chatId}`,
              peerId: {
                type: {
                  oneofKind: "user",
                  user: { userId: info.peerUserId ?? 42n },
                },
              },
            },
          },
        }
      }
      return {
        oneofKind: "getChat",
        getChat: {
          chat: {
            id: BigInt(chatId),
            title: info.title ?? `chat-${chatId}`,
            ...(info.parentChatId != null ? { parentChatId: info.parentChatId } : {}),
            ...(info.parentMessageId != null ? { parentMessageId: info.parentMessageId } : {}),
            ...(info.lastMsgId != null ? { lastMsgId: info.lastMsgId } : {}),
          },
          ...(info.dialogFollowMode != null
            ? { dialog: { chatId: BigInt(chatId), followMode: info.dialogFollowMode } }
            : {}),
        },
      }
    }
    if (method === 38 && input?.oneofKind === "getMessages") {
      const chatId = String(input.getMessages?.peerId?.type?.chat?.chatId ?? "")
      const messageIds = input.getMessages?.messageIds ?? []
      const known = setup.historyByChat?.[chatId] ?? []
      const byId = new Map(known.map((message) => [String(message.id), message]))
      return {
        oneofKind: "getMessages",
        getMessages: {
          messages: messageIds
            .map((id) => byId.get(String(id)))
            .filter((message): message is NonNullable<typeof message> => Boolean(message)),
        },
      }
    }
    if (method === 42 && input?.oneofKind === "createSubthread") {
      if (setup.createSubthreadError) {
        throw new Error(setup.createSubthreadError)
      }
      const parentChatId = input.createSubthread?.parentChatId ?? 0n
      const parentMessageId = input.createSubthread?.parentMessageId ?? 0n
      const childChatId = BigInt(`${String(parentChatId)}${String(parentMessageId)}`)
      return {
        oneofKind: "createSubthread",
        createSubthread: {
          chat: {
            id: childChatId,
            parentChatId,
            parentMessageId,
          },
          dialog: { chatId: childChatId },
          anchorMessage: setup.historyByChat?.[String(parentChatId)]?.find((message) => message.id === parentMessageId),
        },
      }
    }
    if (method === 8 && input?.oneofKind === "editMessage") {
      return {
        oneofKind: "editMessage",
        editMessage: { updates: [] },
      }
    }
    if (method === 4 && input?.oneofKind === "deleteMessages") {
      return {
        oneofKind: "deleteMessages",
        deleteMessages: { updates: [] },
      }
    }
    return { oneofKind: undefined }
  })

  vi.doMock("@inline-chat/realtime-sdk", () => {
    async function* eventsGenerator() {
      for (const event of setup.events) {
        if (event.kind === "message.new") {
          yield {
            kind: event.kind,
            chatId: event.chatId,
            message: {
              ...event.message,
              out: event.message.out ?? false,
            },
            seq: event.seq ?? 1,
            date: event.message.date,
          }
          continue
        }

        if (event.kind === "message.edit") {
          yield {
            kind: event.kind,
            chatId: event.chatId,
            message: {
              ...event.message,
              out: event.message.out ?? false,
            },
            seq: event.seq ?? 1,
            date: event.message.date,
          }
          continue
        }

        if (event.kind === "message.delete") {
          yield {
            kind: event.kind,
            chatId: event.chatId,
            messageIds: event.messageIds,
            seq: event.seq ?? 1,
            date: event.date ?? 1_700_000_000n,
          }
          continue
        }

        if (event.kind === "reaction.add") {
          yield {
            kind: event.kind,
            chatId: event.chatId,
            reaction: event.reaction,
            seq: event.seq ?? 1,
            date: event.date ?? event.reaction.date,
          }
          continue
        }

        if (event.kind === "message.action.invoke") {
          yield {
            kind: event.kind,
            chatId: event.chatId,
            interactionId: event.interactionId,
            messageId: event.messageId,
            actorUserId: event.actorUserId,
            actionId: event.actionId,
            data: event.data,
            seq: event.seq ?? 1,
            date: event.date ?? 1_700_000_000n,
          }
          continue
        }

        if (event.kind === "chat.participant.add") {
          yield {
            kind: event.kind,
            chatId: event.chatId,
            participant: event.participant,
            seq: event.seq ?? 1,
            date: event.date ?? event.participant?.date ?? 1_700_000_000n,
          }
          continue
        }

        yield {
          kind: event.kind,
          chatId: event.chatId,
          emoji: event.emoji,
          userId: event.userId,
          messageId: event.messageId,
          seq: event.seq ?? 1,
          date: event.date ?? 1_700_000_000n,
        }
      }
    }

    const positiveId = (value: unknown): bigint | null => {
      if (typeof value === "bigint") return value > 0n ? value : null
      if (typeof value === "number" && Number.isSafeInteger(value) && value > 0) return BigInt(value)
      if (typeof value !== "string" || !/^[1-9]\d*$/.test(value.trim())) return null
      return BigInt(value.trim())
    }

    return {
      JsonFileStateStore: class {
        constructor(_path: string) {}
      },
      Method: {
        GET_ME: 1,
        DELETE_MESSAGES: 4,
        GET_CHAT_HISTORY: 5,
        GET_CHAT: 25,
        GET_CHAT_PARTICIPANTS: 13,
        GET_CHATS: 17,
        EDIT_MESSAGE: 8,
        CREATE_SUBTHREAD: 42,
        GET_MESSAGES: 38,
        INVOKE_MESSAGE_ACTION: 48,
        ANSWER_MESSAGE_ACTION: 49,
        SET_BOT_PRESENCE_STATE,
      },
      DialogFollowMode: {
        DIALOG_FOLLOW_MODE_UNSPECIFIED: 0,
        FOLLOWING: 1,
      },
      isInlineFollowModeMentionGateEligible: (chat: {
        parentMessageId?: unknown
        lastMsgId?: unknown
      }) => {
        if (positiveId(chat.parentMessageId) != null) return true
        const lastMsgId = positiveId(chat.lastMsgId)
        return lastMsgId != null && lastMsgId < 50n
      },
      BotPresenceState_Kind: {
        IDLE: BOT_PRESENCE_IDLE,
        HAPPY: BOT_PRESENCE_HAPPY,
        WAVING: BOT_PRESENCE_WAVING,
        JUMPING: BOT_PRESENCE_JUMPING,
        FAILED: BOT_PRESENCE_FAILED,
        WAITING: BOT_PRESENCE_WAITING,
        RUNNING: BOT_PRESENCE_RUNNING,
        REVIEW: BOT_PRESENCE_REVIEW,
      },
      InlineSdkClient: class {
        constructor(opts: any) {
          setup.captureSdkLogger?.(opts.logger)
        }
        connect = vi.fn(async () => {})
        getMe = vi.fn(async () => ({ userId: setup.me?.userId ?? 777n }))
        getChat = vi.fn(async ({ chatId }: { chatId: bigint }) => {
          const key = String(chatId)
          const info = setup.chats[key] ?? { kind: "group", title: `chat-${key}` }
          if (info.kind === "direct") {
            return {
              chatId,
              title: info.title ?? "Direct",
              peer: { type: { oneofKind: "user", user: { userId: info.peerUserId ?? 42n } } },
            }
          }
          return {
            chatId,
            title: info.title ?? "Group",
            peer: { type: { oneofKind: "chat", chat: { chatId } } },
            ...(info.parentChatId != null ? { parentChatId: info.parentChatId } : {}),
            ...(info.parentMessageId != null ? { parentMessageId: info.parentMessageId } : {}),
            ...(info.lastMsgId != null ? { lastMsgId: info.lastMsgId } : {}),
            ...(info.dialogFollowMode != null ? { dialogFollowMode: info.dialogFollowMode } : {}),
          }
        })
        sendMessage = sendMessage
        uploadFile = uploadFile
        sendTyping = sendTyping
        answerMessageAction = answerMessageAction
        invokeRaw = invokeRaw
        invokeUncheckedRaw = this.invokeRaw
        getDiagnostics = vi.fn(() => setup.getDiagnostics?.() ?? ({
          protocol: {
            state: "open",
            ping: {
              lastPongAt: Date.now(),
            },
          },
        }))
        close = closeClient
        events = vi.fn(() => eventsGenerator())
      },
    }
  })

  vi.doMock("openclaw/plugin-sdk", async () => {
    const actual = await vi.importActual<Record<string, unknown>>("openclaw/plugin-sdk")
    return {
      ...actual,
      createReplyPrefixOptions: vi.fn(() => ({ onModelSelected: vi.fn() })),
      createTypingCallbacks: vi.fn(() => ({})),
      loadWebMedia: vi.fn(async () => ({
        buffer: Buffer.from([1, 2, 3]),
        contentType: "image/png",
        kind: "image",
        fileName: "image.png",
      })),
      detectMime: vi.fn(async () => "image/png"),
      logInboundDrop: vi.fn(),
      resolveControlCommandGate: vi.fn(
        setup.resolveControlCommandGate ?? (() => ({ shouldBlock: false, commandAuthorized: true })),
      ),
      resolveMentionGatingWithBypass: vi.fn((params: any) => {
        const shouldBypassMention = Boolean(
          params.isGroup &&
            params.requireMention &&
            !params.wasMentioned &&
            !params.implicitMention &&
            params.allowTextCommands &&
            params.commandAuthorized &&
            params.hasControlCommand,
        )
        return {
          shouldSkip: Boolean(
            params.isGroup &&
              params.requireMention &&
              !params.wasMentioned &&
              !params.implicitMention &&
              !shouldBypassMention,
          ),
          effectiveWasMentioned: Boolean(params.wasMentioned || params.implicitMention || shouldBypassMention),
          shouldBypassMention,
        }
      }),
    }
  })
  vi.doMock("openclaw/plugin-sdk/channel-reply-pipeline", async () => {
    const actual = await vi.importActual<Record<string, unknown>>(
      "openclaw/plugin-sdk/channel-reply-pipeline",
    )
    return {
      ...actual,
      createChannelReplyPipeline: vi.fn((params: any) => {
        const typingCallbacks =
          setup.replyPipeline?.typingCallbacks ??
          (params.typing
            ? {
                onReplyStart: params.typing.start,
                ...(params.typing.stop
                  ? {
                      onIdle: () => void params.typing.stop(),
                      onCleanup: () => void params.typing.stop(),
                    }
                  : {}),
              }
            : undefined)
        return {
          onModelSelected: vi.fn(),
          ...(typingCallbacks ? { typingCallbacks } : {}),
          ...setup.replyPipeline,
        }
      }),
    }
  })
  vi.doMock("openclaw/plugin-sdk/skill-commands-runtime", async () => {
    const actual = await vi.importActual<Record<string, unknown>>(
      "openclaw/plugin-sdk/skill-commands-runtime",
    )
    return {
      ...actual,
      listSkillCommandsForAgents: vi.fn(() => setup.skillCommands ?? []),
    }
  })
  vi.doMock("openclaw/plugin-sdk/plugin-runtime", async () => {
    const actual = await vi.importActual<Record<string, unknown>>("openclaw/plugin-sdk/plugin-runtime")
    return {
      ...actual,
      getPluginCommandSpecs: vi.fn(() => setup.pluginCommands ?? []),
    }
  })
  vi.doMock("openclaw/plugin-sdk/web-media", async () => {
    const actual = await vi.importActual<Record<string, unknown>>("openclaw/plugin-sdk/web-media")
    return {
      ...actual,
      loadWebMedia: vi.fn(async () => ({
        buffer: Buffer.from([1, 2, 3]),
        contentType: "image/png",
        kind: "image",
        fileName: "image.png",
      })),
    }
  })
  vi.doMock("openclaw/plugin-sdk/media-runtime", async () => {
    const actual = await vi.importActual<Record<string, unknown>>("openclaw/plugin-sdk/media-runtime")
    return {
      ...actual,
      detectMime: vi.fn(async () => "image/png"),
      extensionForMime: vi.fn((mime: string | undefined) => {
        if (mime === "image/png") return "png"
        if (mime === "image/jpeg") return "jpg"
        if (mime === "video/mp4") return "mp4"
        return undefined
      }),
    }
  })

  const runtimeMod = await import("../runtime")
  runtimeMod.setInlineRuntime({
    version: "test",
    config: {
      current: () => runtimeConfig,
      mutateConfigFile,
    },
    state: {
      resolveStateDir: () => stateDir,
      ...(setup.openKeyedStore ? { openKeyedStore: setup.openKeyedStore } : {}),
    },
    media: {
      loadWebMedia: vi.fn(async (mediaUrl: string) => {
        const media = setup.mediaByUrl?.[mediaUrl]
        return {
          buffer: Buffer.from(media?.buffer ?? [1, 2, 3]),
          contentType: media?.contentType ?? "image/png",
          kind: "image",
          fileName: media?.fileName ?? "image.png",
        }
      }),
      detectMime: vi.fn(async () => "image/png"),
    },
    system: {
      enqueueSystemEvent,
    },
    channel: {
      pairing: {
        readAllowFromStore,
        upsertPairingRequest,
        buildPairingReply,
      },
      commands: {
        shouldHandleTextCommands: setup.shouldHandleTextCommands ?? (() => true),
      },
      media: {
        fetchRemoteMedia,
        saveMediaBuffer,
      },
      text: {
        hasControlCommand: setup.hasControlCommand ?? ((text?: string) => /^\/\S+/.test((text ?? "").trim())),
      },
      routing: {
        resolveAgentRoute,
      },
      mentions: {
        buildMentionRegexes: () => setup.mentionRegexes ?? [],
        matchesMentionPatterns: (text: string, regexes: RegExp[]) => {
          if (setup.matchesMentionPatterns) {
            return setup.matchesMentionPatterns(text, regexes)
          }
          return regexes.some((regex) => regex.test(text))
        },
      },
      session: {
        resolveStorePath: () => path.join(stateDir, "sessions.json"),
        readSessionUpdatedAt: () => null,
        recordInboundSession,
      },
      reply: {
        resolveEnvelopeFormatOptions: () => ({ mode: "compact" }),
        formatAgentEnvelope: ({ body }: { body: string }) => body,
        formatInboundEnvelope: ({ body }: { body: string }) => body,
        finalizeInboundContext,
        dispatchReplyWithBufferedBlockDispatcher: dispatchReply,
      },
    },
  } as any)

  const mod = await import("./monitor")
  const participationMod = await import("./thread-participation")
  const routeMod = await import("./thread-routes")
  participationMod.clearInlineThreadParticipationCacheForTest()
  routeMod.clearInlineReplyThreadRouteCacheForTest()
  return {
    monitorInlineProvider: mod.monitorInlineProvider,
    calls: {
      sendMessage,
      sendTyping,
      invokeRaw,
      uploadFile,
      fetchRemoteMedia,
      saveMediaBuffer,
      resolveAgentRoute,
      recordInboundSession,
      finalizeInboundContext,
      dispatchReply,
      enqueueSystemEvent,
      answerMessageAction,
      closeClient,
      upsertPairingRequest,
      buildPairingReply,
      readAllowFromStore,
    },
  }
}

describe("inline/monitor", () => {
  it("publishes connected and inbound transport status", async () => {
    const statusPatches: Array<Record<string, unknown>> = []
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 7n,
          message: {
            id: 1001n,
            date: 1_700_000_000n,
            fromId: 42n,
            message: "hello",
          },
        },
      ],
      chats: {
        "7": { kind: "direct", title: "Alice" },
      },
      dispatchReplyPayload: {
        text: "hi",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ dmPolicy: "open" }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
      statusSink: (patch: Record<string, unknown>) => {
        statusPatches.push(patch)
      },
    })

    await waitFor(() => {
      expect(statusPatches).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            connected: true,
            lastError: null,
          }),
        ]),
      )
      const connected = statusPatches.find((patch) => patch.connected === true)
      expect(typeof connected?.lastConnectedAt).toBe("number")
      expect(typeof connected?.lastEventAt).toBe("number")
      expect(typeof connected?.lastTransportActivityAt).toBe("number")
    })

    await waitFor(() => {
      const inbound = statusPatches.find((patch) => typeof patch.lastInboundAt === "number")
      expect(typeof inbound?.lastEventAt).toBe("number")
      expect(typeof inbound?.lastTransportActivityAt).toBe("number")
    })

    await handle.stop()
  })

  it("clears recoverable websocket errors after diagnostics show recovery", async () => {
    vi.useFakeTimers()
    const statusPatches: Array<Record<string, unknown>> = []
    const reconnectMessage =
      "WebSocket reconnect scheduled (attempt=3, delayMs=2278, cause=socket-error:Error: connect ECONNREFUSED 127.0.0.1:8000 (code=ECONNREFUSED))"
    let sdkLogger: {
      warn?: (msg: string, meta?: unknown) => void
    } | null = null

    try {
      const harness = await setupMonitorHarness({
        events: [],
        chats: {},
        captureSdkLogger: (logger) => {
          sdkLogger = logger
        },
        getDiagnostics: () => ({
          protocol: {
            state: "open",
            ping: {
              pendingCount: 0,
              lastPongAt: Date.now(),
            },
            transport: {
              state: "connected",
              socketReadyState: 1,
            },
          },
        }),
      })

      const handle = await harness.monitorInlineProvider({
        cfg: {} as any,
        account: buildAccount({ dmPolicy: "open" }),
        runtime: { log: vi.fn(), error: vi.fn() } as any,
        abortSignal: new AbortController().signal,
        log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
        statusSink: (patch: Record<string, unknown>) => {
          statusPatches.push(patch)
        },
      })

      expect(sdkLogger?.warn).toBeTypeOf("function")
      sdkLogger?.warn?.(reconnectMessage)

      const errorIndex = statusPatches.findIndex((patch) => patch.lastError === reconnectMessage)
      expect(errorIndex).toBeGreaterThanOrEqual(0)

      await vi.advanceTimersByTimeAsync(15_000)

      expect(statusPatches.slice(errorIndex + 1)).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            lastError: null,
          }),
        ]),
      )

      await handle.stop()
    } finally {
      vi.useRealTimers()
    }
  })

  it("surfaces startup getMe failures with operation context and closes the client", async () => {
    const statusPatches: Array<Record<string, unknown>> = []
    const getMeError = new Error("Internal server error")
    getMeError.name = "ProtocolClientError:rpc-error"
    const harness = await setupMonitorHarness({
      events: [],
      chats: {},
      getMeError,
    })

    await expect(
      harness.monitorInlineProvider({
        cfg: {} as any,
        account: buildAccount({ dmPolicy: "open" }),
        runtime: { log: vi.fn(), error: vi.fn() } as any,
        abortSignal: new AbortController().signal,
        log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
        statusSink: (patch: Record<string, unknown>) => {
          statusPatches.push(patch)
        },
      }),
    ).rejects.toThrow(
      "inline startup getMe failed: ProtocolClientError:rpc-error: Internal server error",
    )

    expect(statusPatches).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          connected: false,
          lastError: "inline startup getMe failed: ProtocolClientError:rpc-error: Internal server error",
        }),
      ]),
    )
    expect(harness.calls.closeClient).toHaveBeenCalledTimes(1)
  })

  it("registers native approval runtime context when Inline approvals are configured", async () => {
    const register = vi.fn(() => ({ dispose: vi.fn() }))
    const harness = await setupMonitorHarness({
      events: [],
      chats: {},
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {
        channels: {
          inline: {
            token: "token",
            execApprovals: {
              approvers: ["51"],
            },
          },
        },
      } as any,
      account: buildAccount({
        dmPolicy: "open",
        parseMarkdown: false,
        execApprovals: {
          approvers: ["51"],
        },
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      channelRuntime: {
        runtimeContexts: {
          register,
          get: vi.fn(),
          watch: vi.fn(),
        },
      } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(register).toHaveBeenCalledWith(
        expect.objectContaining({
          channelId: "inline",
          accountId: "default",
          capability: "approval.native",
          context: expect.objectContaining({
            parseMarkdown: false,
          }),
        }),
      )
    })
    await Promise.resolve()

    const presenceCalls = harness.calls.invokeRaw.mock.calls.filter(
      ([method]) => method === SET_BOT_PRESENCE_STATE,
    )
    expect(presenceCalls).not.toEqual(
      expect.arrayContaining([
        [
          SET_BOT_PRESENCE_STATE,
          expect.objectContaining({
            setBotPresenceState: expect.objectContaining({
              state: { kind: BOT_PRESENCE_JUMPING },
            }),
          }),
        ],
      ]),
    )
    expect(presenceCalls).not.toEqual(
      expect.arrayContaining([
        [
          SET_BOT_PRESENCE_STATE,
          expect.objectContaining({
            setBotPresenceState: expect.objectContaining({
              state: { kind: BOT_PRESENCE_IDLE },
            }),
          }),
        ],
      ]),
    )

    await handle.stop()
  })

  it("debounces rapid inbound text messages into one turn", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 7n,
          message: {
            id: 1001n,
            date: 1_700_000_000n,
            fromId: 42n,
            message: "first line",
          },
        },
        {
          kind: "message.new",
          chatId: 7n,
          message: {
            id: 1002n,
            date: 1_700_000_001n,
            fromId: 42n,
            message: "second line",
          },
        },
      ],
      chats: {
        "7": { kind: "direct", title: "Alice" },
      },
      dispatchReplyPayload: {
        text: "batched reply",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {
        messages: {
          inbound: {
            debounceMs: 0,
            byChannel: {
              inline: 20,
            },
          },
        },
      } as any,
      account: buildAccount({ dmPolicy: "open" }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalledTimes(1)
      expect(harness.calls.resolveAgentRoute).toHaveBeenCalledTimes(1)
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledTimes(1)
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          RawBody: "first line\nsecond line",
          MessageSid: "1002",
          MessageSids: ["1001", "1002"],
          MessageSidFirst: "1001",
          MessageSidLast: "1002",
          From: "inline:42",
          To: "inline:7",
        }),
      )
    })

    await handle.stop()
  }, 30_000)

  it("uses global inbound debounceMs when Inline channel override is absent", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 7n,
          message: {
            id: 1001n,
            date: 1_700_000_000n,
            fromId: 42n,
            message: "first global line",
          },
        },
        {
          kind: "message.new",
          chatId: 7n,
          message: {
            id: 1002n,
            date: 1_700_000_001n,
            fromId: 42n,
            message: "second global line",
          },
        },
      ],
      chats: {
        "7": { kind: "direct", title: "Alice" },
      },
      dispatchReplyPayload: {
        text: "batched reply",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {
        messages: {
          inbound: {
            debounceMs: 20,
          },
        },
      } as any,
      account: buildAccount({ dmPolicy: "open" }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalledTimes(1)
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          RawBody: "first global line\nsecond global line",
          MessageSid: "1002",
          MessageSids: ["1001", "1002"],
          MessageSidFirst: "1001",
          MessageSidLast: "1002",
        }),
      )
    })

    await handle.stop()
  }, 30_000)

  it("uses Inline account debounceMs to batch rapid inbound text messages", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 7n,
          message: {
            id: 1001n,
            date: 1_700_000_000n,
            fromId: 42n,
            message: "first account-level line",
          },
        },
        {
          kind: "message.new",
          chatId: 7n,
          message: {
            id: 1002n,
            date: 1_700_000_001n,
            fromId: 42n,
            message: "second account-level line",
          },
        },
      ],
      chats: {
        "7": { kind: "direct", title: "Alice" },
      },
      dispatchReplyPayload: {
        text: "batched reply",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        dmPolicy: "open",
        debounceMs: 20,
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalledTimes(1)
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          RawBody: "first account-level line\nsecond account-level line",
          MessageSid: "1002",
          From: "inline:42",
          To: "inline:7",
        }),
      )
    })

    await handle.stop()
  }, 30_000)

  it("lets Inline account debounceMs 0 disable global inbound debounce", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 7n,
          message: {
            id: 1001n,
            date: 1_700_000_000n,
            fromId: 42n,
            message: "first unbatched line",
          },
        },
        {
          kind: "message.new",
          chatId: 7n,
          message: {
            id: 1002n,
            date: 1_700_000_001n,
            fromId: 42n,
            message: "second unbatched line",
          },
        },
      ],
      chats: {
        "7": { kind: "direct", title: "Alice" },
      },
      dispatchReplyPayload: {
        text: "unbatched reply",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {
        messages: {
          inbound: {
            debounceMs: 40,
          },
        },
      } as any,
      account: buildAccount({
        dmPolicy: "open",
        debounceMs: 0,
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalledTimes(2)
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          Body: "first unbatched line",
          MessageSid: "1001",
        }),
      )
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          Body: "second unbatched line",
          MessageSid: "1002",
        }),
      )
    })
    expect(harness.calls.finalizeInboundContext).not.toHaveBeenCalledWith(
      expect.objectContaining({
        RawBody: "first unbatched line\nsecond unbatched line",
      }),
    )

    await handle.stop()
  }, 30_000)

  it("keeps rapid inbound text from different senders in separate debounce turns", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 7n,
          message: {
            id: 1001n,
            date: 1_700_000_000n,
            fromId: 42n,
            message: "first sender",
          },
        },
        {
          kind: "message.new",
          chatId: 7n,
          message: {
            id: 1002n,
            date: 1_700_000_001n,
            fromId: 43n,
            message: "second sender",
          },
        },
      ],
      chats: {
        "7": { kind: "group", title: "Ops" },
      },
      dispatchReplyPayload: {
        text: "reply",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {
        messages: {
          inbound: {
            byChannel: {
              inline: 30,
            },
          },
        },
      } as any,
      account: buildAccount({
        groupPolicy: "open",
        requireMention: false,
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalledTimes(2)
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          Body: "first sender",
          MessageSid: "1001",
        }),
      )
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          Body: "second sender",
          MessageSid: "1002",
        }),
      )
    })
    expect(harness.calls.finalizeInboundContext).not.toHaveBeenCalledWith(
      expect.objectContaining({
        RawBody: "first sender\nsecond sender",
      }),
    )

    await handle.stop()
  })

  it("keeps rapid inbound text from different chats in separate debounce turns", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 7n,
          message: {
            id: 1001n,
            date: 1_700_000_000n,
            fromId: 42n,
            message: "first chat",
          },
        },
        {
          kind: "message.new",
          chatId: 8n,
          message: {
            id: 1002n,
            date: 1_700_000_001n,
            fromId: 42n,
            message: "second chat",
          },
        },
      ],
      chats: {
        "7": { kind: "direct", title: "Alice" },
        "8": { kind: "direct", title: "Alice Thread" },
      },
      dispatchReplyPayload: {
        text: "reply",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {
        messages: {
          inbound: {
            byChannel: {
              inline: 30,
            },
          },
        },
      } as any,
      account: buildAccount({ dmPolicy: "open" }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalledTimes(2)
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          Body: "first chat",
          MessageSid: "1001",
          To: "inline:7",
        }),
      )
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          Body: "second chat",
          MessageSid: "1002",
          To: "inline:8",
        }),
      )
    })
    expect(harness.calls.finalizeInboundContext).not.toHaveBeenCalledWith(
      expect.objectContaining({
        RawBody: "first chat\nsecond chat",
      }),
    )

    await handle.stop()
  })

  it("dispatches message action callbacks before pending debounced text flushes", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 7n,
          message: {
            id: 1001n,
            date: 1_700_000_000n,
            fromId: 42n,
            message: "queued before callback",
          },
        },
        {
          kind: "message.action.invoke",
          chatId: 7n,
          interactionId: 22n,
          messageId: 1000n,
          actorUserId: 42n,
          actionId: "pick",
          data: new Uint8Array([112, 105, 99, 107]),
        },
      ],
      chats: {
        "7": { kind: "direct", title: "Alice" },
      },
      historyByChat: {
        "7": [{ id: 1000n, date: 1_700_000_000n, fromId: 777n, message: "original" }],
      },
      dispatchReplyPayload: {
        text: "reply",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {
        messages: {
          inbound: {
            byChannel: {
              inline: 200,
            },
          },
        },
      } as any,
      account: buildAccount({ dmPolicy: "open" }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalledTimes(2)
    })

    const contexts = harness.calls.finalizeInboundContext.mock.calls.map((call) => call[0])
    expect(contexts[0]).toEqual(
      expect.objectContaining({
        MessageActionInteractionId: "22",
        MessageActionId: "pick",
        Body: 'Alice pressed "pick" on message #1000',
      }),
    )
    expect(contexts[1]).toEqual(
      expect.objectContaining({
        Body: "queued before callback",
        MessageSid: "1001",
      }),
    )
    expect(harness.calls.answerMessageAction.mock.invocationCallOrder[0]).toBeLessThan(
      harness.calls.dispatchReply.mock.invocationCallOrder[0] ?? Number.POSITIVE_INFINITY,
    )

    await handle.stop()
  })

  it("dispatches stop requests without waiting for an active inbound run", async () => {
    let releaseFirstRun!: () => void
    const firstRunBlocked = new Promise<void>((resolve) => {
      releaseFirstRun = resolve
    })
    let blockedFirstRun = false

    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 7n,
          message: {
            id: 1001n,
            date: 1_700_000_000n,
            fromId: 42n,
            message: "long task",
          },
        },
        {
          kind: "message.new",
          chatId: 7n,
          message: {
            id: 1002n,
            date: 1_700_000_001n,
            fromId: 42n,
            message: "/stop",
          },
        },
      ],
      chats: {
        "7": { kind: "direct", title: "Alice" },
      },
      dispatchReplyBlocker: async ({ ctx }) => {
        if ((ctx as { Body?: string }).Body !== "long task") return
        blockedFirstRun = true
        await firstRunBlocked
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ dmPolicy: "open" }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(blockedFirstRun).toBe(true)
      expect(harness.calls.dispatchReply).toHaveBeenCalledTimes(2)
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          Body: "/stop",
          CommandBody: "/stop",
          MessageSid: "1002",
        }),
      )
    })

    releaseFirstRun()
    await waitForMockPromise(harness.calls.dispatchReply, 0)
    await waitForMockPromise(harness.calls.dispatchReply, 1)
    await handle.stop()
  })

  it("cancels pending debounced text when a stop request arrives", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 7n,
          message: {
            id: 1001n,
            date: 1_700_000_000n,
            fromId: 42n,
            message: "queued before stop",
          },
        },
        {
          kind: "message.new",
          chatId: 7n,
          message: {
            id: 1002n,
            date: 1_700_000_001n,
            fromId: 42n,
            message: "/stop",
          },
        },
      ],
      chats: {
        "7": { kind: "direct", title: "Alice" },
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {
        messages: {
          inbound: {
            byChannel: {
              inline: 40,
            },
          },
        },
      } as any,
      account: buildAccount({ dmPolicy: "open" }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalledTimes(1)
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          Body: "/stop",
          CommandBody: "/stop",
          MessageSid: "1002",
        }),
      )
    })

    await new Promise((resolve) => setTimeout(resolve, 80))
    expect(harness.calls.dispatchReply).toHaveBeenCalledTimes(1)
    expect(harness.calls.finalizeInboundContext).not.toHaveBeenCalledWith(
      expect.objectContaining({
        Body: "queued before stop",
        MessageSid: "1001",
      }),
    )

    await handle.stop()
  })

  it("does not cancel pending debounced text for unauthorized group stop requests", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 7n,
          message: {
            id: 1001n,
            date: 1_700_000_000n,
            fromId: 42n,
            message: "queued before unauthorized stop",
          },
        },
        {
          kind: "message.new",
          chatId: 7n,
          message: {
            id: 1002n,
            date: 1_700_000_001n,
            fromId: 42n,
            message: "/stop",
          },
        },
      ],
      chats: {
        "7": { kind: "group", title: "Ops" },
      },
      resolveControlCommandGate: ({ hasControlCommand }: any) => ({
        commandAuthorized: !hasControlCommand,
        shouldBlock: Boolean(hasControlCommand),
      }),
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {
        messages: {
          inbound: {
            byChannel: {
              inline: 40,
            },
          },
        },
      } as any,
      account: buildAccount({
        groupPolicy: "open",
        requireMention: false,
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalledTimes(1)
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          Body: "queued before unauthorized stop",
          MessageSid: "1001",
        }),
      )
    })
    expect(harness.calls.finalizeInboundContext).not.toHaveBeenCalledWith(
      expect.objectContaining({
        Body: "/stop",
        MessageSid: "1002",
      }),
    )

    await handle.stop()
  })

  it("does not use DM allowFrom to authorize group stop requests", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 7n,
          message: {
            id: 1001n,
            date: 1_700_000_000n,
            fromId: 42n,
            message: "queued before group stop",
          },
        },
        {
          kind: "message.new",
          chatId: 7n,
          message: {
            id: 1002n,
            date: 1_700_000_001n,
            fromId: 42n,
            message: "/stop",
          },
        },
      ],
      chats: {
        "7": { kind: "group", title: "Ops" },
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {
        messages: {
          inbound: {
            byChannel: {
              inline: 40,
            },
          },
        },
      } as any,
      account: buildAccount({
        groupPolicy: "open",
        requireMention: false,
        allowFrom: ["42"],
        groupAllowFrom: [],
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalledTimes(1)
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          Body: "queued before group stop",
          MessageSid: "1001",
        }),
      )
    })
    expect(harness.calls.finalizeInboundContext).not.toHaveBeenCalledWith(
      expect.objectContaining({
        Body: "/stop",
        MessageSid: "1002",
      }),
    )

    await handle.stop()
  })

  it("cancels pending debounced text when a voice transcript resolves to stop", async () => {
    const voiceMedia = {
      media: {
        oneofKind: "voice",
        voice: {
          voice: {
            id: 9101n,
            cdnUrl: "https://cdn.inline.chat/stop-voice.ogg",
            mimeType: "audio/ogg",
            size: 12_345,
            duration: 2,
          },
        },
      },
    }
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 7n,
          message: {
            id: 1001n,
            date: 1_700_000_000n,
            fromId: 42n,
            message: "queued before voice stop",
          },
        },
        {
          kind: "message.new",
          chatId: 7n,
          message: {
            id: 1002n,
            date: 1_700_000_001n,
            fromId: 42n,
            message: "",
            media: voiceMedia,
          } as any,
        },
        {
          kind: "message.edit",
          chatId: 7n,
          message: {
            id: 1002n,
            date: 1_700_000_002n,
            fromId: 42n,
            message: "/stop",
            media: voiceMedia,
          } as any,
        },
      ],
      chats: {
        "7": { kind: "direct", title: "Alice" },
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {
        messages: {
          inbound: {
            byChannel: {
              inline: 40,
            },
          },
        },
      } as any,
      account: buildAccount({
        dmPolicy: "open",
        voiceTranscriptWaitMs: 200,
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalledTimes(1)
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          Body: "/stop",
          CommandBody: "/stop",
          MessageSid: "1002",
        }),
      )
    })

    await new Promise((resolve) => setTimeout(resolve, 80))
    expect(harness.calls.dispatchReply).toHaveBeenCalledTimes(1)
    expect(harness.calls.finalizeInboundContext).not.toHaveBeenCalledWith(
      expect.objectContaining({
        Body: "queued before voice stop",
        MessageSid: "1001",
      }),
    )
    expect(harness.calls.fetchRemoteMedia).not.toHaveBeenCalled()

    await handle.stop()
  })

  it("does not cancel pending debounced text for unauthorized voice stop transcripts", async () => {
    const voiceMedia = {
      media: {
        oneofKind: "voice",
        voice: {
          voice: {
            id: 9103n,
            cdnUrl: "https://cdn.inline.chat/unauthorized-stop-voice.ogg",
            mimeType: "audio/ogg",
            size: 12_345,
            duration: 2,
          },
        },
      },
    }
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 7n,
          message: {
            id: 1001n,
            date: 1_700_000_000n,
            fromId: 42n,
            message: "queued before unauthorized voice stop",
          },
        },
        {
          kind: "message.new",
          chatId: 7n,
          message: {
            id: 1002n,
            date: 1_700_000_001n,
            fromId: 42n,
            message: "",
            media: voiceMedia,
          } as any,
        },
        {
          kind: "message.edit",
          chatId: 7n,
          message: {
            id: 1002n,
            date: 1_700_000_002n,
            fromId: 42n,
            message: "/stop",
            media: voiceMedia,
          } as any,
        },
      ],
      chats: {
        "7": { kind: "group", title: "Ops" },
      },
      resolveControlCommandGate: ({ hasControlCommand }: any) => ({
        commandAuthorized: !hasControlCommand,
        shouldBlock: Boolean(hasControlCommand),
      }),
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {
        messages: {
          inbound: {
            byChannel: {
              inline: 40,
            },
          },
        },
      } as any,
      account: buildAccount({
        groupPolicy: "open",
        requireMention: false,
        voiceTranscriptWaitMs: 200,
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalledTimes(1)
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          Body: "queued before unauthorized voice stop",
          MessageSid: "1001",
        }),
      )
    })
    expect(harness.calls.fetchRemoteMedia).not.toHaveBeenCalled()
    expect(harness.calls.finalizeInboundContext).not.toHaveBeenCalledWith(
      expect.objectContaining({
        Body: "/stop",
        MessageSid: "1002",
      }),
    )

    await handle.stop()
  })

  it("cancels held voice messages and suppresses their transcript edits when stop arrives", async () => {
    const voiceMedia = {
      media: {
        oneofKind: "voice",
        voice: {
          voice: {
            id: 9102n,
            cdnUrl: "https://cdn.inline.chat/canceled-voice.ogg",
            mimeType: "audio/ogg",
            size: 12_345,
            duration: 3,
          },
        },
      },
    }
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 7n,
          message: {
            id: 1001n,
            date: 1_700_000_000n,
            fromId: 42n,
            message: "",
            media: voiceMedia,
          } as any,
        },
        {
          kind: "message.new",
          chatId: 7n,
          message: {
            id: 1002n,
            date: 1_700_000_001n,
            fromId: 42n,
            message: "/stop",
          },
        },
        {
          kind: "message.edit",
          chatId: 7n,
          message: {
            id: 1001n,
            date: 1_700_000_002n,
            fromId: 42n,
            message: "transcript after stop",
            media: voiceMedia,
          } as any,
        },
      ],
      chats: {
        "7": { kind: "direct", title: "Alice" },
      },
      mediaByUrl: {
        "https://cdn.inline.chat/canceled-voice.ogg": {
          contentType: "audio/ogg",
          fileName: "canceled-voice.ogg",
        },
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        dmPolicy: "open",
        voiceTranscriptWaitMs: 20,
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalledTimes(1)
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          Body: "/stop",
          CommandBody: "/stop",
          MessageSid: "1002",
        }),
      )
    })

    await new Promise((resolve) => setTimeout(resolve, 80))
    expect(harness.calls.dispatchReply).toHaveBeenCalledTimes(1)
    expect(harness.calls.fetchRemoteMedia).not.toHaveBeenCalled()
    expect(harness.calls.enqueueSystemEvent).not.toHaveBeenCalled()
    expect(harness.calls.finalizeInboundContext).not.toHaveBeenCalledWith(
      expect.objectContaining({
        Body: "transcript after stop",
        MessageSid: "1001",
      }),
    )

    await handle.stop()
  })

  it("forwards reply-pipeline payload transforms to the dispatcher", async () => {
    const transformReplyPayload = vi.fn((payload: Record<string, unknown>) => ({
      ...payload,
      text: `transformed ${String(payload.text ?? "")}`,
    }))
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 7n,
          message: {
            id: 1001n,
            date: 1_700_000_000n,
            fromId: 42n,
            message: "hello",
          },
        },
      ],
      chats: {
        "7": { kind: "direct", title: "Alice" },
      },
      dispatchReplyPayload: {
        text: "agent reply",
      },
      replyPipeline: {
        transformReplyPayload,
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ dmPolicy: "open" }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalledTimes(1)
      expect(harness.calls.dispatchReply.mock.calls[0]?.[0].dispatcherOptions.transformReplyPayload).toBe(
        transformReplyPayload,
      )
      expect(transformReplyPayload).toHaveBeenCalledWith(expect.objectContaining({ text: "agent reply" }))
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 7n,
          text: "transformed agent reply",
        }),
      )
    })

    await handle.stop()
  })

  it("sanitizes Inline-specific visible reply text before sending", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 7n,
          message: {
            id: 1001n,
            date: 1_700_000_000n,
            fromId: 42n,
            message: "hello",
          },
        },
      ],
      chats: {
        "7": { kind: "direct", title: "Alice" },
      },
      dispatchReplyPayload: {
        text: "See `https://example.com/docs`.\n\n/focus - Bind this thread (Discord) or topic/conversation (Telegram) to a session target.",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ dmPolicy: "open" }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 7n,
          text: "See https://example.com/docs.\n\n/focus - Bind this Inline conversation to a session target.",
        }),
      )
    })

    await handle.stop()
  })

  it("routes direct messages by sender id and preserves reply-to message id", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 7n,
          message: {
            id: 1001n,
            date: 1_700_000_000n,
            fromId: 42n,
            message: "hello from dm",
            replyToMsgId: 9n,
          },
        },
      ],
      chats: {
        "7": { kind: "direct", title: "Alice" },
      },
      dispatchReplyPayload: {
        text: "agent reply",
        replyToId: "555",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ dmPolicy: "open" }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.resolveAgentRoute).toHaveBeenCalledWith(
        expect.objectContaining({
          peer: { kind: "direct", id: "42" },
        }),
      )
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          ChatType: "direct",
          InboundEventKind: "user_request",
          ReplyToId: "9",
          From: "inline:42",
          To: "inline:7",
        }),
      )
      expect(harness.calls.finalizeInboundContext.mock.calls[0]?.[0]).not.toHaveProperty("MessageThreadId")
      expect(harness.calls.finalizeInboundContext.mock.calls[0]?.[0]).not.toHaveProperty("WasMentioned")
      expect(harness.calls.recordInboundSession).toHaveBeenCalledWith(
        expect.objectContaining({
          updateLastRoute: expect.objectContaining({
            channel: "inline",
            to: "inline:7",
          }),
        }),
      )
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 7n,
          text: "agent reply",
          replyToMsgId: 555n,
          parseMarkdown: true,
        }),
      )
    })

    await handle.stop()
  })

  it("uses parent chat targeting and thread metadata for inbound reply-thread messages", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 7100n,
          message: {
            id: 61002n,
            date: 1_700_000_010n,
            fromId: 42n,
            message: "can you handle this reply thread?",
          },
        },
      ],
      chats: {
        "7000": { kind: "group", title: "Deploy Room" },
        "7100": {
          kind: "group",
          title: "Re: deploy plan",
          parentChatId: 7000n,
          parentMessageId: 5000n,
        },
      },
      historyByChat: {
        "7000": [
          {
            id: 4999n,
            date: 1_700_000_001n,
            fromId: 51n,
            message: "unrelated parent chat line",
          },
          {
            id: 5000n,
            date: 1_700_000_002n,
            fromId: 41n,
            message: "Parent thread anchor",
          },
        ],
        "7100": [
          {
            id: 61001n,
            date: 1_700_000_009n,
            fromId: 51n,
            message: "thread follow-up context",
          },
          {
            id: 61002n,
            date: 1_700_000_010n,
            fromId: 42n,
            message: "can you handle this reply thread?",
          },
        ],
      },
      dispatchReplyPayload: {
        text: "thread reply",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ groupPolicy: "open", requireMention: false, replyThreads: true }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.resolveAgentRoute).toHaveBeenCalledWith(
        expect.objectContaining({
          peer: { kind: "group", id: "7000" },
        }),
      )
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          SessionKey: "agent:main:inline:group:7000:thread:7100",
          ParentSessionKey: "agent:main:inline:group:7000",
          To: "inline:7000",
          OriginatingTo: "inline:7000",
          GroupSubject: "Deploy Room",
          MessageThreadId: "7100",
          ThreadLabel: "Re: deploy plan",
          Body: "can you handle this reply thread?",
          BodyForAgent: "can you handle this reply thread?",
          GroupSystemPrompt: expect.stringContaining("do not answer unrelated questions from the parent chat or other reply threads"),
          InboundHistory: expect.arrayContaining([
            expect.objectContaining({ body: "unrelated parent chat line" }),
            expect.objectContaining({ body: "Parent thread anchor" }),
            expect.objectContaining({ body: "thread follow-up context" }),
          ]),
        }),
      )
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 7100n,
          text: "thread reply",
        }),
      )
    })

    await handle.stop()
  })

  it("continues bot-participated reply threads without an explicit mention by default", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 7100n,
          message: {
            id: 61003n,
            date: 1_700_000_011n,
            fromId: 42n,
            message: "follow-up without mention",
            mentioned: false,
          },
        },
      ],
      chats: {
        "7000": { kind: "group", title: "Deploy Room" },
        "7100": {
          kind: "group",
          title: "Re: deploy plan",
          parentChatId: 7000n,
          parentMessageId: 5000n,
        },
      },
      historyByChat: {
        "7000": [{ id: 5000n, date: 1_700_000_002n, fromId: 41n, message: "Parent thread anchor" }],
        "7100": [
          {
            id: 61002n,
            date: 1_700_000_010n,
            fromId: 777n,
            message: "earlier bot reply",
            out: true,
          },
          {
            id: 61003n,
            date: 1_700_000_011n,
            fromId: 42n,
            message: "follow-up without mention",
          },
        ],
      },
      dispatchReplyPayload: {
        text: "continuing in thread",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ groupPolicy: "open", requireMention: true, replyThreads: true }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalledTimes(1)
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          SessionKey: "agent:main:inline:group:7000:thread:7100",
          ParentSessionKey: "agent:main:inline:group:7000",
          MessageThreadId: "7100",
          Body: "follow-up without mention",
          WasMentioned: true,
          ExplicitlyMentionedBot: false,
          MentionSource: "implicit_thread",
          ImplicitMentionKinds: ["reply_thread"],
          InboundHistory: expect.arrayContaining([
            expect.objectContaining({ body: "Parent thread anchor" }),
            expect.objectContaining({ body: "earlier bot reply" }),
          ]),
        }),
      )
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 7100n,
          text: "continuing in thread",
        }),
      )
    })

    await handle.stop()
  })

  it("continues bot-participated reply threads from persistent participation when history is sparse", async () => {
    const register = vi.fn(async () => {})
    const lookup = vi.fn(async (key: string) =>
      key === "default:7000:7100" ? { repliedAt: 1_700_000_000 } : undefined,
    )
    const openKeyedStore = vi.fn(() => ({ register, lookup }))
    const harness = await setupMonitorHarness({
      openKeyedStore,
      events: [
        {
          kind: "message.new",
          chatId: 7100n,
          message: {
            id: 61003n,
            date: 1_700_000_011n,
            fromId: 42n,
            message: "still here?",
            mentioned: false,
          },
        },
      ],
      chats: {
        "7000": { kind: "group", title: "Deploy Room" },
        "7100": {
          kind: "group",
          title: "Re: deploy plan",
          parentChatId: 7000n,
          parentMessageId: 5000n,
        },
      },
      historyByChat: {
        "7000": [{ id: 5000n, date: 1_700_000_002n, fromId: 41n, message: "Parent thread anchor" }],
        "7100": [
          {
            id: 61003n,
            date: 1_700_000_011n,
            fromId: 42n,
            message: "still here?",
          },
        ],
      },
      dispatchReplyPayload: {
        text: "yes",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ groupPolicy: "open", requireMention: true, replyThreads: true }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(lookup).toHaveBeenCalledWith("default:7000:7100")
      expect(harness.calls.dispatchReply).toHaveBeenCalledTimes(1)
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          SessionKey: "agent:main:inline:group:7000:thread:7100",
          ParentSessionKey: "agent:main:inline:group:7000",
          MessageThreadId: "7100",
          WasMentioned: true,
          ExplicitlyMentionedBot: false,
          MentionSource: "implicit_thread",
          ImplicitMentionKinds: ["reply_thread"],
        }),
      )
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 7100n,
          text: "yes",
        }),
      )
      expect(register).toHaveBeenCalledWith(
        "default:7000:7100",
        expect.objectContaining({ agentId: "main" }),
        { ttlMs: 86_400_000 },
      )
    })

    await handle.stop()
  })

  it("continues followed Inline threads without an explicit mention by default", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 7200n,
          message: {
            id: 12n,
            date: 1_700_000_011n,
            fromId: 42n,
            message: "fresh followed thread follow-up",
            mentioned: false,
          },
        },
      ],
      chats: {
        "7200": {
          kind: "group",
          title: "Fresh thread",
          lastMsgId: 12n,
          dialogFollowMode: 1,
        },
      },
      historyByChat: {
        "7200": [
          {
            id: 12n,
            date: 1_700_000_011n,
            fromId: 42n,
            message: "fresh followed thread follow-up",
          },
        ],
      },
      dispatchReplyPayload: {
        text: "continuing",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ groupPolicy: "open", requireMention: true, replyThreads: true }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalledTimes(1)
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          SessionKey: "agent:main:inline:group:7200",
          Body: "fresh followed thread follow-up",
          WasMentioned: true,
          ExplicitlyMentionedBot: false,
          MentionSource: "implicit_thread",
          ImplicitMentionKinds: ["follow_mode"],
        }),
      )
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 7200n,
          text: "continuing",
        }),
      )
    })

    await handle.stop()
  })

  it("does not treat follow mode as an implicit mention in large non-reply threads", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 7201n,
          message: {
            id: 75n,
            date: 1_700_000_011n,
            fromId: 42n,
            message: "large followed thread without mention",
            mentioned: false,
          },
        },
      ],
      chats: {
        "7201": {
          kind: "group",
          title: "Large followed thread",
          lastMsgId: 75n,
          dialogFollowMode: 1,
        },
      },
      historyByChat: {
        "7201": [
          {
            id: 75n,
            date: 1_700_000_011n,
            fromId: 42n,
            message: "large followed thread without mention",
          },
        ],
      },
      dispatchReplyPayload: {
        text: "should not send",
      },
    })

    const runtime = { log: vi.fn(), error: vi.fn() }
    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ groupPolicy: "open", requireMention: true, replyThreads: true }),
      runtime: runtime as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(runtime.log).toHaveBeenCalledWith(expect.stringContaining("no mention"))
      expect(harness.calls.dispatchReply).not.toHaveBeenCalled()
      expect(harness.calls.sendMessage).not.toHaveBeenCalled()
    })

    await handle.stop()
  })

  it("can require explicit mentions inside reply threads by parent chat policy", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 7100n,
          message: {
            id: 61003n,
            date: 1_700_000_011n,
            fromId: 42n,
            message: "silent follow-up",
            mentioned: false,
          },
        },
      ],
      chats: {
        "7000": { kind: "group", title: "Deploy Room" },
        "7100": {
          kind: "group",
          title: "Re: deploy plan",
          parentChatId: 7000n,
          parentMessageId: 5000n,
          dialogFollowMode: 1,
        },
      },
      historyByChat: {
        "7000": [{ id: 5000n, date: 1_700_000_002n, fromId: 41n, message: "Parent thread anchor" }],
        "7100": [
          {
            id: 61002n,
            date: 1_700_000_010n,
            fromId: 777n,
            message: "earlier bot reply",
            out: true,
          },
        ],
      },
      dispatchReplyPayload: {
        text: "should not send",
      },
    })

    const runtime = { log: vi.fn(), error: vi.fn() }
    const handle = await harness.monitorInlineProvider({
      cfg: {
        channels: {
          inline: {
            groups: {
              "7000": { replyThreadRequireExplicitMention: true },
            },
          },
        },
      } as any,
      account: buildAccount({ groupPolicy: "open", requireMention: true, replyThreads: true }),
      runtime: runtime as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(runtime.log).toHaveBeenCalledWith(expect.stringContaining("no mention"))
      expect(harness.calls.dispatchReply).not.toHaveBeenCalled()
      expect(harness.calls.sendMessage).not.toHaveBeenCalled()
    })

    await handle.stop()
  })

  it("can include limited parent chat history before a reply-thread anchor when configured", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 7100n,
          message: {
            id: 61002n,
            date: 1_700_000_010n,
            fromId: 42n,
            message: "what did we decide?",
          },
        },
      ],
      chats: {
        "7000": { kind: "group", title: "Deploy Room" },
        "7100": {
          kind: "group",
          title: "Re: deploy plan",
          parentChatId: 7000n,
          parentMessageId: 5000n,
        },
      },
      historyByChat: {
        "7000": [
          {
            id: 4999n,
            date: 1_700_000_001n,
            fromId: 51n,
            message: "parent context worth inheriting",
          },
          {
            id: 5000n,
            date: 1_700_000_002n,
            fromId: 41n,
            message: "Parent thread anchor",
          },
        ],
        "7100": [
          {
            id: 61001n,
            date: 1_700_000_009n,
            fromId: 777n,
            message: "thread-local bot context",
            out: true,
          },
          {
            id: 61002n,
            date: 1_700_000_010n,
            fromId: 42n,
            message: "what did we decide?",
          },
        ],
      },
      dispatchReplyPayload: {
        text: "parent-aware reply",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {
        channels: {
          inline: {
            groups: {
              "7000": { replyThreadParentHistoryLimit: 1 },
            },
          },
        },
      } as any,
      account: buildAccount({ groupPolicy: "open", requireMention: false, replyThreads: true }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      const ctx = harness.calls.finalizeInboundContext.mock.calls[0]?.[0]
      expect(ctx.InboundHistory.map((entry: { body: string }) => entry.body)).toEqual([
        "parent context worth inheriting",
        "Parent thread anchor",
        "thread-local bot context",
      ])
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 7100n,
          text: "parent-aware reply",
        }),
      )
    })

    await handle.stop()
  })

  it("does not promote reply-thread anchor images to current media paths", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 7100n,
          message: {
            id: 61002n,
            date: 1_700_000_010n,
            fromId: 42n,
            message: "what about this image?",
          },
        },
      ],
      chats: {
        "7000": { kind: "group", title: "Deploy Room" },
        "7100": {
          kind: "group",
          title: "Re: image",
          parentChatId: 7000n,
          parentMessageId: 5000n,
        },
      },
      historyByChat: {
        "7000": [
          {
            id: 5000n,
            date: 1_700_000_002n,
            fromId: 41n,
            message: "",
            media: {
              media: {
                oneofKind: "photo",
                photo: {
                  photo: {
                    id: 901n,
                    sizes: [{ w: 1200, h: 900, size: 12345, cdnUrl: "https://cdn.inline.chat/anchor-photo.jpg" }],
                  },
                },
              },
            },
          } as any,
        ],
        "7100": [
          {
            id: 61002n,
            date: 1_700_000_010n,
            fromId: 42n,
            message: "what about this image?",
          },
        ],
      },
      mediaByUrl: {
        "https://cdn.inline.chat/anchor-photo.jpg": {
          contentType: "image/jpeg",
          fileName: "anchor-photo.jpg",
        },
      },
      dispatchReplyPayload: {
        text: "anchor media reply",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ groupPolicy: "open", requireMention: false, replyThreads: true }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.fetchRemoteMedia).not.toHaveBeenCalled()
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          Body: "what about this image?",
          BodyForAgent: "what about this image?",
          UntrustedStructuredContext: expect.arrayContaining([
            expect.objectContaining({
              type: "recent_media_attachments",
              payload: {
                summary: "Recent media/attachments: #5000 user:41: image attachment: https://cdn.inline.chat/anchor-photo.jpg",
              },
            }),
          ]),
        }),
      )
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.not.objectContaining({
          MediaPath: expect.anything(),
          MediaUrl: expect.anything(),
          MediaPaths: expect.anything(),
          MediaUrls: expect.anything(),
        }),
      )
    })

    await handle.stop()
  })

  it("creates and replies in a child reply thread when the parent chat is configured for threaded replies", async () => {
    const harness = await setupMonitorHarness({
      me: {
        userId: 777n,
        username: "inlinebot",
      },
      events: [
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 2002n,
            date: 1_700_000_002n,
            fromId: 51n,
            message: "@inlinebot can you look at this?",
            mentioned: true,
          },
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      historyByChat: {
        "88": [
          {
            id: 2001n,
            date: 1_700_000_001n,
            fromId: 52n,
            message: "unrelated parent room context",
          },
          {
            id: 2002n,
            date: 1_700_000_002n,
            fromId: 51n,
            message: "@inlinebot can you look at this?",
          },
        ],
      },
      dispatchReplyPayload: {
        text: "threaded reply",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {
        channels: {
          inline: {
            groups: {
              "88": { replyThreadMode: "thread" },
            },
          },
        },
      } as any,
      account: buildAccount({ groupPolicy: "open", requireMention: true }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.invokeRaw).toHaveBeenCalledWith(
        42,
        expect.objectContaining({
          oneofKind: "createSubthread",
          createSubthread: expect.objectContaining({
            parentChatId: 88n,
            parentMessageId: 2002n,
          }),
        }),
      )
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          SessionKey: "agent:main:inline:group:88:thread:882002",
          ParentSessionKey: "agent:main:inline:group:88",
          To: "inline:88",
          OriginatingTo: "inline:88",
          MessageThreadId: "882002",
          ThreadLabel: "Re: @inlinebot can you look at this?",
          Body: "@inlinebot can you look at this?",
          BodyForAgent: "can you look at this?",
          InboundHistory: [
            expect.objectContaining({
              body: "unrelated parent room context",
            }),
            expect.objectContaining({
              body: "@inlinebot can you look at this?",
            }),
          ],
        }),
      )
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 882002n,
          text: "threaded reply",
        }),
      )
      expect(harness.calls.sendMessage.mock.calls[0]?.[0]).not.toHaveProperty("replyToMsgId")
    })

    await handle.stop()
  })

  it("keeps small ordinary chats in-place instead of creating a child reply thread", async () => {
    const harness = await setupMonitorHarness({
      me: {
        userId: 777n,
        username: "inlinebot",
      },
      events: [
        {
          kind: "message.new",
          chatId: 89n,
          message: {
            id: 12n,
            date: 1_700_000_012n,
            fromId: 51n,
            message: "@inlinebot answer here",
            mentioned: true,
          },
        },
      ],
      chats: {
        "89": { kind: "group", title: "Short Project Thread" },
      },
      dispatchReplyPayload: {
        text: "same chat reply",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {
        channels: {
          inline: {
            groups: {
              "89": { replyThreadMode: "thread" },
            },
          },
        },
      } as any,
      account: buildAccount({ groupPolicy: "open", requireMention: true }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 89n,
          text: "same chat reply",
        }),
      )
    })
    expect(harness.calls.invokeRaw).not.toHaveBeenCalledWith(
      42,
      expect.objectContaining({ oneofKind: "createSubthread" }),
    )
    expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
      expect.not.objectContaining({
        MessageThreadId: expect.any(String),
      }),
    )

    await handle.stop()
  })

  it("creates and replies in a child reply thread in auto mode when the message asks for it", async () => {
    const harness = await setupMonitorHarness({
      me: {
        userId: 777n,
        username: "inlinebot",
      },
      events: [
        {
          kind: "message.new",
          chatId: 89n,
          message: {
            id: 12n,
            date: 1_700_000_012n,
            fromId: 51n,
            message: "@inlinebot reply in a thread with the answer",
            mentioned: true,
          },
        },
      ],
      chats: {
        "89": { kind: "group", title: "Auto Thread Room" },
      },
      historyByChat: {
        "89": [
          {
            id: 12n,
            date: 1_700_000_012n,
            fromId: 51n,
            message: "@inlinebot reply in a thread with the answer",
          },
        ],
      },
      dispatchReplyPayload: {
        text: "thread reply",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {
        channels: {
          inline: {
            groups: {
              "89": { replyThreadMode: "auto" },
            },
          },
        },
      } as any,
      account: buildAccount({ groupPolicy: "open", requireMention: true }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.invokeRaw).toHaveBeenCalledWith(
        42,
        expect.objectContaining({
          oneofKind: "createSubthread",
          createSubthread: expect.objectContaining({
            parentChatId: 89n,
            parentMessageId: 12n,
          }),
        }),
      )
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 8912n,
          text: "thread reply",
        }),
      )
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          SessionKey: "agent:main:inline:group:89:thread:8912",
          ParentSessionKey: "agent:main:inline:group:89",
          MessageThreadId: "8912",
          ThreadLabel: "Re: @inlinebot reply in a thread with the answer",
          BodyForAgent: "reply in a thread with the answer",
        }),
      )
    })

    await handle.stop()
  })

  it("keeps auto mode in the parent chat when the message says not to thread", async () => {
    const harness = await setupMonitorHarness({
      me: {
        userId: 777n,
        username: "inlinebot",
      },
      events: [
        {
          kind: "message.new",
          chatId: 93n,
          message: {
            id: 130n,
            date: 1_700_000_013n,
            fromId: 51n,
            message: "@inlinebot don't reply in a thread, answer here",
            mentioned: true,
          },
        },
      ],
      chats: {
        "93": { kind: "group", title: "Auto Parent Room" },
      },
      dispatchReplyPayload: {
        text: "parent reply",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {
        channels: {
          inline: {
            groups: {
              "93": { replyThreadMode: "auto" },
            },
          },
        },
      } as any,
      account: buildAccount({ groupPolicy: "open", requireMention: true }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 93n,
          text: "parent reply",
        }),
      )
    })
    expect(harness.calls.invokeRaw).not.toHaveBeenCalledWith(
      42,
      expect.objectContaining({ oneofKind: "createSubthread" }),
    )
    expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
      expect.not.objectContaining({
        MessageThreadId: expect.any(String),
      }),
    )

    await handle.stop()
  })

  it("creates a new reply thread for a new parent-chat message even when an older active route exists", async () => {
    const register = vi.fn(async () => {})
    const now = Date.now()
    const lookup = vi.fn(async (key: string) => {
      if (!key.includes(":agent:main")) return undefined
      return {
        accountId: "default",
        parentChatId: "88",
        parentMessageId: "2000",
        threadId: "8800",
        threadLabel: "Stable project thread",
        createdAt: now,
        updatedAt: now,
        agentId: "main",
      }
    })
    const openKeyedStore = vi.fn(() => ({ register, lookup }))
    const harness = await setupMonitorHarness({
      me: {
        userId: 777n,
        username: "inlinebot",
      },
      openKeyedStore,
      events: [
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 2003n,
            date: 1_700_000_003n,
            fromId: 51n,
            message: "@inlinebot continue the long work",
            mentioned: true,
          },
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      historyByChat: {
        "88": [
          {
            id: 2000n,
            date: 1_700_000_000n,
            fromId: 51n,
            message: "@inlinebot start the long work",
          },
          {
            id: 2003n,
            date: 1_700_000_003n,
            fromId: 51n,
            message: "@inlinebot continue the long work",
          },
        ],
      },
      dispatchReplyPayload: {
        text: "new thread reply",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {
        channels: {
          inline: {
            groups: {
              "88": { replyThreadMode: "thread" },
            },
          },
        },
      } as any,
      account: buildAccount({ groupPolicy: "open", requireMention: true }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.invokeRaw).toHaveBeenCalledWith(
        42,
        expect.objectContaining({
          oneofKind: "createSubthread",
          createSubthread: expect.objectContaining({
            parentChatId: 88n,
            parentMessageId: 2003n,
          }),
        }),
      )
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 882003n,
          text: "new thread reply",
        }),
      )
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          SessionKey: "agent:main:inline:group:88:thread:882003",
          ParentSessionKey: "agent:main:inline:group:88",
          MessageThreadId: "882003",
          ThreadLabel: "Re: @inlinebot continue the long work",
        }),
      )
    })
    expect(lookup).toHaveBeenCalled()

    await handle.stop()
  })

  it("can override the parent-size gate to thread small ordinary chats", async () => {
    const harness = await setupMonitorHarness({
      me: {
        userId: 777n,
        username: "inlinebot",
      },
      events: [
        {
          kind: "message.new",
          chatId: 90n,
          message: {
            id: 8n,
            date: 1_700_000_013n,
            fromId: 51n,
            message: "@inlinebot start a thread anyway",
            mentioned: true,
          },
        },
      ],
      chats: {
        "90": { kind: "group", title: "Short Thread Override" },
      },
      dispatchReplyPayload: {
        text: "child reply",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {
        channels: {
          inline: {
            groups: {
              "90": {
                replyThreadMode: "thread",
                replyThreadAutoCreateMinMessages: 0,
              },
            },
          },
        },
      } as any,
      account: buildAccount({ groupPolicy: "open", requireMention: true }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.invokeRaw).toHaveBeenCalledWith(
        42,
        expect.objectContaining({
          oneofKind: "createSubthread",
          createSubthread: expect.objectContaining({
            parentChatId: 90n,
            parentMessageId: 8n,
          }),
        }),
      )
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 908n,
          text: "child reply",
        }),
      )
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          SessionKey: "agent:main:inline:group:90:thread:908",
          ParentSessionKey: "agent:main:inline:group:90",
          MessageThreadId: "908",
        }),
      )
    })

    await handle.stop()
  })

  it("uses top-level Inline reply-thread defaults for parent-chat delivery", async () => {
    const harness = await setupMonitorHarness({
      me: {
        userId: 777n,
        username: "inlinebot",
      },
      events: [
        {
          kind: "message.new",
          chatId: 92n,
          message: {
            id: 80n,
            date: 1_700_000_015n,
            fromId: 51n,
            message: "@inlinebot use the top level thread config",
            mentioned: true,
          },
        },
      ],
      chats: {
        "92": { kind: "group", title: "Top Level Thread Defaults" },
      },
      dispatchReplyPayload: {
        text: "top level child reply",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {
        channels: {
          inline: {
            replyThreadMode: "thread",
          },
        },
      } as any,
      account: buildAccount({ groupPolicy: "open", requireMention: true }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.invokeRaw).toHaveBeenCalledWith(
        42,
        expect.objectContaining({
          oneofKind: "createSubthread",
          createSubthread: expect.objectContaining({
            parentChatId: 92n,
            parentMessageId: 80n,
          }),
        }),
      )
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 9280n,
          text: "top level child reply",
        }),
      )
    })

    await handle.stop()
  })

  it("sends typing status to the parent chat and auto-created reply thread chat", async () => {
    const harness = await setupMonitorHarness({
      dispatchTypingLifecycle: true,
      me: {
        userId: 777n,
        username: "inlinebot",
      },
      events: [
        {
          kind: "message.new",
          chatId: 91n,
          message: {
            id: 9n,
            date: 1_700_000_014n,
            fromId: 51n,
            message: "@inlinebot answer in a child thread",
            mentioned: true,
          },
        },
      ],
      chats: {
        "91": { kind: "group", title: "Typing Target Room" },
      },
      dispatchReplyPayload: {
        text: "child reply",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {
        channels: {
          inline: {
            groups: {
              "91": {
                replyThreadMode: "thread",
                replyThreadAutoCreateMinMessages: 0,
              },
            },
          },
        },
      } as any,
      account: buildAccount({ groupPolicy: "open", requireMention: true }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.invokeRaw).toHaveBeenCalledWith(
        42,
        expect.objectContaining({
          oneofKind: "createSubthread",
          createSubthread: expect.objectContaining({
            parentChatId: 91n,
            parentMessageId: 9n,
          }),
        }),
      )
      expect(harness.calls.sendTyping).toHaveBeenCalledWith({ chatId: 91n, typing: true })
      expect(harness.calls.sendTyping).toHaveBeenCalledWith({ chatId: 91n, typing: false })
      expect(harness.calls.sendTyping).toHaveBeenCalledWith({ chatId: 919n, typing: true })
      expect(harness.calls.sendTyping).toHaveBeenCalledWith({ chatId: 919n, typing: false })
      expect(harness.calls.invokeRaw).toHaveBeenCalledWith(
        SET_BOT_PRESENCE_STATE,
        expect.objectContaining({
          oneofKind: "setBotPresenceState",
          setBotPresenceState: expect.objectContaining({
            peerId: expect.objectContaining({
              type: expect.objectContaining({
                oneofKind: "chat",
                chat: { chatId: 91n },
              }),
            }),
            state: { kind: BOT_PRESENCE_IDLE },
          }),
        }),
      )
      expect(harness.calls.invokeRaw).toHaveBeenCalledWith(
        SET_BOT_PRESENCE_STATE,
        expect.objectContaining({
          oneofKind: "setBotPresenceState",
          setBotPresenceState: expect.objectContaining({
            peerId: expect.objectContaining({
              type: expect.objectContaining({
                oneofKind: "chat",
                chat: { chatId: 919n },
              }),
            }),
            state: { kind: BOT_PRESENCE_RUNNING },
          }),
        }),
      )
      expect(harness.calls.recordInboundSession).toHaveBeenCalledWith(
        expect.objectContaining({
          sessionKey: "agent:main:inline:group:91:thread:919",
        }),
      )
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 919n,
          text: "child reply",
        }),
      )
    })

    const childPresenceCalls = harness.calls.invokeRaw.mock.calls.filter(
      ([method, input]) =>
        method === SET_BOT_PRESENCE_STATE &&
        input?.oneofKind === "setBotPresenceState" &&
        input.setBotPresenceState?.peerId?.type?.oneofKind === "chat" &&
        input.setBotPresenceState.peerId.type.chat?.chatId === 919n,
    )
    expect(childPresenceCalls).not.toEqual(
      expect.arrayContaining([
        [
          SET_BOT_PRESENCE_STATE,
          expect.objectContaining({
            setBotPresenceState: expect.objectContaining({
              state: { kind: BOT_PRESENCE_JUMPING },
            }),
          }),
        ],
      ]),
    )

    await handle.stop()
  })

  it("lets reply payload channelData set bot presence comment", async () => {
    const harness = await setupMonitorHarness({
      dispatchTypingLifecycle: true,
      events: [
        {
          kind: "message.new",
          chatId: 7n,
          message: {
            id: 1001n,
            date: 1_700_000_000n,
            fromId: 42n,
            message: "how are you feeling?",
          },
        },
      ],
      chats: {
        "7": { kind: "direct", title: "Alice", peerUserId: 42n },
      },
      dispatchReplyPayload: {
        text: "I'm focused.",
        channelData: {
          inline: {
            botPresence: {
              kind: "review",
              comment: "Thinking it over",
            },
          },
        },
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ dmPolicy: "open" }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.invokeRaw).toHaveBeenCalledWith(
        SET_BOT_PRESENCE_STATE,
        expect.objectContaining({
          oneofKind: "setBotPresenceState",
          setBotPresenceState: expect.objectContaining({
            peerId: expect.objectContaining({
              type: expect.objectContaining({
                oneofKind: "chat",
                chat: { chatId: 7n },
              }),
            }),
            state: { kind: BOT_PRESENCE_REVIEW, comment: "Thinking it over" },
          }),
        }),
      )
    })
    await Promise.resolve()

    const presenceCalls = harness.calls.invokeRaw.mock.calls.filter(
      ([method]) => method === SET_BOT_PRESENCE_STATE,
    )
    expect(presenceCalls).not.toEqual(
      expect.arrayContaining([
        [
          SET_BOT_PRESENCE_STATE,
          expect.objectContaining({
            setBotPresenceState: expect.objectContaining({
              state: { kind: BOT_PRESENCE_JUMPING },
            }),
          }),
        ],
      ]),
    )
    expect(presenceCalls).not.toEqual(
      expect.arrayContaining([
        [
          SET_BOT_PRESENCE_STATE,
          expect.objectContaining({
            setBotPresenceState: expect.objectContaining({
              state: { kind: BOT_PRESENCE_IDLE },
            }),
          }),
        ],
      ]),
    )

    await handle.stop()
  })

  it("lets reply payload channelData set emoji-only bot presence comment", async () => {
    const emojiComment = "\u{1F44B}\u{1F4A1}"
    const harness = await setupMonitorHarness({
      dispatchTypingLifecycle: true,
      events: [
        {
          kind: "message.new",
          chatId: 7n,
          message: {
            id: 1001n,
            date: 1_700_000_000n,
            fromId: 42n,
            message: "say hi",
          },
        },
      ],
      chats: {
        "7": { kind: "direct", title: "Alice", peerUserId: 42n },
      },
      dispatchReplyPayload: {
        text: "Hi.",
        channelData: {
          inline: {
            botPresence: {
              kind: "waving",
              comment: emojiComment,
            },
          },
        },
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ dmPolicy: "open" }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.invokeRaw).toHaveBeenCalledWith(
        SET_BOT_PRESENCE_STATE,
        expect.objectContaining({
          oneofKind: "setBotPresenceState",
          setBotPresenceState: expect.objectContaining({
            peerId: expect.objectContaining({
              type: expect.objectContaining({
                oneofKind: "chat",
                chat: { chatId: 7n },
              }),
            }),
            state: { kind: BOT_PRESENCE_WAVING, comment: emojiComment },
          }),
        }),
      )
    })

    await handle.stop()
  })

  it("keeps auto-created reply-thread delivery when mirrored parent typing fails", async () => {
    const runtimeError = vi.fn()
    const harness = await setupMonitorHarness({
      dispatchTypingLifecycle: true,
      sendTyping: async ({ chatId }) => {
        if (chatId === 94n) {
          throw new Error("parent typing unavailable")
        }
      },
      me: {
        userId: 777n,
        username: "inlinebot",
      },
      events: [
        {
          kind: "message.new",
          chatId: 94n,
          message: {
            id: 10n,
            date: 1_700_000_014n,
            fromId: 51n,
            message: "@inlinebot answer despite parent typing failure",
            mentioned: true,
          },
        },
      ],
      chats: {
        "94": { kind: "group", title: "Parent Typing Failure Room" },
      },
      dispatchReplyPayload: {
        text: "child reply after parent typing failure",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {
        channels: {
          inline: {
            groups: {
              "94": {
                replyThreadMode: "thread",
                replyThreadAutoCreateMinMessages: 0,
              },
            },
          },
        },
      } as any,
      account: buildAccount({ groupPolicy: "open", requireMention: true }),
      runtime: { log: vi.fn(), error: runtimeError } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.sendTyping).toHaveBeenCalledWith({ chatId: 9410n, typing: true })
      expect(harness.calls.sendTyping).toHaveBeenCalledWith({ chatId: 9410n, typing: false })
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 9410n,
          text: "child reply after parent typing failure",
        }),
      )
    })
    expect(runtimeError).toHaveBeenCalledWith(expect.stringContaining("inline parent reply-thread typing failed"))
    expect(runtimeError).toHaveBeenCalledWith(expect.stringContaining("inline typing start failed for chat 94"))
    expect(runtimeError).not.toHaveBeenCalledWith(expect.stringMatching(/^inline typing start failed: /))

    await handle.stop()
  })

  it("falls back to the parent chat when automatic thread creation fails", async () => {
    const harness = await setupMonitorHarness({
      me: {
        userId: 777n,
        username: "inlinebot",
      },
      createSubthreadError: "boom",
      events: [
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 2003n,
            date: 1_700_000_003n,
            fromId: 51n,
            message: "@inlinebot thread this",
            mentioned: true,
          },
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      dispatchReplyPayload: {
        text: "parent fallback reply",
      },
    })

    const runtime = { log: vi.fn(), error: vi.fn() }
    const handle = await harness.monitorInlineProvider({
      cfg: {
        channels: {
          inline: {
            groups: {
              "88": { replyThreadMode: "thread" },
            },
          },
        },
      } as any,
      account: buildAccount({ groupPolicy: "open", requireMention: true }),
      runtime: runtime as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(runtime.error).toHaveBeenCalledWith(expect.stringContaining("inline create reply thread failed"))
      expect(harness.calls.dispatchReply).toHaveBeenCalled()
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 88n,
          text: "parent fallback reply",
        }),
      )
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          SessionKey: "agent:main:inline:group:88",
          To: "inline:88",
          OriginatingTo: "inline:88",
        }),
      )
    })
    const ctx = harness.calls.finalizeInboundContext.mock.calls[0]?.[0]
    expect(ctx).not.toHaveProperty("MessageThreadId")
    expect(ctx).not.toHaveProperty("ParentSessionKey")

    await handle.stop()
  })

  it("keeps parent-chat replies in the parent chat when that group overrides threaded defaults with main mode", async () => {
    const harness = await setupMonitorHarness({
      me: {
        userId: 777n,
        username: "inlinebot",
      },
      events: [
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 2004n,
            date: 1_700_000_004n,
            fromId: 51n,
            message: "@inlinebot answer here",
            mentioned: true,
          },
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      dispatchReplyPayload: {
        text: "main parent reply",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {
        channels: {
          inline: {
            groups: {
              "88": { replyThreadMode: "main" },
            },
          },
        },
      } as any,
      account: buildAccount({ groupPolicy: "open", requireMention: true, replyThreadMode: "thread" }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 88n,
          text: "main parent reply",
        }),
      )
    })
    expect(harness.calls.invokeRaw).not.toHaveBeenCalledWith(
      42,
      expect.objectContaining({ oneofKind: "createSubthread" }),
    )
    expect(harness.calls.sendMessage.mock.calls[0]?.[0]).not.toHaveProperty("replyToMsgId")

    await handle.stop()
  })

  it("keeps explicit reply-thread inbound messages in the thread even when the parent chat is main mode", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 7100n,
          message: {
            id: 61002n,
            date: 1_700_000_010n,
            fromId: 42n,
            message: "please answer in main",
          },
        },
      ],
      chats: {
        "7000": { kind: "group", title: "Deploy Room" },
        "7100": {
          kind: "group",
          title: "Re: deploy plan",
          parentChatId: 7000n,
          parentMessageId: 5000n,
        },
      },
      historyByChat: {
        "7000": [{ id: 5000n, date: 1_700_000_002n, fromId: 41n, message: "Parent thread anchor" }],
        "7100": [{ id: 61002n, date: 1_700_000_010n, fromId: 42n, message: "please answer in main" }],
      },
      dispatchReplyPayload: {
        text: "main reply",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {
        channels: {
          inline: {
            groups: {
              "7000": { replyThreadMode: "main" },
            },
          },
        },
      } as any,
      account: buildAccount({ groupPolicy: "open", requireMention: false }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          To: "inline:7000",
          OriginatingTo: "inline:7000",
          GroupSubject: "Deploy Room",
          Body: "please answer in main",
          BodyForAgent: "please answer in main",
        }),
      )
      const ctx = harness.calls.finalizeInboundContext.mock.calls[0]?.[0]
      expect(ctx).toEqual(
        expect.objectContaining({
          SessionKey: "agent:main:inline:group:7000:thread:7100",
          ParentSessionKey: "agent:main:inline:group:7000",
          MessageThreadId: "7100",
          ThreadLabel: "Re: deploy plan",
        }),
      )
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 7100n,
          text: "main reply",
        }),
      )
    })

    await handle.stop()
  })

  it("falls back to current non-threaded behavior when reply-thread metadata is unavailable", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 7200n,
          message: {
            id: 62002n,
            date: 1_700_000_020n,
            fromId: 42n,
            message: "reply thread metadata missing",
          },
        },
      ],
      chats: {
        "7200": { kind: "group", title: "Unknown Child Chat" },
      },
      historyByChat: {
        "7200": [
          {
            id: 62001n,
            date: 1_700_000_019n,
            fromId: 51n,
            message: "normal child chat context",
          },
          {
            id: 62002n,
            date: 1_700_000_020n,
            fromId: 42n,
            message: "reply thread metadata missing",
          },
        ],
      },
      dispatchReplyPayload: {
        text: "fallback reply",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ groupPolicy: "open", requireMention: false, replyThreads: true }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.resolveAgentRoute).toHaveBeenCalledWith(
        expect.objectContaining({
          peer: { kind: "group", id: "7200" },
        }),
      )
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          To: "inline:7200",
        }),
      )
      expect(harness.calls.finalizeInboundContext.mock.calls[0]?.[0]).not.toHaveProperty("MessageThreadId")
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 7200n,
          text: "fallback reply",
        }),
      )
    })

    await handle.stop()
  })

  it("handles message action callbacks by answering immediately and editing the target message", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.action.invoke",
          chatId: 7n,
          interactionId: 22n,
          messageId: 1001n,
          actorUserId: 42n,
          actionId: "pick",
          data: new Uint8Array([123, 34, 107, 34, 58, 49, 125]), // {"k":1}
        },
      ],
      chats: {
        "7": { kind: "direct", title: "Alice" },
      },
      historyByChat: {
        "7": [{ id: 1001n, date: 1_700_000_000n, fromId: 777n, message: "original" }],
      },
      dispatchReplyPayload: {
        text: "received",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ dmPolicy: "open" }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.answerMessageAction).toHaveBeenCalledTimes(1)
      expect(harness.calls.invokeRaw).toHaveBeenCalledWith(
        8,
        expect.objectContaining({
          oneofKind: "editMessage",
          editMessage: expect.objectContaining({
            messageId: 1001n,
            text: "received",
            parseMarkdown: true,
          }),
        }),
      )
      expect(harness.calls.sendMessage).not.toHaveBeenCalled()
      expect(harness.calls.answerMessageAction).toHaveBeenCalledWith(
        expect.objectContaining({
          interactionId: 22n,
        }),
      )
      expect(harness.calls.answerMessageAction.mock.calls[0]?.[0]).not.toHaveProperty("ui")
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          MessageActionInteractionId: "22",
          MessageActionId: "pick",
          MessageActionDataBase64: "eyJrIjoxfQ==",
          Body: 'Alice pressed "pick" on message #1001',
          BodyForAgent: 'Alice pressed "pick" on message #1001',
        }),
      )
      const ctx = harness.calls.finalizeInboundContext.mock.calls[0]?.[0]
      expect(ctx?.Body).not.toContain("data_base64")
      expect(ctx?.BodyForAgent).not.toContain("{")
    })

    expect(harness.calls.answerMessageAction.mock.invocationCallOrder[0]).toBeLessThan(
      harness.calls.dispatchReply.mock.invocationCallOrder[0] ?? Number.POSITIVE_INFINITY,
    )
    const editCall = harness.calls.invokeRaw.mock.calls.find(
      (call) =>
        call[0] === 8 &&
        call[1]?.oneofKind === "editMessage" &&
        call[1]?.editMessage?.messageId === 1001n,
    )
    const editOrder = editCall
      ? harness.calls.invokeRaw.mock.invocationCallOrder[harness.calls.invokeRaw.mock.calls.indexOf(editCall)]
      : Number.POSITIVE_INFINITY
    expect(harness.calls.answerMessageAction.mock.invocationCallOrder[0]).toBeLessThan(editOrder)

    await handle.stop()
  })

  it("answers message action callbacks with toast ui from callback payload", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.action.invoke",
          chatId: 7n,
          interactionId: 23n,
          messageId: 1002n,
          actorUserId: 42n,
          actionId: "save",
          data: new TextEncoder().encode(
            JSON.stringify({ value: "draft-1", callbackToast: "Saved" }),
          ),
        },
      ],
      chats: {
        "7": { kind: "direct", title: "Alice" },
      },
      historyByChat: {
        "7": [{ id: 1002n, date: 1_700_000_000n, fromId: 777n, message: "draft" }],
      },
      dispatchReplyPayload: {
        text: "saved",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ dmPolicy: "open" }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.answerMessageAction).toHaveBeenCalledTimes(1)
      expect(harness.calls.answerMessageAction).toHaveBeenCalledWith({
        interactionId: 23n,
        ui: {
          kind: {
            oneofKind: "toast",
            toast: { text: "Saved" },
          },
        },
      })
      expect(harness.calls.invokeRaw).toHaveBeenCalledWith(
        8,
        expect.objectContaining({
          oneofKind: "editMessage",
          editMessage: expect.objectContaining({
            messageId: 1002n,
            text: "saved",
            parseMarkdown: true,
          }),
        }),
      )
    })

    expect(harness.calls.answerMessageAction.mock.invocationCallOrder[0]).toBeLessThan(
      harness.calls.dispatchReply.mock.invocationCallOrder[0] ?? Number.POSITIVE_INFINITY,
    )

    await handle.stop()
  })

  it("renders command menu buttons for /subagents and skips agent dispatch", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 7n,
          message: {
            id: 1004n,
            date: 1_700_000_003n,
            fromId: 42n,
            message: "/subagents",
          },
        },
      ],
      chats: {
        "7": { kind: "direct", title: "Alice" },
      },
      dispatchReplyPayload: {
        text: "should not dispatch",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ dmPolicy: "open" }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).not.toHaveBeenCalled()
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 7n,
          text: expect.stringContaining("/subagents"),
          actions: expect.any(Object),
        }),
      )
    })

    const sent = harness.calls.sendMessage.mock.calls[0]?.[0]
    const firstButtonData = sent?.actions?.rows?.[0]?.actions?.[0]?.action?.callback?.data
    expect(firstButtonData).toBeInstanceOf(Uint8Array)
    expect(new TextDecoder().decode(firstButtonData)).toBe("icmd:/subagents list")

    await handle.stop()
  })

  it("edits paginated /commands callbacks in place", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.action.invoke",
          chatId: 7n,
          interactionId: 25n,
          messageId: 1008n,
          actorUserId: 42n,
          actionId: "commands-page",
          data: new TextEncoder().encode("commands_page_2:main"),
        },
      ],
      chats: {
        "7": { kind: "direct", title: "Alice" },
      },
      historyByChat: {
        "7": [{ id: 1008n, date: 1_700_000_000n, fromId: 777n, message: "Commands" }],
      },
      dispatchReplyPayload: {
        text: "should not dispatch",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ dmPolicy: "open" }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).not.toHaveBeenCalled()
      expect(harness.calls.invokeRaw).toHaveBeenCalledWith(
        8,
        expect.objectContaining({
          oneofKind: "editMessage",
          editMessage: expect.objectContaining({
            messageId: 1008n,
            text: expect.stringContaining("Commands (2/"),
            actions: expect.any(Object),
          }),
        }),
      )
    })

    const editPayload = harness.calls.invokeRaw.mock.calls.find(
      (call) => call[0] === 8 && call[1]?.oneofKind === "editMessage" && call[1]?.editMessage?.messageId === 1008n,
    )?.[1]
    const callbackData = (editPayload?.editMessage?.actions?.rows ?? [])
      .flatMap((row: any) => row.actions ?? [])
      .map((action: any) => action.action?.callback?.data)
      .filter((data: unknown): data is Uint8Array => data instanceof Uint8Array)
      .map((data) => new TextDecoder().decode(data))
    expect(callbackData).toContain("commands_page_1:main")

    await handle.stop()
  })

  it("renders reasoning mode choices in the command menu", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 7004n,
          message: {
            id: 10041n,
            date: 1_700_000_003n,
            fromId: 42n,
            message: "/reasoning",
          },
        },
      ],
      chats: {
        "7004": { kind: "direct", title: "Alice" },
      },
      dispatchReplyPayload: {
        text: "should not dispatch",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ dmPolicy: "open" }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).not.toHaveBeenCalled()
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 7004n,
          text: "Choose on, off, or stream for /reasoning.",
          actions: expect.any(Object),
        }),
      )
    })

    const sent = harness.calls.sendMessage.mock.calls[0]?.[0]
    const callbackData = (sent?.actions?.rows ?? [])
      .flatMap((row: any) => row.actions ?? [])
      .map((action: any) => action.action?.callback?.data)
      .filter((data: unknown): data is Uint8Array => data instanceof Uint8Array)
      .map((data) => new TextDecoder().decode(data))
    expect(callbackData).toEqual(["icmd:/reasoning on", "icmd:/reasoning off", "icmd:/reasoning stream"])

    await handle.stop()
  })

  it("shows the current thinking level in the native /think menu", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 7005n,
          message: {
            id: 10042n,
            date: 1_700_000_003n,
            fromId: 42n,
            message: "/think",
          },
        },
      ],
      chats: {
        "7005": { kind: "direct", title: "Alice" },
      },
      dispatchReplyPayload: {
        text: "should not dispatch",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {
        agents: {
          list: [{ id: "main", thinkingDefault: "high" }],
        },
      } as any,
      account: buildAccount({ dmPolicy: "open" }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).not.toHaveBeenCalled()
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 7005n,
          text: expect.stringContaining("Current thinking level: high."),
          actions: expect.any(Object),
        }),
      )
    })

    const sent = harness.calls.sendMessage.mock.calls[0]?.[0]
    const callbackData = (sent?.actions?.rows ?? [])
      .flatMap((row: any) => row.actions ?? [])
      .map((action: any) => action.action?.callback?.data)
      .filter((data: unknown): data is Uint8Array => data instanceof Uint8Array)
      .map((data) => new TextDecoder().decode(data))
    expect(callbackData.some((data) => data.startsWith("icmd:/think "))).toBe(true)

    await handle.stop()
  })

  it("preserves native command source for prefixed command menu callbacks", async () => {
    const shouldHandleTextCommands = vi.fn(({ cfg, commandSource }: any) => {
      if (commandSource === "native") return true
      return cfg.commands?.text !== false
    })
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.action.invoke",
          chatId: 7n,
          interactionId: 23n,
          messageId: 1005n,
          actorUserId: 42n,
          actionId: "toggle",
          data: new TextEncoder().encode("icmd:/verbose on"),
        },
      ],
      chats: {
        "7": { kind: "direct", title: "Alice" },
      },
      historyByChat: {
        "7": [{ id: 1005n, date: 1_700_000_000n, fromId: 777n, message: "Verbose?" }],
      },
      shouldHandleTextCommands,
      dispatchReplyPayload: {
        text: "verbose enabled",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {
        commands: {
          text: false,
        },
      } as any,
      account: buildAccount({ dmPolicy: "open" }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(shouldHandleTextCommands).toHaveBeenCalledWith(
        expect.objectContaining({
          surface: "inline",
          commandSource: "native",
        }),
      )
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          CommandBody: "/verbose on",
          CommandSource: "native",
          CommandTurn: expect.objectContaining({
            kind: "native",
            source: "native",
          }),
        }),
      )
      expect(harness.calls.invokeRaw).toHaveBeenCalledWith(
        8,
        expect.objectContaining({
          oneofKind: "editMessage",
        }),
      )
    })

    await handle.stop()
  })

  it("uses slash callback payload as CommandBody and edits the callback target", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.action.invoke",
          chatId: 7n,
          interactionId: 23n,
          messageId: 1005n,
          actorUserId: 42n,
          actionId: "toggle",
          data: new TextEncoder().encode("/verbose on"),
        },
      ],
      chats: {
        "7": { kind: "direct", title: "Alice" },
      },
      historyByChat: {
        "7": [{ id: 1005n, date: 1_700_000_000n, fromId: 777n, message: "Verbose?" }],
      },
      dispatchReplyPayload: {
        text: "verbose enabled",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ dmPolicy: "open" }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          CommandBody: "/verbose on",
        }),
      )
      expect(harness.calls.invokeRaw).toHaveBeenCalledWith(
        8,
        expect.objectContaining({
          oneofKind: "editMessage",
          editMessage: expect.objectContaining({
            messageId: 1005n,
            text: "verbose enabled",
            parseMarkdown: true,
          }),
        }),
      )
      expect(harness.calls.sendMessage).not.toHaveBeenCalled()
    })

    const editPayload = harness.calls.invokeRaw.mock.calls.find(
      (call) => call[0] === 8 && call[1]?.oneofKind === "editMessage" && call[1]?.editMessage?.messageId === 1005n,
    )?.[1]
    expect(editPayload?.editMessage?.actions).toEqual({ rows: [] })

    await handle.stop()
  })

  it("edits model list callback replies in place", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.action.invoke",
          chatId: 7n,
          interactionId: 24n,
          messageId: 1007n,
          actorUserId: 42n,
          actionId: "pick",
          data: new TextEncoder().encode("mdl_list_openai_2"),
        },
      ],
      chats: {
        "7": { kind: "direct", title: "Alice" },
      },
      historyByChat: {
        "7": [{ id: 1007n, date: 1_700_000_000n, fromId: 777n, message: "Pick a model" }],
      },
      dispatchReplyPayload: {
        text: "Models (openai) — 12 available",
        channelData: {
          inline: {
            buttons: [[{ text: "gpt-4.1", callback_data: "mdl_sel_openai/gpt-4.1" }]],
          },
        },
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ dmPolicy: "open" }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          CommandBody: "/models openai 2",
          Surface: "inline",
        }),
      )
      expect(harness.calls.invokeRaw).toHaveBeenCalledWith(
        8,
        expect.objectContaining({
          oneofKind: "editMessage",
          editMessage: expect.objectContaining({
            messageId: 1007n,
            text: "Models (openai) — 12 available",
            parseMarkdown: true,
            actions: expect.any(Object),
          }),
        }),
      )
    })

    expect(harness.calls.sendMessage).not.toHaveBeenCalled()

    const editPayload = harness.calls.invokeRaw.mock.calls.find(
      (call) => call[0] === 8 && call[1]?.oneofKind === "editMessage" && call[1]?.editMessage?.messageId === 1007n,
    )?.[1]
    const buttonData = editPayload?.editMessage?.actions?.rows?.[0]?.actions?.[0]?.action?.callback?.data
    expect(buttonData).toBeInstanceOf(Uint8Array)
    expect(new TextDecoder().decode(buttonData)).toBe("mdl_sel_openai/gpt-4.1")

    await handle.stop()
  })

  it("handles final model picker selection natively and clears buttons", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.action.invoke",
          chatId: 7n,
          interactionId: 24n,
          messageId: 1007n,
          actorUserId: 42n,
          actionId: "pick",
          data: new TextEncoder().encode("mdl_sel_openai/gpt-4.1"),
        },
      ],
      chats: {
        "7": { kind: "direct", title: "Alice" },
      },
      historyByChat: {
        "7": [{ id: 1007n, date: 1_700_000_000n, fromId: 777n, message: "Pick a model" }],
      },
    })

    const cfg = {
      agents: {
        defaults: {
          model: "openai/gpt-4.1",
        },
      },
    } as any

    const handle = await harness.monitorInlineProvider({
      cfg,
      account: buildAccount({ dmPolicy: "open" }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).not.toHaveBeenCalled()
      expect(harness.calls.finalizeInboundContext).not.toHaveBeenCalled()
      expect(harness.calls.invokeRaw).toHaveBeenCalledWith(
        8,
        expect.objectContaining({
          oneofKind: "editMessage",
          editMessage: expect.objectContaining({
            messageId: 1007n,
            text: "✅ Model reset to default\n\nThis model will be used for your next message.",
            parseMarkdown: true,
            actions: { rows: [] },
          }),
        }),
      )
    })

    expect(harness.calls.sendMessage).not.toHaveBeenCalled()
    expect(modelRuntimeMocks.patchSessionEntry).toHaveBeenCalledWith(
      expect.objectContaining({
        replaceEntry: true,
        preserveActivity: true,
        fallbackEntry: expect.objectContaining({
          sessionId: expect.any(String),
        }),
      }),
    )

    await handle.stop()
  })

  it("assigns unique inbound message ids to repeated callbacks on the same target message", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.action.invoke",
          chatId: 7n,
          interactionId: 24n,
          messageId: 1007n,
          actorUserId: 42n,
          actionId: "first",
          data: new TextEncoder().encode("/verbose on"),
        },
        {
          kind: "message.action.invoke",
          chatId: 7n,
          interactionId: 25n,
          messageId: 1007n,
          actorUserId: 42n,
          actionId: "second",
          data: new TextEncoder().encode("/verbose off"),
        },
      ],
      chats: {
        "7": { kind: "direct", title: "Alice" },
      },
      historyByChat: {
        "7": [{ id: 1007n, date: 1_700_000_000n, fromId: 777n, message: "Pick an option" }],
      },
      dispatchReplyPayload: {
        text: "updated",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ dmPolicy: "open" }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledTimes(2)
      expect(harness.calls.invokeRaw).toHaveBeenCalledWith(
        8,
        expect.objectContaining({
          oneofKind: "editMessage",
          editMessage: expect.objectContaining({
            messageId: 1007n,
            text: "updated",
          }),
        }),
      )
    })

    expect(harness.calls.finalizeInboundContext.mock.calls[0]?.[0]).toEqual(
      expect.objectContaining({
        MessageSid: "callback:1007:24",
        MessageActionInteractionId: "24",
        MessageActionId: "first",
      }),
    )
    expect(harness.calls.finalizeInboundContext.mock.calls[1]?.[0]).toEqual(
      expect.objectContaining({
        MessageSid: "callback:1007:25",
        MessageActionInteractionId: "25",
        MessageActionId: "second",
      }),
    )

    const callbackEdits = harness.calls.invokeRaw.mock.calls.filter(
      (call) => call[0] === 8 && call[1]?.oneofKind === "editMessage" && call[1]?.editMessage?.messageId === 1007n,
    )
    expect(callbackEdits).toHaveLength(2)

    await handle.stop()
  })

  it("answers callback interactions even when compat command menu short-circuits before dispatch", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.action.invoke",
          chatId: 7n,
          interactionId: 25n,
          messageId: 1008n,
          actorUserId: 42n,
          actionId: "subagents",
          data: new TextEncoder().encode("/subagents"),
        },
      ],
      chats: {
        "7": { kind: "direct", title: "Alice" },
      },
      historyByChat: {
        "7": [{ id: 1008n, date: 1_700_000_000n, fromId: 777n, message: "Choose a command" }],
      },
      dispatchReplyPayload: {
        text: "should not dispatch",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ dmPolicy: "open" }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).not.toHaveBeenCalled()
      expect(harness.calls.answerMessageAction).toHaveBeenCalledTimes(1)
      expect(harness.calls.invokeRaw).toHaveBeenCalledWith(
        8,
        expect.objectContaining({
          oneofKind: "editMessage",
          editMessage: expect.objectContaining({
            messageId: 1008n,
            text: expect.stringContaining("/subagents"),
            actions: expect.any(Object),
            parseMarkdown: true,
          }),
        }),
      )
      expect(harness.calls.sendMessage).not.toHaveBeenCalled()
      expect(harness.calls.answerMessageAction).toHaveBeenCalledWith(
        expect.objectContaining({
          interactionId: 25n,
        }),
      )
    })

    const compatEditCall = harness.calls.invokeRaw.mock.calls.find(
      (call) =>
        call[0] === 8 &&
        call[1]?.oneofKind === "editMessage" &&
        call[1]?.editMessage?.messageId === 1008n,
    )
    const compatEditOrder = compatEditCall
      ? harness.calls.invokeRaw.mock.invocationCallOrder[harness.calls.invokeRaw.mock.calls.indexOf(compatEditCall)]
      : Number.POSITIVE_INFINITY
    expect(harness.calls.answerMessageAction.mock.invocationCallOrder[0]).toBeLessThan(compatEditOrder)

    await handle.stop()
  })

  it("maps compatible button data to inline message actions on text replies", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 7n,
          message: {
            id: 1002n,
            date: 1_700_000_001n,
            fromId: 42n,
            message: "show options",
          },
        },
      ],
      chats: {
        "7": { kind: "direct", title: "Alice" },
      },
      dispatchReplyPayload: {
        text: "choose one",
        channelData: {
          telegram: {
            buttons: [[{ text: "Option A", callback_data: "cmd:a" }]],
          },
        },
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ dmPolicy: "open" }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 7n,
          text: "choose one",
          actions: expect.objectContaining({
            rows: [
              expect.objectContaining({
                actions: [
                  expect.objectContaining({
                    actionId: "btn_1_1",
                    text: "Option A",
                  }),
                ],
              }),
            ],
          }),
        }),
      )
    })

    const sent = harness.calls.sendMessage.mock.calls[0]?.[0]
    const buttonData = sent?.actions?.rows?.[0]?.actions?.[0]?.action?.callback?.data
    expect(buttonData).toBeInstanceOf(Uint8Array)
    expect(new TextDecoder().decode(buttonData)).toBe("cmd:a")

    await handle.stop()
  })

  it("maps Inline copy-text buttons on text replies", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 73n,
          message: {
            id: 10022n,
            date: 1_700_000_001n,
            fromId: 42n,
            message: "copy command",
          },
        },
      ],
      chats: {
        "73": { kind: "direct", title: "Alice" },
      },
      dispatchReplyPayload: {
        text: "copy this",
        channelData: {
          inline: {
            buttons: [[{ text: "Copy", copy_text: "bun run lint" }]],
          },
        },
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ dmPolicy: "open" }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      const action = harness.calls.sendMessage.mock.calls[0]?.[0]?.actions?.rows?.[0]?.actions?.[0]
      expect(action).toMatchObject({
        actionId: "btn_1_1",
        text: "Copy",
        action: {
          oneofKind: "copyText",
          copyText: {
            text: "bun run lint",
          },
        },
      })
    })

    await handle.stop()
  })

  it("maps shared interactive buttons to inline message actions on text replies", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 71n,
          message: {
            id: 10021n,
            date: 1_700_000_001n,
            fromId: 42n,
            message: "show options",
          },
        },
      ],
      chats: {
        "71": { kind: "direct", title: "Alice" },
      },
      dispatchReplyPayload: {
        text: "choose one",
        interactive: {
          blocks: [
            {
              type: "buttons",
              buttons: [{ label: "Approve", value: "approve" }],
            },
          ],
        },
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ dmPolicy: "open" }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 71n,
          text: "choose one",
          actions: expect.any(Object),
        }),
      )
    })

    const sent = harness.calls.sendMessage.mock.calls[0]?.[0]
    const button = sent?.actions?.rows?.[0]?.actions?.[0]
    expect(button?.text).toBe("Approve")
    expect(new TextDecoder().decode(button?.action?.callback?.data)).toBe("approve")

    await handle.stop()
  })

  it("uses shared interactive labels as fallback text when reply text is omitted", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 710n,
          message: {
            id: 100211n,
            date: 1_700_000_001n,
            fromId: 42n,
            message: "show options",
          },
        },
      ],
      chats: {
        "710": { kind: "direct", title: "Alice" },
      },
      dispatchReplyPayload: {
        interactive: {
          blocks: [
            {
              type: "buttons",
              buttons: [{ label: "Approve", value: "approve" }],
            },
          ],
        },
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ dmPolicy: "open" }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 710n,
          text: "- Approve",
          actions: expect.any(Object),
        }),
      )
    })

    const sent = harness.calls.sendMessage.mock.calls[0]?.[0]
    const button = sent?.actions?.rows?.[0]?.actions?.[0]
    expect(button?.text).toBe("Approve")
    expect(new TextDecoder().decode(button?.action?.callback?.data)).toBe("approve")

    await handle.stop()
  })

  it("keeps reply-pipeline buttons inside Inline server action limits", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 72n,
          message: {
            id: 10022n,
            date: 1_700_000_001n,
            fromId: 42n,
            message: "show options",
          },
        },
      ],
      chats: {
        "72": { kind: "direct", title: "Alice" },
      },
      dispatchReplyPayload: {
        text: "choose one",
        interactive: {
          blocks: [
            {
              type: "buttons",
              buttons: [
                { label: "x".repeat(80), value: "approve" },
                {
                  label: "Oversized",
                  value: "y".repeat(INLINE_ACTION_CALLBACK_DATA_MAX_BYTES + 1),
                },
              ],
            },
          ],
        },
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ dmPolicy: "open" }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 72n,
          text: "choose one",
          actions: expect.any(Object),
        }),
      )
    })

    const sent = harness.calls.sendMessage.mock.calls[0]?.[0]
    const row = sent?.actions?.rows?.[0]?.actions
    expect(row).toHaveLength(1)
    expect(row?.[0]?.text).toHaveLength(INLINE_ACTION_LABEL_MAX_LENGTH)
    expect(new TextDecoder().decode(row?.[0]?.action?.callback?.data)).toBe("approve")

    await handle.stop()
  })

  it("preserves compatible model callbacks on rendered buttons", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 7n,
          message: {
            id: 1006n,
            date: 1_700_000_004n,
            fromId: 42n,
            message: "show model picker",
          },
        },
      ],
      chats: {
        "7": { kind: "direct", title: "Alice" },
      },
      dispatchReplyPayload: {
        text: "pick model",
        channelData: {
          telegram: {
            buttons: [
              [
                { text: "Browse", callback_data: "mdl_prov" },
                { text: "OpenAI Page 2", callback_data: "mdl_list_openai_2" },
              ],
              [{ text: "openai/gpt-4.1", callback_data: "mdl_sel_openai/gpt-4.1" }],
            ],
          },
        },
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ dmPolicy: "open" }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 7n,
          text: "pick model",
          actions: expect.any(Object),
        }),
      )
    })

    const sent = harness.calls.sendMessage.mock.calls[0]?.[0]
    const row1Btn1 = sent?.actions?.rows?.[0]?.actions?.[0]?.action?.callback?.data
    const row1Btn2 = sent?.actions?.rows?.[0]?.actions?.[1]?.action?.callback?.data
    const row2Btn1 = sent?.actions?.rows?.[1]?.actions?.[0]?.action?.callback?.data

    expect(new TextDecoder().decode(row1Btn1)).toBe("mdl_prov")
    expect(new TextDecoder().decode(row1Btn2)).toBe("mdl_list_openai_2")
    expect(new TextDecoder().decode(row2Btn1)).toBe("mdl_sel_openai/gpt-4.1")

    await handle.stop()
  })

  it("attaches compatible buttons only to the first media send", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 7n,
          message: {
            id: 1003n,
            date: 1_700_000_002n,
            fromId: 42n,
            message: "send media",
          },
        },
      ],
      chats: {
        "7": { kind: "direct", title: "Alice" },
      },
      dispatchReplyPayload: {
        text: "media caption",
        mediaUrls: ["https://example.com/a.jpg", "https://example.com/b.jpg"],
        channelData: {
          telegram: {
            buttons: [[{ text: "Open", callback_data: "cmd:open" }]],
          },
        },
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ dmPolicy: "open" }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.sendMessage).toHaveBeenCalledTimes(2)
      expect(harness.calls.sendMessage).toHaveBeenNthCalledWith(
        1,
        expect.objectContaining({
          chatId: 7n,
          actions: expect.any(Object),
        }),
      )
      expect(harness.calls.sendMessage).toHaveBeenNthCalledWith(
        2,
        expect.objectContaining({
          chatId: 7n,
        }),
      )
    })

    const firstSend = harness.calls.sendMessage.mock.calls[0]?.[0]
    const secondSend = harness.calls.sendMessage.mock.calls[1]?.[0]
    expect(firstSend?.actions?.rows?.[0]?.actions?.[0]?.text).toBe("Open")
    expect(secondSend?.actions).toBeUndefined()

    await handle.stop()
  })

  it("uploads media in reply payloads and sends as Inline attachments", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 7n,
          message: {
            id: 1201n,
            date: 1_700_000_000n,
            fromId: 42n,
            message: "send image",
          },
        },
      ],
      chats: {
        "7": { kind: "direct", title: "Alice" },
      },
      dispatchReplyPayload: {
        text: "here it is",
        mediaUrl: "https://example.com/image.png",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ dmPolicy: "open" }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.uploadFile).toHaveBeenCalledWith(
        expect.objectContaining({
          type: "photo",
        }),
      )
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 7n,
          text: "here it is",
          media: {
            kind: "photo",
            photoId: 200n,
          },
          parseMarkdown: true,
        }),
      )
    })

    await handle.stop()
  })

  it("hydrates sender username and rewrites @id mentions to @username", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 17n,
          message: {
            id: 1100n,
            date: 1_700_000_100n,
            fromId: 42n,
            message: "hello",
          },
        },
      ],
      chats: {
        "17": { kind: "direct", title: "Alice" },
      },
      participants: {
        "17": [{ id: 42n, username: "alice", firstName: "Alice" }],
      },
      dispatchReplyPayload: {
        text: "cc @42 thanks",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ dmPolicy: "open" }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          SenderId: "42",
          SenderName: "Alice",
          SenderUsername: "alice",
          Body: "hello",
          BodyForAgent: "hello",
        }),
      )
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 17n,
          text: "cc @alice thanks",
        }),
      )
    })

    await handle.stop()
  })

  it("falls back to cached directory users for direct sender names", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 17n,
          message: {
            id: 1100n,
            date: 1_700_000_100n,
            fromId: 42n,
            message: "hello",
          },
        },
      ],
      chats: {
        "17": { kind: "direct", title: "user:42", peerUserId: 42n },
      },
      participants: {
        "17": [],
      },
      directoryUsers: [{ id: 42n, username: "alice", firstName: "Alice" }],
      dispatchReplyPayload: {
        text: "cc @42 thanks",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ dmPolicy: "open" }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          ConversationLabel: "Alice (@alice) id:42",
          SenderId: "42",
          SenderName: "Alice",
          SenderUsername: "alice",
          Body: "hello",
          BodyForAgent: "hello",
        }),
      )
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 17n,
          text: "cc @alice thanks",
          parseMarkdown: true,
        }),
      )
      expect(harness.calls.invokeRaw).toHaveBeenCalledWith(17, {
        oneofKind: "getChats",
        getChats: {},
      })
    })

    await handle.stop()
  })

  it("routes group messages by chat id and does not set DM last-route metadata", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 2002n,
            date: 1_700_000_001n,
            fromId: 51n,
            message: "hello from group",
            mentioned: true,
          },
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      dispatchReplyPayload: {
        text: "group reply",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        groupPolicy: "open",
        requireMention: true,
        parseMarkdown: false,
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.resolveAgentRoute).toHaveBeenCalledWith(
        expect.objectContaining({
          peer: { kind: "group", id: "88" },
        }),
      )
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          ChatType: "group",
          InboundEventKind: "user_request",
          GroupSubject: "Project Room",
          From: "inline:chat:88",
          To: "inline:88",
          SenderId: "51",
          Body: "hello from group",
          BodyForAgent: "hello from group",
          BodyForCommands: "hello from group",
        }),
      )
      const recordArgs = harness.calls.recordInboundSession.mock.calls[0]?.[0]
      expect(recordArgs?.updateLastRoute).toBeUndefined()
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 88n,
          text: "group reply",
          parseMarkdown: false,
        }),
      )
    })

    await handle.stop()
  })

  it("marks unmentioned group messages as room events when configured", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 2002n,
            date: 1_700_000_002n,
            fromId: 51n,
            message: "ambient group update",
            mentioned: false,
          },
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      dispatchReplyPayload: {
        text: "noted",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {
        messages: {
          groupChat: {
            unmentionedInbound: "room_event",
            mentionPatterns: [],
          },
        },
      } as any,
      account: buildAccount({
        groupPolicy: "open",
        requireMention: false,
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalledTimes(1)
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          ChatType: "group",
          InboundEventKind: "room_event",
          WasMentioned: false,
          Body: "ambient group update",
          BodyForAgent: "ambient group update",
        }),
      )
    })

    await handle.stop()
  })

  it("runs pairing flow for unknown DM senders and skips normal dispatch", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 999n,
          message: {
            id: 3003n,
            date: 1_700_000_002n,
            fromId: 404n,
            message: "hi",
          },
        },
      ],
      chats: {
        "999": { kind: "direct", title: "Unknown" },
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        dmPolicy: "pairing",
        allowFrom: [],
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.upsertPairingRequest).toHaveBeenCalledWith(
        expect.objectContaining({
          channel: "inline",
          id: "404",
          pairingAdapter: expect.objectContaining({
            idLabel: "inlineUserId",
          }),
        }),
      )
      expect(harness.calls.buildPairingReply).toHaveBeenCalled()
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 999n,
          text: "PAIRING_REPLY",
        }),
      )
      expect(harness.calls.dispatchReply).not.toHaveBeenCalled()
      expect(harness.calls.recordInboundSession).not.toHaveBeenCalled()
    })

    await handle.stop()
  })

  it("accepts allowFrom entries with user target prefixes", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 123n,
          message: {
            id: 4444n,
            date: 1_700_000_003n,
            fromId: 42n,
            message: "allowed dm",
          },
        },
      ],
      chats: {
        "123": { kind: "direct", title: "Allowed User" },
      },
      dispatchReplyPayload: {
        text: "ok",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        dmPolicy: "allowlist",
        allowFrom: ["inline:user:42"],
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.upsertPairingRequest).not.toHaveBeenCalled()
      expect(harness.calls.recordInboundSession).toHaveBeenCalled()
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 123n,
          text: "ok",
        }),
      )
    })

    await handle.stop()
  })

  it("allows direct messages from sender access groups in allowFrom", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 123n,
          message: {
            id: 4445n,
            date: 1_700_000_003n,
            fromId: 42n,
            message: "allowed dm",
          },
        },
      ],
      chats: {
        "123": { kind: "direct", title: "Allowed User" },
      },
      dispatchReplyPayload: {
        text: "ok",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {
        accessGroups: {
          operators: {
            type: "message.senders",
            members: { inline: ["42"] },
          },
        },
      } as any,
      account: buildAccount({
        dmPolicy: "allowlist",
        allowFrom: ["accessGroup:operators"],
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.upsertPairingRequest).not.toHaveBeenCalled()
      expect(harness.calls.recordInboundSession).toHaveBeenCalled()
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 123n,
          text: "ok",
        }),
      )
    })

    await handle.stop()
  })

  it("maps account.blockStreaming=false to disableBlockStreaming=true", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 77n,
          message: {
            id: 5555n,
            date: 1_700_000_004n,
            fromId: 42n,
            message: "dm",
          },
        },
      ],
      chats: {
        "77": { kind: "direct", title: "Alice" },
      },
      dispatchReplyPayload: {
        text: "ok",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        dmPolicy: "open",
        blockStreaming: false,
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalled()
      const args = harness.calls.dispatchReply.mock.calls[0]?.[0]
      expect(args?.replyOptions?.disableBlockStreaming).toBe(true)
    })

    await handle.stop()
  })

  it("maps unified streaming.mode=block to Inline block streaming", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 771n,
          message: {
            id: 5556n,
            date: 1_700_000_004n,
            fromId: 42n,
            message: "dm",
          },
        },
      ],
      chats: {
        "771": { kind: "direct", title: "Alice" },
      },
      partialReplies: [{ text: "partial" }],
      dispatchReplyPayload: {
        text: "ok",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        dmPolicy: "open",
        streaming: { mode: "block" },
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalled()
      const args = harness.calls.dispatchReply.mock.calls[0]?.[0]
      expect(args?.replyOptions?.onPartialReply).toBeUndefined()
      expect(args?.replyOptions?.disableBlockStreaming).toBe(false)
    })

    await handle.stop()
  })

  it("maps unified streaming.mode=progress to a separate Inline progress placeholder path", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 772n,
          message: {
            id: 5557n,
            date: 1_700_000_004n,
            fromId: 42n,
            message: "dm",
          },
        },
      ],
      chats: {
        "772": { kind: "direct", title: "Alice" },
      },
      partialReplies: [{ text: "first paragraph\n\n" }],
      dispatchReplyPayload: {
        text: "first paragraph\n\nfinal",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        dmPolicy: "open",
        streaming: { mode: "progress" },
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      const args = harness.calls.dispatchReply.mock.calls[0]?.[0]
      expect(args?.replyOptions?.onPartialReply).toBeUndefined()
      expect(typeof args?.replyOptions?.onToolStart).toBe("function")
      expect(args?.replyOptions?.suppressDefaultToolProgressMessages).toBe(true)
      expect(args?.replyOptions?.disableBlockStreaming).toBe(true)
    })

    await handle.stop()
  })

  it("sends, edits, and deletes a silent progress placeholder before the final reply", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 773n,
          message: {
            id: 5558n,
            date: 1_700_000_004n,
            fromId: 42n,
            message: "dm",
          },
        },
      ],
      chats: {
        "773": { kind: "direct", title: "Alice" },
      },
      partialReplies: [{ text: "draft before tool\n\n" }],
      toolStartBeforePayloadIndexes: [0],
      itemEventBeforePayloadIndexes: [0],
      dispatchReplyPayload: {
        text: "visible after tool",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        dmPolicy: "open",
        streaming: { mode: "progress" },
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      const args = harness.calls.dispatchReply.mock.calls[0]?.[0]
      expect(typeof args?.replyOptions?.onToolStart).toBe("function")
      expect(typeof args?.replyOptions?.onItemEvent).toBe("function")
      expect(harness.calls.sendMessage).toHaveBeenNthCalledWith(
        1,
        expect.objectContaining({
          chatId: 773n,
          sendMode: "silent",
          text: expect.any(String),
        }),
      )
      expect(harness.calls.invokeRaw).toHaveBeenCalledWith(
        8,
        expect.objectContaining({
          oneofKind: "editMessage",
          editMessage: expect.objectContaining({
            messageId: 1n,
            text: expect.stringContaining("listed files"),
          }),
        }),
      )
      expect(harness.calls.invokeRaw).toHaveBeenCalledWith(
        4,
        expect.objectContaining({
          oneofKind: "deleteMessages",
          deleteMessages: expect.objectContaining({
            messageIds: [1n],
          }),
        }),
      )
      expect(harness.calls.sendMessage).toHaveBeenNthCalledWith(
        2,
        expect.objectContaining({
          chatId: 773n,
          text: "visible after tool",
        }),
      )
    })

    const deleteCallIndex = harness.calls.invokeRaw.mock.calls.findIndex(
      (call) => call[0] === 4 && call[1]?.oneofKind === "deleteMessages",
    )
    expect(deleteCallIndex).toBeGreaterThanOrEqual(0)
    expect(harness.calls.invokeRaw.mock.invocationCallOrder[deleteCallIndex]).toBeLessThan(
      harness.calls.sendMessage.mock.invocationCallOrder[1] ?? Number.POSITIVE_INFINITY,
    )

    await handle.stop()
  })

  it("keeps edit-based streaming off by default", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 66n,
          message: {
            id: 5600n,
            date: 1_700_000_006n,
            fromId: 42n,
            message: "dm",
          },
        },
      ],
      chats: {
        "66": { kind: "direct", title: "Alice" },
      },
      partialReplies: [{ text: "first paragraph\n\n" }],
      dispatchReplyPayload: {
        text: "first paragraph\n\nsecond paragraph",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ dmPolicy: "open" }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      const args = harness.calls.dispatchReply.mock.calls[0]?.[0]
      expect(args?.replyOptions?.onPartialReply).toBeUndefined()
      expect(harness.calls.invokeRaw).not.toHaveBeenCalledWith(
        8,
        expect.objectContaining({ oneofKind: "editMessage" }),
      )
      expect(harness.calls.sendMessage).toHaveBeenCalledTimes(1)
    })

    await handle.stop()
  })

  it("lets explicit streaming=false override legacy edit-streaming config", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 661n,
          message: {
            id: 5601n,
            date: 1_700_000_006n,
            fromId: 42n,
            message: "dm",
          },
        },
      ],
      chats: {
        "661": { kind: "direct", title: "Alice" },
      },
      partialReplies: [{ text: "first paragraph\n\n" }],
      dispatchReplyPayload: {
        text: "final only",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        dmPolicy: "open",
        streaming: false,
        streamViaEditMessage: true,
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      const args = harness.calls.dispatchReply.mock.calls[0]?.[0]
      expect(args?.replyOptions?.onPartialReply).toBeUndefined()
      expect(args?.replyOptions?.disableBlockStreaming).toBe(true)
      expect(harness.calls.invokeRaw).not.toHaveBeenCalledWith(
        8,
        expect.objectContaining({ oneofKind: "editMessage" }),
      )
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 661n,
          text: "final only",
        }),
      )
    })

    await handle.stop()
  })

  it("streams by paragraph through send plus editMessage when enabled", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 67n,
          message: {
            id: 5700n,
            date: 1_700_000_007n,
            fromId: 42n,
            message: "dm",
          },
        },
      ],
      chats: {
        "67": { kind: "direct", title: "Alice" },
      },
      partialReplies: [
        { text: "first **paragraph**\n\n" },
        { text: "second paragraph" },
      ],
      dispatchReplyPayload: {
        text: "first **paragraph**\n\nsecond paragraph",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ dmPolicy: "open", streamViaEditMessage: true }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      const args = harness.calls.dispatchReply.mock.calls[0]?.[0]
      expect(typeof args?.replyOptions?.onPartialReply).toBe("function")
      expect(args?.replyOptions?.disableBlockStreaming).toBe(true)
      expect(harness.calls.sendMessage).toHaveBeenCalledTimes(1)
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 67n,
          text: "first **paragraph**",
          parseMarkdown: true,
        }),
      )
      expect(harness.calls.invokeRaw).toHaveBeenCalledWith(
        8,
        expect.objectContaining({
          oneofKind: "editMessage",
          editMessage: expect.objectContaining({
            messageId: 1n,
            text: "first **paragraph**\n\nsecond paragraph",
            parseMarkdown: true,
          }),
        }),
      )
    })

    await handle.stop()
  })

  it("rotates streamed edit messages on assistant message boundaries", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 670n,
          message: {
            id: 5701n,
            date: 1_700_000_010n,
            fromId: 42n,
            message: "dm",
          },
        },
      ],
      chats: {
        "670": { kind: "direct", title: "Alice" },
      },
      partialReplies: [{ text: "first update\n\n" }],
      dispatchReplyPayloads: [{ text: "first update" }, { text: "second update" }],
      assistantMessageStartBeforePayloadIndexes: [1],
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ dmPolicy: "open", streamViaEditMessage: true }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      const args = harness.calls.dispatchReply.mock.calls[0]?.[0]
      expect(typeof args?.replyOptions?.onAssistantMessageStart).toBe("function")
      expect(harness.calls.sendMessage).toHaveBeenCalledTimes(2)
      expect(harness.calls.sendMessage).toHaveBeenNthCalledWith(
        1,
        expect.objectContaining({
          chatId: 670n,
          text: "first update",
        }),
      )
      expect(harness.calls.sendMessage).toHaveBeenNthCalledWith(
        2,
        expect.objectContaining({
          chatId: 670n,
          text: "second update",
        }),
      )
    })

    await handle.stop()
  })

  it("rotates streamed edit messages on tool-start boundaries", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 671n,
          message: {
            id: 5702n,
            date: 1_700_000_011n,
            fromId: 42n,
            message: "dm",
          },
        },
      ],
      chats: {
        "671": { kind: "direct", title: "Alice" },
      },
      partialReplies: [{ text: "first update\n\n" }],
      dispatchReplyPayloads: [{ text: "first update" }, { text: "second update" }],
      toolStartBeforePayloadIndexes: [1],
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ dmPolicy: "open", streamViaEditMessage: true }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      const args = harness.calls.dispatchReply.mock.calls[0]?.[0]
      expect(typeof args?.replyOptions?.onToolStart).toBe("function")
      expect(harness.calls.sendMessage).toHaveBeenCalledTimes(2)
      expect(harness.calls.sendMessage).toHaveBeenNthCalledWith(
        1,
        expect.objectContaining({
          chatId: 671n,
          text: "first update",
        }),
      )
      expect(harness.calls.sendMessage).toHaveBeenNthCalledWith(
        2,
        expect.objectContaining({
          chatId: 671n,
          text: "second update",
        }),
      )
    })

    await handle.stop()
  })

  it("splits repeated final payloads into separate messages when stream boundaries are absent", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 672n,
          message: {
            id: 5703n,
            date: 1_700_000_012n,
            fromId: 42n,
            message: "dm",
          },
        },
      ],
      chats: {
        "672": { kind: "direct", title: "Alice" },
      },
      partialReplies: [{ text: "first update\n\n" }],
      dispatchReplyPayloads: [{ text: "first update" }, { text: "second update" }],
      payloadInfoKinds: ["final", "final"],
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ dmPolicy: "open", streamViaEditMessage: true }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.sendMessage).toHaveBeenCalledTimes(2)
      expect(harness.calls.sendMessage).toHaveBeenNthCalledWith(
        1,
        expect.objectContaining({
          chatId: 672n,
          text: "first update",
        }),
      )
      expect(harness.calls.sendMessage).toHaveBeenNthCalledWith(
        2,
        expect.objectContaining({
          chatId: 672n,
          text: "second update",
        }),
      )
    })

    await handle.stop()
  })

  it("sends a fallback reply when dispatch skips non-silently and nothing is delivered", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 673n,
          message: {
            id: 5704n,
            date: 1_700_000_013n,
            fromId: 42n,
            message: "dm",
          },
        },
      ],
      chats: {
        "673": { kind: "direct", title: "Alice" },
      },
      skipInfos: [{ reason: "policy" }],
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ dmPolicy: "open" }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.sendMessage).toHaveBeenCalledTimes(1)
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 673n,
          text: "No response generated. Please try again.",
        }),
      )
    })

    await handle.stop()
  })

  it("suppresses reasoning-only final payloads without fallback chat text", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 674n,
          message: {
            id: 5705n,
            date: 1_700_000_014n,
            fromId: 42n,
            message: "dm",
          },
        },
      ],
      chats: {
        "674": { kind: "direct", title: "Alice" },
      },
      dispatchReplyPayloads: [
        { text: "Reasoning:\nprivate chain of thought" },
        { text: "<think>private chain of thought</think>" },
      ],
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ dmPolicy: "open" }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalled()
    })
    await waitForMockPromise(harness.calls.dispatchReply)

    expect(harness.calls.sendMessage).not.toHaveBeenCalled()

    await handle.stop()
  })

  it("suppresses copied OpenClaw runtime heartbeat context", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 6741n,
          message: {
            id: 57051n,
            date: 1_700_000_014n,
            fromId: 42n,
            message: "dm",
          },
        },
      ],
      chats: {
        "6741": { kind: "direct", title: "Alice" },
      },
      dispatchReplyPayload: {
        text: [
          "OpenClaw runtime context for the immediately preceding user message.",
          "This context is runtime-generated, not user-authored. Keep internal details private.",
          "",
          "Read HEARTBEAT.md if it exists (workspace context). Follow it strictly. Do not infer or repeat old tasks from prior chats. If nothing needs attention, reply HEARTBEAT_OK.",
          "When reading HEARTBEAT.md, use workspace file /workspace/support/HEARTBEAT.md (exact case). Do not read docs/heartbeat.md.",
          "Current time: Sunday, May 10th, 2026 - 5:39 AM (America/Vancouver) / 2026-05-10 12:39 UTC",
        ].join("\n"),
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ dmPolicy: "open" }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalled()
    })
    await waitForMockPromise(harness.calls.dispatchReply)

    expect(harness.calls.sendMessage).not.toHaveBeenCalled()

    await handle.stop()
  })

  it("strips copied OpenClaw runtime context before sending visible text", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 6742n,
          message: {
            id: 57052n,
            date: 1_700_000_014n,
            fromId: 42n,
            message: "dm",
          },
        },
      ],
      chats: {
        "6742": { kind: "direct", title: "Alice" },
      },
      dispatchReplyPayload: {
        text: [
          "OpenClaw runtime context for the immediately preceding user message.",
          "This context is runtime-generated, not user-authored. Keep internal details private.",
          "",
          "<<<BEGIN_OPENCLAW_INTERNAL_CONTEXT>>>",
          "secret runtime context",
          "<<<END_OPENCLAW_INTERNAL_CONTEXT>>>",
          "",
          "Visible reply.",
        ].join("\n"),
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ dmPolicy: "open" }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 6742n,
          text: "Visible reply.",
        }),
      )
    })

    await handle.stop()
  })

  it("suppresses heartbeat ack payloads without fallback chat text", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 6743n,
          message: {
            id: 57053n,
            date: 1_700_000_014n,
            fromId: 42n,
            message: "dm",
          },
        },
      ],
      chats: {
        "6743": { kind: "direct", title: "Alice" },
      },
      dispatchReplyPayload: {
        text: "HEARTBEAT_OK",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ dmPolicy: "open" }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalled()
    })
    await waitForMockPromise(harness.calls.dispatchReply)

    expect(harness.calls.sendMessage).not.toHaveBeenCalled()

    await handle.stop()
  })

  it("strips reasoning tags from mixed final payloads before sending chat text", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 675n,
          message: {
            id: 5706n,
            date: 1_700_000_015n,
            fromId: 42n,
            message: "dm",
          },
        },
      ],
      chats: {
        "675": { kind: "direct", title: "Alice" },
      },
      dispatchReplyPayload: {
        text: "<think>private chain of thought</think>\n\nVisible answer",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ dmPolicy: "open" }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 675n,
          text: "Visible answer",
        }),
      )
    })

    await handle.stop()
  })

  it("preserves literal reasoning tags inside code blocks", async () => {
    const text = "Use `<think>example</think>` literally."
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 6751n,
          message: {
            id: 57061n,
            date: 1_700_000_018n,
            fromId: 42n,
            message: "dm",
          },
        },
      ],
      chats: {
        "6751": { kind: "direct", title: "Alice" },
      },
      dispatchReplyPayload: { text },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ dmPolicy: "open" }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 6751n,
          text,
        }),
      )
    })

    await handle.stop()
  })

  it("sends media without suppressed reasoning captions", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 6752n,
          message: {
            id: 57062n,
            date: 1_700_000_019n,
            fromId: 42n,
            message: "dm",
          },
        },
      ],
      chats: {
        "6752": { kind: "direct", title: "Alice" },
      },
      dispatchReplyPayload: {
        text: "<think>private chain of thought</think>",
        mediaUrl: "https://example.com/image.png",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ dmPolicy: "open" }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 6752n,
          media: {
            kind: "photo",
            photoId: 200n,
          },
        }),
      )
    })

    expect(harness.calls.sendMessage.mock.calls[0]?.[0]?.text).toBeUndefined()

    await handle.stop()
  })

  it("does not send partial reasoning tag prefixes during edit streaming", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 6753n,
          message: {
            id: 57063n,
            date: 1_700_000_020n,
            fromId: 42n,
            message: "dm",
          },
        },
      ],
      chats: {
        "6753": { kind: "direct", title: "Alice" },
      },
      partialReplies: [
        { text: "<thi\n\n" },
        { text: "<think>private chain of thought</think>\n\nVisible answer\n\n" },
      ],
      dispatchReplyPayload: {
        text: "<think>private chain of thought</think>\n\nVisible answer",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ dmPolicy: "open", streamViaEditMessage: true }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 6753n,
          text: "Visible answer",
        }),
      )
    })

    const sentTexts = harness.calls.sendMessage.mock.calls
      .map((call) => call[0]?.text)
      .filter((text): text is string => typeof text === "string")
    expect(sentTexts).not.toContain("<thi")

    await handle.stop()
  })

  it("does not expose reasoning streams in mentioned group edit streaming", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 676n,
          message: {
            id: 5707n,
            date: 1_700_000_016n,
            fromId: 42n,
            message: "@Boba check payroll",
            mentioned: true,
          },
        },
      ],
      chats: {
        "676": { kind: "group", title: "Ops" },
      },
      reasoningReplies: [{ text: "Reasoning:\nprivate chain of thought" }],
      dispatchReplyPayload: {
        text: "Visible answer",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        groupPolicy: "open",
        requireMention: true,
        streamViaEditMessage: true,
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      const args = harness.calls.dispatchReply.mock.calls[0]?.[0]
      expect(args?.replyOptions?.onReasoningStream).toBeUndefined()
      expect(args?.replyOptions?.onReasoningEnd).toBeUndefined()
      expect(harness.calls.sendMessage).toHaveBeenCalledTimes(1)
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 676n,
          text: "Visible answer",
        }),
      )
    })

    await handle.stop()
  })

  it("suppresses payloads explicitly marked as reasoning", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 677n,
          message: {
            id: 5708n,
            date: 1_700_000_017n,
            fromId: 42n,
            message: "dm",
          },
        },
      ],
      chats: {
        "677": { kind: "direct", title: "Alice" },
      },
      dispatchReplyPayload: {
        text: "private chain of thought",
        isReasoning: true,
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ dmPolicy: "open" }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalled()
    })
    await waitForMockPromise(harness.calls.dispatchReply)

    expect(harness.calls.sendMessage).not.toHaveBeenCalled()

    await handle.stop()
  })

  it("serializes concurrent partial snapshots so the first paragraph sends only once", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 68n,
          message: {
            id: 5800n,
            date: 1_700_000_008n,
            fromId: 42n,
            message: "dm",
          },
        },
      ],
      chats: {
        "68": { kind: "direct", title: "Alice" },
      },
      partialReplies: [
        { text: "first paragraph\n\n" },
        { text: "first paragraph\n\nsecond" },
        { text: "first paragraph\n\nsecond paragraph" },
      ],
      partialRepliesConcurrent: true,
      sendMessageDelayMs: 25,
      dispatchReplyPayload: {
        text: "first paragraph\n\nsecond paragraph",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ dmPolicy: "open", streamViaEditMessage: true }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.sendMessage).toHaveBeenCalledTimes(1)
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 68n,
          text: "first paragraph",
        }),
      )
      expect(harness.calls.invokeRaw).toHaveBeenCalledWith(
        8,
        expect.objectContaining({
          oneofKind: "editMessage",
          editMessage: expect.objectContaining({
            text: "first paragraph\n\nsecond paragraph",
            parseMarkdown: true,
          }),
        }),
      )
    })

    await handle.stop()
  })

  it("reconstructs multi-chunk final text into the streamed message instead of overwriting with the last chunk", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 69n,
          message: {
            id: 5900n,
            date: 1_700_000_009n,
            fromId: 42n,
            message: "dm",
          },
        },
      ],
      chats: {
        "69": { kind: "direct", title: "Alice" },
      },
      partialReplies: [{ text: "first paragraph\n\n" }],
      dispatchReplyPayloads: [
        { text: "first paragraph\n\nsecond " },
        { text: "paragraph\n\nthird paragraph" },
      ],
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ dmPolicy: "open", streamViaEditMessage: true }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.sendMessage).toHaveBeenCalledTimes(1)
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 69n,
          text: "first paragraph",
        }),
      )
      const editCalls = harness.calls.invokeRaw.mock.calls.filter((call) => call[0] === 8)
      expect(editCalls.length).toBeGreaterThanOrEqual(2)
      expect(editCalls.at(-1)?.[1]).toEqual(
        expect.objectContaining({
          oneofKind: "editMessage",
          editMessage: expect.objectContaining({
            text: "first paragraph\n\nsecond paragraph\n\nthird paragraph",
            parseMarkdown: true,
          }),
        }),
      )
    })

    await handle.stop()
  })

  it("honors channels.inline.groups.*.requireMention overrides", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 6001n,
            date: 1_700_000_005n,
            fromId: 51n,
            message: "no mention but allowed",
            mentioned: false,
          },
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      dispatchReplyPayload: {
        text: "group reply",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {
        channels: {
          inline: {
            groups: {
              "88": {
                requireMention: false,
              },
            },
          },
        },
      } as any,
      account: buildAccount({
        groupPolicy: "open",
        requireMention: true,
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalled()
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 88n,
          text: "group reply",
        }),
      )
    })

    await handle.stop()
  })

  it("routes allowlisted Inline groups without requiring groupAllowFrom senders", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 60011n,
            date: 1_700_000_011n,
            fromId: 51n,
            message: "allowed by group route",
            mentioned: false,
          },
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      dispatchReplyPayload: {
        text: "group allowlist reply",
      },
    })

    const cfg = {
      channels: {
        inline: {
          groups: {
            "chat:88": {
              requireMention: false,
            },
          },
        },
      },
    } as any

    const handle = await harness.monitorInlineProvider({
      cfg,
      account: buildAccount({
        groupPolicy: "allowlist",
        allowFrom: ["99"],
        groupAllowFrom: [],
        requireMention: true,
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalledTimes(1)
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 88n,
          text: "group allowlist reply",
        }),
      )
    })

    await handle.stop()
  })

  it("uses per-group allowFrom as the sender gate for Inline groups", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 60016n,
            date: 1_700_000_016n,
            fromId: 51n,
            message: "allowed by group sender override",
            mentioned: false,
          },
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      dispatchReplyPayload: {
        text: "group sender override reply",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {
        channels: {
          inline: {
            groups: {
              "chat:88": {
                requireMention: false,
                allowFrom: ["51"],
              },
            },
          },
        },
      } as any,
      account: buildAccount({
        groupPolicy: "allowlist",
        groupAllowFrom: ["99"],
        requireMention: true,
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalledTimes(1)
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 88n,
          text: "group sender override reply",
        }),
      )
    })

    await handle.stop()
  })

  it("does not let global groupAllowFrom bypass a per-group allowFrom override", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 60017n,
            date: 1_700_000_017n,
            fromId: 52n,
            message: "blocked by group sender override",
            mentioned: false,
          },
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      dispatchReplyPayload: {
        text: "should not send",
      },
    })
    const log = { info: vi.fn(), warn: vi.fn(), error: vi.fn() }

    const handle = await harness.monitorInlineProvider({
      cfg: {
        channels: {
          inline: {
            groups: {
              "chat:88": {
                requireMention: false,
                allowFrom: ["51"],
              },
            },
          },
        },
      } as any,
      account: buildAccount({
        groupPolicy: "allowlist",
        groupAllowFrom: ["*"],
        requireMention: true,
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log,
    })

    await waitFor(() => {
      expect(log.info).toHaveBeenCalledWith(
        expect.stringContaining("inline: drop group sender=52 (groupPolicy=allowlist)"),
      )
    })
    expect(harness.calls.dispatchReply).not.toHaveBeenCalled()
    expect(harness.calls.sendMessage).not.toHaveBeenCalled()

    await handle.stop()
  })

  it("routes native-mentioned Inline groups even when the group is not pre-allowlisted", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 60018n,
            date: 1_700_000_018n,
            fromId: 51n,
            message: "@inlinebot howdy",
            mentioned: true,
          },
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      dispatchReplyPayload: {
        text: "native mention reply",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        groupPolicy: "allowlist",
        groupAllowFrom: [],
        requireMention: true,
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalledTimes(1)
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 88n,
          text: "native mention reply",
        }),
      )
    })

    await handle.stop()
  })

  it("allows Inline group senders from access groups in groupAllowFrom", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 60013n,
            date: 1_700_000_013n,
            fromId: 51n,
            message: "allowed by access group",
            mentioned: false,
          },
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      dispatchReplyPayload: {
        text: "group access reply",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {
        accessGroups: {
          operators: {
            type: "message.senders",
            members: { inline: ["51"] },
          },
        },
        channels: {
          inline: {
            groups: {
              "chat:88": {
                requireMention: false,
              },
            },
          },
        },
      } as any,
      account: buildAccount({
        groupPolicy: "allowlist",
        groupAllowFrom: ["accessGroup:operators"],
        requireMention: true,
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalledTimes(1)
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 88n,
          text: "group access reply",
        }),
      )
    })

    await handle.stop()
  })

  it("drops non-allowlisted Inline groups without a native mention even when another group is configured", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 60012n,
            date: 1_700_000_012n,
            fromId: 51n,
            message: "not in allowlist",
            mentioned: false,
          },
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      dispatchReplyPayload: {
        text: "should not send",
      },
    })
    const log = { info: vi.fn(), warn: vi.fn(), error: vi.fn() }

    const handle = await harness.monitorInlineProvider({
      cfg: {
        channels: {
          inline: {
            groups: {
              "99": {
                requireMention: false,
              },
            },
          },
        },
      } as any,
      account: buildAccount({
        groupPolicy: "allowlist",
        groupAllowFrom: [],
        requireMention: true,
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log,
    })

    await waitFor(() => {
      expect(log.info).toHaveBeenCalledWith(
        expect.stringContaining("inline: drop group chat=88 (groupPolicy=allowlist)"),
      )
    })
    expect(harness.calls.dispatchReply).not.toHaveBeenCalled()
    expect(harness.calls.sendMessage).not.toHaveBeenCalled()

    await handle.stop()
  })

  it("treats mention pattern matches as mentions even when native mentioned is false", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 60015n,
            date: 1_700_000_055n,
            fromId: 51n,
            message: "hey boba, can you check this?",
            mentioned: false,
          },
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      mentionRegexes: [/boba/i],
      dispatchReplyPayload: {
        text: "on it",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        groupPolicy: "open",
        requireMention: true,
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalledTimes(1)
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          InboundEventKind: "user_request",
          WasMentioned: true,
        }),
      )
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 88n,
          text: "on it",
        }),
      )
    })

    await handle.stop()
  })

  it("includes prior skipped group messages from chat history when a later message mentions the bot", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 60020n,
            date: 1_700_000_060n,
            fromId: 51n,
            message: "context before mention",
            mentioned: false,
          },
        },
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 60021n,
            date: 1_700_000_061n,
            fromId: 51n,
            message: "@inlinebot can you summarize?",
            mentioned: true,
          },
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      historyByChat: {
        "88": [
          {
            id: 60020n,
            date: 1_700_000_060n,
            fromId: 51n,
            message: "context before mention",
          },
          {
            id: 60021n,
            date: 1_700_000_061n,
            fromId: 51n,
            message: "@inlinebot can you summarize?",
          },
        ],
      },
      dispatchReplyPayload: {
        text: "summary",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        groupPolicy: "open",
        requireMention: true,
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalledTimes(1)
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          Body: "@inlinebot can you summarize?",
          BodyForAgent: expect.stringContaining("can you summarize?"),
          InboundHistory: [
            expect.objectContaining({
              sender: "user:51",
              body: "context before mention",
            }),
          ],
        }),
      )
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 88n,
          text: "summary",
        }),
      )
    })

    await handle.stop()
  })

  it("strips the active Inline bot mention from agent prompt bodies", async () => {
    const harness = await setupMonitorHarness({
      me: {
        userId: 777n,
        username: "inlinebot",
      },
      events: [
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 60022n,
            date: 1_700_000_062n,
            fromId: 51n,
            message: "@inlinebot can you summarize?",
            mentioned: true,
            entities: {
              entities: [
                {
                  type: 1,
                  offset: 0n,
                  length: 10n,
                  entity: {
                    oneofKind: "mention",
                    mention: { userId: 777n },
                  },
                },
              ],
            },
          },
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      dispatchReplyPayload: {
        text: "summary",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        groupPolicy: "open",
        requireMention: true,
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalledTimes(1)
      const ctx = harness.calls.finalizeInboundContext.mock.calls[0]?.[0]
      expect(ctx).toEqual(
        expect.objectContaining({
          RawBody: "@inlinebot can you summarize?",
          CommandBody: "@inlinebot can you summarize?",
          WasMentioned: true,
          ExplicitlyMentionedBot: true,
          MentionedUserIds: ["777"],
          MentionSource: "explicit_bot",
        }),
      )
      expect(ctx.Body).toContain("can you summarize?")
      expect(ctx.Body).toContain("@inlinebot")
      expect(ctx.BodyForAgent).toContain("can you summarize?")
      expect(ctx.BodyForAgent).not.toContain("@inlinebot")
    })

    await handle.stop()
  })

  it("includes recent chat history on a first mention even when pending history is empty", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 60031n,
            date: 1_700_000_071n,
            fromId: 51n,
            message: "@inlinebot can you catch up?",
            mentioned: true,
          },
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      historyByChat: {
        "88": [
          {
            id: 60028n,
            date: 1_700_000_068n,
            fromId: 52n,
            message: "we changed the deployment config",
          },
          {
            id: 60029n,
            date: 1_700_000_069n,
            fromId: 53n,
            message: "staging looks stable now",
          },
          {
            id: 60030n,
            date: 1_700_000_070n,
            fromId: 51n,
            message: "can someone summarize this for the bot?",
          },
          {
            id: 60031n,
            date: 1_700_000_071n,
            fromId: 51n,
            message: "@inlinebot can you catch up?",
          },
        ],
      },
      dispatchReplyPayload: {
        text: "caught up",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        groupPolicy: "open",
        requireMention: true,
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalledTimes(1)
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          Body: "@inlinebot can you catch up?",
          BodyForAgent: expect.stringContaining("can you catch up?"),
          InboundHistory: [
            expect.objectContaining({
              sender: "user:52",
              body: "we changed the deployment config",
            }),
            expect.objectContaining({
              sender: "user:53",
              body: "staging looks stable now",
            }),
            expect.objectContaining({
              sender: "user:51",
              body: "can someone summarize this for the bot?",
            }),
          ],
        }),
      )
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 88n,
          text: "caught up",
        }),
      )
    })

    await handle.stop()
  })

  it("does not stall on a first mention when both pending history and fetched chat history are empty", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 60040n,
            date: 1_700_000_080n,
            fromId: 51n,
            message: "@inlinebot are you here?",
            mentioned: true,
          },
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      historyByChat: {
        "88": [],
      },
      dispatchReplyPayload: {
        text: "yes",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        groupPolicy: "open",
        requireMention: true,
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalledTimes(1)
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          Body: "@inlinebot are you here?",
          BodyForAgent: expect.stringContaining("are you here?"),
          InboundHistory: [],
        }),
      )
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 88n,
          text: "yes",
        }),
      )
    })

    await handle.stop()
  })

  it("stores skipped group messages as pending context and reuses them on mention when chat history is empty", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 61000n,
            date: 1_700_000_070n,
            fromId: 51n,
            message: "we deployed to staging and saw an error",
            mentioned: false,
          },
        },
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 61001n,
            date: 1_700_000_071n,
            fromId: 51n,
            message: "@inlinebot can you summarize what happened?",
            mentioned: true,
          },
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      dispatchReplyPayload: {
        text: "summary",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        groupPolicy: "open",
        requireMention: true,
        historyLimit: 10,
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalledTimes(1)
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          Body: "@inlinebot can you summarize what happened?",
          BodyForAgent: expect.stringContaining("can you summarize what happened?"),
          InboundHistory: [
            expect.objectContaining({
              sender: "user:51",
              body: "we deployed to staging and saw an error",
            }),
          ],
        }),
      )
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 88n,
          text: "summary",
        }),
      )
    })

    await handle.stop()
  })

  it("keeps skipped pending context entries when Inline reuses a message id with a newer date", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 61000n,
            date: 1_700_000_070n,
            fromId: 51n,
            message: "tail message before delete",
            mentioned: false,
          },
        },
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 61000n,
            date: 1_700_000_071n,
            fromId: 52n,
            message: "new message reused the tail id",
            mentioned: false,
          },
        },
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 61001n,
            date: 1_700_000_072n,
            fromId: 51n,
            message: "@inlinebot what did we miss?",
            mentioned: true,
          },
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      dispatchReplyPayload: {
        text: "summary",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        groupPolicy: "open",
        requireMention: true,
        historyLimit: 10,
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalledTimes(1)
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          Body: "@inlinebot what did we miss?",
          InboundHistory: [
            expect.objectContaining({
              sender: "user:51",
              body: "tail message before delete",
            }),
            expect.objectContaining({
              sender: "user:52",
              body: "new message reused the tail id",
            }),
          ],
        }),
      )
    })

    await handle.stop()
  })

  it("stores skipped attachment-only messages as media-aware pending context", async () => {
    const longMediaUrl = `https://cdn.inline.chat/pending-photo.jpg?token=${"a".repeat(420)}`
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 61010n,
            date: 1_700_000_072n,
            fromId: 51n,
            message: "",
            mentioned: false,
            media: {
              oneofKind: "photo",
              photo: {
                photo: {
                  id: 904n,
                  sizes: [{ w: 1200, h: 900, size: 22_222, cdnUrl: longMediaUrl }],
                },
              },
            },
          } as any,
        },
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 61011n,
            date: 1_700_000_073n,
            fromId: 51n,
            message: "@inlinebot summarize skipped media",
            mentioned: true,
          },
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      dispatchReplyPayload: {
        text: "summary",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        groupPolicy: "open",
        requireMention: true,
        historyLimit: 10,
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalledTimes(1)
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          Body: "@inlinebot summarize skipped media",
          InboundHistory: [
            expect.objectContaining({
              sender: "user:51",
              body: `image attachment: ${longMediaUrl}`,
            }),
          ],
        }),
      )
    })

    await handle.stop()
  })

  it("uses cfg.messages.groupChat.historyLimit for pending mention-gated context when account historyLimit is unset", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 62000n,
            date: 1_700_000_080n,
            fromId: 51n,
            message: "first skipped line",
            mentioned: false,
          },
        },
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 62001n,
            date: 1_700_000_081n,
            fromId: 51n,
            message: "second skipped line",
            mentioned: false,
          },
        },
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 62002n,
            date: 1_700_000_082n,
            fromId: 51n,
            message: "third skipped line",
            mentioned: false,
          },
        },
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 62003n,
            date: 1_700_000_083n,
            fromId: 51n,
            message: "@inlinebot summarize the latest lines",
            mentioned: true,
          },
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      dispatchReplyPayload: {
        text: "summary",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {
        messages: {
          groupChat: {
            historyLimit: 2,
          },
        },
      } as any,
      account: buildAccount({
        groupPolicy: "open",
        requireMention: true,
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalledTimes(1)
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          InboundHistory: [
            expect.objectContaining({ body: "second skipped line" }),
            expect.objectContaining({ body: "third skipped line" }),
          ],
        }),
      )
      expect(harness.calls.finalizeInboundContext).not.toHaveBeenCalledWith(
        expect.objectContaining({
          InboundHistory: expect.arrayContaining([expect.objectContaining({ body: "first skipped line" })]),
        }),
      )
    })

    await handle.stop()
  })

  it("normalizes targeted bot commands and bypasses mention gating for the active bot", async () => {
    const harness = await setupMonitorHarness({
      me: {
        userId: 777n,
        username: "inlinebot",
      },
      events: [
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 6002n,
            date: 1_700_000_006n,
            fromId: 51n,
            message: "/status@inlinebot now",
            mentioned: false,
          },
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      dispatchReplyPayload: {
        text: "command handled",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        groupPolicy: "open",
        requireMention: true,
        groupAllowFrom: ["51"],
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalledTimes(1)
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          RawBody: "/status@inlinebot now",
          CommandBody: "/status now",
          WasMentioned: true,
        }),
      )
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 88n,
          text: "command handled",
        }),
      )
    })

    await handle.stop()
  })

  it("does not allow Inline group control commands from DM allowFrom when groupAllowFrom is unset", async () => {
    const runtime = { log: vi.fn(), error: vi.fn() }
    const harness = await setupMonitorHarness({
      me: {
        userId: 777n,
        username: "inlinebot",
      },
      events: [
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 60020n,
            date: 1_700_000_020n,
            fromId: 51n,
            message: "/status",
            mentioned: false,
          },
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      dispatchReplyPayload: {
        text: "should not send",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        groupPolicy: "open",
        requireMention: true,
        allowFrom: ["51"],
        groupAllowFrom: [],
      }),
      runtime: runtime as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(runtime.log).toHaveBeenCalledWith(
        expect.stringContaining("inline: drop control command (unauthorized) target=51"),
      )
    })
    expect(harness.calls.dispatchReply).not.toHaveBeenCalled()
    expect(harness.calls.sendMessage).not.toHaveBeenCalled()

    await handle.stop()
  })

  it("allows Inline group control commands from commands.allowFrom", async () => {
    const harness = await setupMonitorHarness({
      me: {
        userId: 777n,
        username: "inlinebot",
      },
      events: [
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 60021n,
            date: 1_700_000_021n,
            fromId: 51n,
            message: "/status",
            mentioned: false,
          },
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      dispatchReplyPayload: {
        text: "command handled",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {
        commands: {
          allowFrom: { inline: ["51"] },
        },
      } as any,
      account: buildAccount({
        groupPolicy: "open",
        requireMention: true,
        groupAllowFrom: [],
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalledTimes(1)
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          CommandBody: "/status",
          WasMentioned: true,
          CommandAuthorized: true,
        }),
      )
    })

    await handle.stop()
  })

  it("keeps registered Inline slash commands active when text commands are disabled", async () => {
    const shouldHandleTextCommands = vi.fn(({ cfg, commandSource }: any) => {
      if (commandSource === "native") return true
      return cfg.commands?.text !== false
    })
    const harness = await setupMonitorHarness({
      me: {
        userId: 777n,
        username: "inlinebot",
      },
      events: [
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 60023n,
            date: 1_700_000_023n,
            fromId: 51n,
            message: "/status",
            mentioned: false,
          },
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      shouldHandleTextCommands,
      dispatchReplyPayload: {
        text: "command handled",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {
        commands: {
          text: false,
        },
      } as any,
      account: buildAccount({
        groupPolicy: "open",
        requireMention: true,
        groupAllowFrom: ["51"],
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalledTimes(1)
      expect(shouldHandleTextCommands).toHaveBeenCalledWith(
        expect.objectContaining({
          surface: "inline",
          commandSource: "native",
        }),
      )
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          CommandBody: "/status",
          CommandSource: "native",
          CommandTurn: expect.objectContaining({
            kind: "native",
            source: "native",
            authorized: true,
          }),
          WasMentioned: true,
          CommandAuthorized: true,
        }),
      )
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 88n,
          text: "command handled",
        }),
      )
    })

    await handle.stop()
  })

  it("keeps registered Inline skill commands active when text commands are disabled", async () => {
    const shouldHandleTextCommands = vi.fn(({ cfg, commandSource }: any) => {
      if (commandSource === "native") return true
      return cfg.commands?.text !== false
    })
    const harness = await setupMonitorHarness({
      me: {
        userId: 777n,
        username: "inlinebot",
      },
      events: [
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 60025n,
            date: 1_700_000_025n,
            fromId: 51n,
            message: "/deploy",
            mentioned: false,
          },
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      shouldHandleTextCommands,
      skillCommands: [{ name: "deploy", description: "Deploy a service." }],
      dispatchReplyPayload: {
        text: "skill handled",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {
        commands: {
          text: false,
          nativeSkills: true,
        },
      } as any,
      account: buildAccount({
        groupPolicy: "open",
        requireMention: true,
        groupAllowFrom: ["51"],
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalledTimes(1)
      expect(shouldHandleTextCommands).toHaveBeenCalledWith(
        expect.objectContaining({
          surface: "inline",
          commandSource: "native",
        }),
      )
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          CommandBody: "/deploy",
          CommandSource: "native",
          WasMentioned: true,
          CommandAuthorized: true,
        }),
      )
    })

    await handle.stop()
  })

  it("keeps registered Inline plugin commands active when text commands are disabled", async () => {
    const hasControlCommand = vi.fn(() => false)
    const shouldHandleTextCommands = vi.fn(({ cfg, commandSource }: any) => {
      if (commandSource === "native") return true
      return cfg.commands?.text !== false
    })
    const harness = await setupMonitorHarness({
      me: {
        userId: 777n,
        username: "inlinebot",
      },
      events: [
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 60026n,
            date: 1_700_000_026n,
            fromId: 51n,
            message: "/threadreply",
            mentioned: false,
          },
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      hasControlCommand,
      shouldHandleTextCommands,
      pluginCommands: [{ name: "threadreply", description: "Set Inline reply-thread mode." }],
      dispatchReplyPayload: {
        text: "plugin handled",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {
        commands: {
          text: false,
        },
      } as any,
      account: buildAccount({
        groupPolicy: "open",
        requireMention: true,
        groupAllowFrom: ["51"],
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalledTimes(1)
      expect(shouldHandleTextCommands).toHaveBeenCalledWith(
        expect.objectContaining({
          surface: "inline",
          commandSource: "native",
        }),
      )
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          CommandBody: "/threadreply",
          CommandSource: "native",
          WasMentioned: true,
          CommandAuthorized: true,
        }),
      )
    })

    await handle.stop()
  })

  it("handles built-in Inline plugin commands when the host command registry is empty", async () => {
    const hasControlCommand = vi.fn(() => false)
    const shouldHandleTextCommands = vi.fn(({ cfg, commandSource }: any) => {
      if (commandSource === "native") return true
      return cfg.commands?.text !== false
    })
    const harness = await setupMonitorHarness({
      me: {
        userId: 777n,
        username: "inlinebot",
      },
      events: [
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 60029n,
            date: 1_700_000_029n,
            fromId: 51n,
            message: "/threadreply",
            mentioned: false,
          },
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      hasControlCommand,
      shouldHandleTextCommands,
      pluginCommands: [],
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {
        commands: {
          text: false,
        },
      } as any,
      account: buildAccount({
        groupPolicy: "open",
        requireMention: true,
        groupAllowFrom: ["51"],
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).not.toHaveBeenCalled()
      expect(shouldHandleTextCommands).toHaveBeenCalledWith(
        expect.objectContaining({
          surface: "inline",
          commandSource: "native",
        }),
      )
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 88n,
          text: expect.stringContaining("Thread reply mode for chat 88: auto."),
          actions: expect.objectContaining({
            rows: expect.any(Array),
          }),
          parseMarkdown: true,
        }),
      )
    })

    await handle.stop()
  })

  it("honors channels.inline.commands.native when account commands only override native skills", async () => {
    const shouldHandleTextCommands = vi.fn(({ cfg, commandSource }: any) => {
      if (commandSource === "native") return true
      return cfg.commands?.text !== false
    })
    const harness = await setupMonitorHarness({
      me: {
        userId: 777n,
        username: "inlinebot",
      },
      events: [
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 60028n,
            date: 1_700_000_028n,
            fromId: 51n,
            message: "/status",
            mentioned: false,
          },
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      shouldHandleTextCommands,
      dispatchReplyPayload: {
        text: "command handled",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {
        commands: {
          native: false,
          text: false,
        },
        channels: {
          inline: {
            commands: { native: true },
          },
        },
      } as any,
      account: buildAccount({
        groupPolicy: "open",
        requireMention: true,
        groupAllowFrom: ["51"],
        commands: { nativeSkills: false },
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalledTimes(1)
      expect(shouldHandleTextCommands).toHaveBeenCalledWith(
        expect.objectContaining({
          surface: "inline",
          commandSource: "native",
        }),
      )
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          CommandBody: "/status",
          CommandSource: "native",
          WasMentioned: true,
          CommandAuthorized: true,
        }),
      )
    })

    await handle.stop()
  })

  it("keeps registered Inline plugin command button callbacks active when text commands are disabled", async () => {
    const hasControlCommand = vi.fn(() => false)
    const shouldHandleTextCommands = vi.fn(({ cfg, commandSource }: any) => {
      if (commandSource === "native") return true
      return cfg.commands?.text !== false
    })
    const harness = await setupMonitorHarness({
      me: {
        userId: 777n,
        username: "inlinebot",
      },
      events: [
        {
          kind: "message.action.invoke",
          chatId: 88n,
          interactionId: 44n,
          messageId: 60027n,
          actorUserId: 51n,
          actionId: "threadreply-min",
          data: new TextEncoder().encode("/threadreply min 0"),
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      historyByChat: {
        "88": [{ id: 60027n, date: 1_700_000_027n, fromId: 777n, message: "Thread reply mode?" }],
      },
      hasControlCommand,
      shouldHandleTextCommands,
      pluginCommands: [{ name: "threadreply", description: "Set Inline reply-thread mode." }],
      dispatchReplyPayload: {
        text: "plugin button handled",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {
        commands: {
          text: false,
        },
      } as any,
      account: buildAccount({
        groupPolicy: "open",
        requireMention: true,
        groupAllowFrom: ["51"],
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.answerMessageAction).toHaveBeenCalledWith({ interactionId: 44n })
      expect(shouldHandleTextCommands).toHaveBeenCalledWith(
        expect.objectContaining({
          surface: "inline",
          commandSource: "native",
        }),
      )
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          CommandBody: "/threadreply min 0",
          CommandSource: "native",
          WasMentioned: true,
          CommandAuthorized: true,
        }),
      )
      expect(harness.calls.invokeRaw).toHaveBeenCalledWith(
        8,
        expect.objectContaining({
          oneofKind: "editMessage",
          editMessage: expect.objectContaining({
            messageId: 60027n,
            text: "plugin button handled",
          }),
        }),
      )
      expect(harness.calls.sendMessage).not.toHaveBeenCalled()
    })

    await handle.stop()
  })

  it("does not treat Inline slash text as native when native commands are disabled", async () => {
    const shouldHandleTextCommands = vi.fn(({ cfg, commandSource }: any) => {
      if (commandSource === "native") return true
      return cfg.commands?.text !== false
    })
    const runtime = { log: vi.fn(), error: vi.fn() }
    const harness = await setupMonitorHarness({
      me: {
        userId: 777n,
        username: "inlinebot",
      },
      events: [
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 60024n,
            date: 1_700_000_024n,
            fromId: 51n,
            message: "/status",
            mentioned: false,
          },
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      shouldHandleTextCommands,
      dispatchReplyPayload: {
        text: "should not send",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {
        commands: {
          text: false,
        },
      } as any,
      account: buildAccount({
        groupPolicy: "open",
        requireMention: true,
        allowFrom: ["51"],
        groupAllowFrom: [],
        commands: { native: false },
      }),
      runtime: runtime as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(runtime.log).toHaveBeenCalledWith("inline: drop group chat 88 (no mention)")
    })
    expect(shouldHandleTextCommands).toHaveBeenCalledWith(
      expect.objectContaining({
        surface: "inline",
        commandSource: "text",
      }),
    )
    expect(harness.calls.dispatchReply).not.toHaveBeenCalled()
    expect(harness.calls.sendMessage).not.toHaveBeenCalled()

    await handle.stop()
  })

  it("blocks Inline group control commands when command owner config excludes the sender", async () => {
    const log = { info: vi.fn(), warn: vi.fn(), error: vi.fn() }
    const runtime = { log: vi.fn(), error: vi.fn() }
    const harness = await setupMonitorHarness({
      me: {
        userId: 777n,
        username: "inlinebot",
      },
      events: [
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 60022n,
            date: 1_700_000_022n,
            fromId: 51n,
            message: "/status",
            mentioned: false,
          },
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      dispatchReplyPayload: {
        text: "should not send",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {
        commands: {
          ownerAllowFrom: ["99"],
        },
      } as any,
      account: buildAccount({
        groupPolicy: "open",
        requireMention: true,
        groupAllowFrom: ["51"],
      }),
      runtime: runtime as any,
      abortSignal: new AbortController().signal,
      log,
    })

    await waitFor(() => {
      expect(runtime.log).toHaveBeenCalledWith(
        expect.stringContaining("inline: drop control command (unauthorized) target=51"),
      )
    })
    expect(harness.calls.dispatchReply).not.toHaveBeenCalled()
    expect(harness.calls.sendMessage).not.toHaveBeenCalled()

    await handle.stop()
  })

  it("can bypass mention gate on replies to bot messages and keeps reply threaded", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 7001n,
            date: 1_700_000_100n,
            fromId: 51n,
            message: "follow up",
            mentioned: false,
            replyToMsgId: 5000n,
          },
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      historyByChat: {
        "88": [
          {
            id: 5000n,
            date: 1_700_000_099n,
            fromId: 777n,
            message: "earlier bot message",
            out: true,
          },
        ],
      },
      dispatchReplyPayload: {
        text: "threaded reply",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        groupPolicy: "open",
        requireMention: true,
        replyToBotWithoutMention: true,
        historyLimit: 10,
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalled()
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 88n,
          text: "threaded reply",
          replyToMsgId: 7001n,
        }),
      )
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          Body: "follow up",
          InboundHistory: [
            expect.objectContaining({ body: "earlier bot message" }),
          ],
        }),
      )
    })

    await handle.stop()
  })

  it("includes attachment-only messages in history and current inbound body", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 7301n,
            date: 1_700_000_110n,
            fromId: 51n,
            message: "",
            mentioned: true,
            media: {
              media: {
                oneofKind: "photo",
                photo: {
                  photo: {
                    id: 900n,
                    sizes: [{ w: 1200, h: 900, size: 12345, cdnUrl: "https://cdn.inline.chat/current-photo.jpg" }],
                  },
                },
              },
            },
          } as any,
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      historyByChat: {
        "88": [
          {
            id: 7300n,
            date: 1_700_000_109n,
            fromId: 52n,
            message: "",
            attachments: {
              attachments: [
                {
                  attachment: {
                    oneofKind: "urlPreview",
                    urlPreview: {
                      id: 901n,
                      url: "https://example.com/design",
                      title: "Design mock",
                    },
                  },
                },
              ],
            },
          } as any,
        ],
      },
      mediaByUrl: {
        "https://cdn.inline.chat/current-photo.jpg": {
          contentType: "image/jpeg",
          fileName: "current-photo.jpg",
        },
      },
      dispatchReplyPayload: {
        text: "looks good",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        groupPolicy: "open",
        requireMention: true,
        historyLimit: 10,
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalled()
      expect(harness.calls.fetchRemoteMedia).toHaveBeenCalledWith(
        expect.objectContaining({
          url: "https://cdn.inline.chat/current-photo.jpg",
        }),
      )
      expect(harness.calls.saveMediaBuffer).toHaveBeenCalledWith(
        expect.any(Buffer),
        "image/jpeg",
        "inbound",
        300 * 1024 * 1024,
        "current-photo.jpg",
      )
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          Body: "<media:image>",
          InboundHistory: [
            expect.objectContaining({
              body: "link preview (Design mock): https://example.com/design",
            }),
          ],
        }),
      )
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          UntrustedStructuredContext: expect.arrayContaining([
            expect.objectContaining({
              type: "recent_media_attachments",
              payload: {
                summary: "Recent media/attachments: #7300 user:52: link preview (Design mock): https://example.com/design",
              },
            }),
          ]),
        }),
      )
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          BodyForAgent: "<media:image>",
          MediaPath: "/tmp/current-photo.jpg",
          MediaType: "image/jpeg",
          MediaUrl: "/tmp/current-photo.jpg",
          MediaPaths: ["/tmp/current-photo.jpg"],
          MediaUrls: ["/tmp/current-photo.jpg"],
          MediaTypes: ["image/jpeg"],
          UntrustedStructuredContext: expect.arrayContaining([
            expect.objectContaining({
              type: "current_media_attachments",
              payload: { summary: "image attachment: https://cdn.inline.chat/current-photo.jpg" },
            }),
          ]),
        }),
      )
    })

    await handle.stop()
  })

  it("includes previous flattened image-only messages in history context", async () => {
    const longMediaUrl = `https://cdn.inline.chat/history-photo.jpg?token=${"b".repeat(420)}`
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 7305n,
            date: 1_700_000_114n,
            fromId: 51n,
            message: "please review this update",
            mentioned: true,
          } as any,
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      historyByChat: {
        "88": [
          {
            id: 7300n,
            date: 1_700_000_109n,
            fromId: 52n,
            message: "",
            media: {
              oneofKind: "photo",
              photo: {
                photo: {
                  id: 901n,
                  sizes: [{ w: 1200, h: 900, size: 12345, cdnUrl: longMediaUrl }],
                },
              },
            },
          } as any,
        ],
      },
      dispatchReplyPayload: {
        text: "got it",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        groupPolicy: "open",
        requireMention: true,
        historyLimit: 10,
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalled()
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          Body: "please review this update",
          BodyForAgent: "please review this update",
        }),
      )
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          InboundHistory: expect.arrayContaining([
            expect.objectContaining({
              sender: "user:52",
              body: `image attachment: ${longMediaUrl}`,
            }),
          ]),
          UntrustedStructuredContext: expect.arrayContaining([
            expect.objectContaining({
              type: "recent_media_attachments",
              payload: {
                summary: `Recent media/attachments: #7300 user:52: image attachment: ${longMediaUrl}`,
              },
            }),
          ]),
        }),
      )
    })

    await handle.stop()
  })

  it("exposes attachment-only documents with placeholder text and media metadata", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 7303n,
            date: 1_700_000_112n,
            fromId: 51n,
            message: "",
            mentioned: true,
            media: {
              media: {
                oneofKind: "document",
                document: {
                  document: {
                    id: 902n,
                    cdnUrl: "https://cdn.inline.chat/spec.pdf",
                    fileName: "spec.pdf",
                    mimeType: "application/pdf",
                    size: 12_345,
                  },
                },
              },
            },
          } as any,
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      mediaByUrl: {
        "https://cdn.inline.chat/spec.pdf": {
          contentType: "application/pdf",
          fileName: "spec.pdf",
        },
      },
      dispatchReplyPayload: {
        text: "reviewed",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        groupPolicy: "open",
        requireMention: true,
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalled()
      expect(harness.calls.fetchRemoteMedia).toHaveBeenCalledWith(
        expect.objectContaining({
          url: "https://cdn.inline.chat/spec.pdf",
          filePathHint: "spec.pdf",
        }),
      )
      expect(harness.calls.saveMediaBuffer).toHaveBeenCalledWith(
        expect.any(Buffer),
        "application/pdf",
        "inbound",
        300 * 1024 * 1024,
        "spec.pdf",
      )
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          Body: "<media:document>",
          BodyForAgent: "<media:document>",
          RawBody: "<media:document>",
          CommandBody: "<media:document>",
          MediaPath: "/tmp/spec.pdf",
          MediaType: "application/pdf",
          MediaUrl: "/tmp/spec.pdf",
          MediaPaths: ["/tmp/spec.pdf"],
          MediaUrls: ["/tmp/spec.pdf"],
          MediaTypes: ["application/pdf"],
          UntrustedStructuredContext: expect.arrayContaining([
            expect.objectContaining({
              type: "current_media_attachments",
              payload: { summary: "document attachment (spec.pdf): https://cdn.inline.chat/spec.pdf" },
            }),
          ]),
        }),
      )
    })

    await handle.stop()
  })

  it("passes image documents as current media paths", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 7306n,
            date: 1_700_000_115n,
            fromId: 51n,
            message: "",
            mentioned: true,
            media: {
              media: {
                oneofKind: "document",
                document: {
                  document: {
                    id: 904n,
                    cdnUrl: "https://cdn.inline.chat/image-document",
                    fileName: "image-document.png",
                    size: 12_345,
                  },
                },
              },
            },
          } as any,
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      dispatchReplyPayload: {
        text: "saw it",
      },
      mediaByUrl: {
        "https://cdn.inline.chat/image-document": {
          contentType: "image/png",
          fileName: "image-document.png",
        },
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        groupPolicy: "open",
        requireMention: true,
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalled()
      expect(harness.calls.fetchRemoteMedia).toHaveBeenCalledWith(
        expect.objectContaining({
          url: "https://cdn.inline.chat/image-document",
          filePathHint: "image-document.png",
        }),
      )
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          Body: "<media:document>",
          BodyForAgent: "<media:document>",
          MediaPath: "/tmp/image-document.png",
          MediaType: "image/png",
          MediaUrl: "/tmp/image-document.png",
          MediaPaths: ["/tmp/image-document.png"],
          MediaUrls: ["/tmp/image-document.png"],
          MediaTypes: ["image/png"],
          UntrustedStructuredContext: expect.arrayContaining([
            expect.objectContaining({
              type: "current_media_attachments",
              payload: { summary: "document attachment (image-document.png): https://cdn.inline.chat/image-document" },
            }),
          ]),
        }),
      )
    })

    await handle.stop()
  })

  it("supports flattened media oneof payloads for attachment-only images", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 7304n,
            date: 1_700_000_113n,
            fromId: 51n,
            message: "",
            mentioned: true,
            media: {
              oneofKind: "photo",
              photo: {
                photo: {
                  id: 903n,
                  sizes: [{ w: 1280, h: 720, size: 67_890, cdnUrl: "https://cdn.inline.chat/flattened-photo.jpg" }],
                },
              },
            },
          } as any,
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      mediaByUrl: {
        "https://cdn.inline.chat/flattened-photo.jpg": {
          contentType: "image/jpeg",
          fileName: "flattened-photo.jpg",
        },
      },
      dispatchReplyPayload: {
        text: "saw it",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        groupPolicy: "open",
        requireMention: true,
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalled()
      expect(harness.calls.fetchRemoteMedia).toHaveBeenCalledWith(
        expect.objectContaining({
          url: "https://cdn.inline.chat/flattened-photo.jpg",
          filePathHint: "flattened-photo.jpg",
        }),
      )
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          Body: "<media:image>",
          BodyForAgent: "<media:image>",
          RawBody: "<media:image>",
          CommandBody: "<media:image>",
          MediaPath: "/tmp/flattened-photo.jpg",
          MediaType: "image/jpeg",
          MediaUrl: "/tmp/flattened-photo.jpg",
          MediaPaths: ["/tmp/flattened-photo.jpg"],
          MediaUrls: ["/tmp/flattened-photo.jpg"],
          MediaTypes: ["image/jpeg"],
          UntrustedStructuredContext: expect.arrayContaining([
            expect.objectContaining({
              type: "current_media_attachments",
              payload: { summary: "image attachment: https://cdn.inline.chat/flattened-photo.jpg" },
            }),
          ]),
        }),
      )
    })

    await handle.stop()
  })

  it("waits for Inline voice auto-transcript edits before dispatching", async () => {
    const voiceMedia = {
      media: {
        oneofKind: "voice",
        voice: {
          voice: {
            id: 901n,
            cdnUrl: "https://cdn.inline.chat/voice.ogg",
            mimeType: "audio/ogg",
            size: 12_345,
            duration: 4,
          },
        },
      },
    }
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 7n,
          message: {
            id: 7401n,
            date: 1_700_000_130n,
            fromId: 42n,
            message: "",
            media: voiceMedia,
          } as any,
        },
        {
          kind: "message.edit",
          chatId: 7n,
          message: {
            id: 7401n,
            date: 1_700_000_131n,
            fromId: 42n,
            message: "transcribed voice request",
            media: voiceMedia,
          } as any,
        },
      ],
      chats: {
        "7": { kind: "direct", title: "Alice" },
      },
      dispatchReplyPayload: {
        text: "voice reply",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        dmPolicy: "open",
        voiceTranscriptWaitMs: 200,
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalledTimes(1)
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          Body: "transcribed voice request",
          BodyForAgent: "transcribed voice request",
          RawBody: "transcribed voice request",
          MessageSid: "7401",
        }),
      )
    })
    expect(harness.calls.fetchRemoteMedia).not.toHaveBeenCalled()
    expect(harness.calls.enqueueSystemEvent).not.toHaveBeenCalled()

    await handle.stop()
  })

  it("falls back to raw voice audio when Inline transcript edit does not arrive", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 7n,
          message: {
            id: 7402n,
            date: 1_700_000_132n,
            fromId: 42n,
            message: "",
            media: {
              media: {
                oneofKind: "voice",
                voice: {
                  voice: {
                    id: 902n,
                    cdnUrl: "https://cdn.inline.chat/fallback-voice.ogg",
                    mimeType: "audio/ogg",
                    size: 12_345,
                    duration: 4,
                  },
                },
              },
            },
          } as any,
        },
      ],
      chats: {
        "7": { kind: "direct", title: "Alice" },
      },
      mediaByUrl: {
        "https://cdn.inline.chat/fallback-voice.ogg": {
          contentType: "audio/ogg",
          fileName: "fallback-voice.ogg",
        },
      },
      dispatchReplyPayload: {
        text: "fallback reply",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        dmPolicy: "open",
        voiceTranscriptWaitMs: 20,
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalledTimes(1)
      expect(harness.calls.fetchRemoteMedia).toHaveBeenCalledWith(
        expect.objectContaining({
          url: "https://cdn.inline.chat/fallback-voice.ogg",
          filePathHint: "fallback-voice.ogg",
        }),
      )
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          Body: "<media:audio>",
          BodyForAgent: "<media:audio>",
          RawBody: "<media:audio>",
          MediaPath: "/tmp/fallback-voice.ogg",
          MediaType: "audio/ogg",
          MediaUrl: "/tmp/fallback-voice.ogg",
          MediaPaths: ["/tmp/fallback-voice.ogg"],
          MediaUrls: ["/tmp/fallback-voice.ogg"],
          MediaTypes: ["audio/ogg"],
        }),
      )
    })

    await handle.stop()
  })

  it("continues when inbound media download fails", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 7302n,
            date: 1_700_000_111n,
            fromId: 51n,
            message: "",
            mentioned: true,
            media: {
              media: {
                oneofKind: "document",
                document: {
                  document: {
                    id: 901n,
                    cdnUrl: "https://cdn.inline.chat/broken-spec.pdf",
                    fileName: "broken-spec.pdf",
                    mimeType: "application/pdf",
                    size: 4567,
                  },
                },
              },
            },
          } as any,
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      dispatchReplyPayload: {
        text: "still replying",
      },
    })

    harness.calls.fetchRemoteMedia.mockRejectedValueOnce(new Error("network failed"))

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        groupPolicy: "open",
        requireMention: true,
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalled()
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.not.objectContaining({
          MediaPath: expect.anything(),
        }),
      )
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          Body: "<media:document>",
          BodyForAgent: "<media:document>",
          UntrustedStructuredContext: expect.arrayContaining([
            expect.objectContaining({
              type: "current_media_attachments",
              payload: { summary: "document attachment (broken-spec.pdf): https://cdn.inline.chat/broken-spec.pdf" },
            }),
          ]),
        }),
      )
    })

    await handle.stop()
  })

  it("preserves the remote attachment url when inbound media exceeds the configured limit", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 7304n,
            date: 1_700_000_113n,
            fromId: 51n,
            message: "",
            mentioned: true,
            media: {
              media: {
                oneofKind: "document",
                document: {
                  document: {
                    id: 903n,
                    cdnUrl: "https://cdn.inline.chat/huge-spec.pdf",
                    fileName: "huge-spec.pdf",
                    mimeType: "application/pdf",
                    size: 500_000_000,
                  },
                },
              },
            },
          } as any,
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      dispatchReplyPayload: {
        text: "still visible",
      },
    })

    harness.calls.fetchRemoteMedia.mockRejectedValueOnce(
      new Error(
        "Failed to fetch media from https://cdn.inline.chat/huge-spec.pdf: content length 500000000 exceeds maxBytes 1048576",
      ),
    )

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        groupPolicy: "open",
        requireMention: true,
        mediaMaxMb: 1,
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalled()
      expect(harness.calls.fetchRemoteMedia).toHaveBeenCalledWith(
        expect.objectContaining({
          url: "https://cdn.inline.chat/huge-spec.pdf",
          maxBytes: 1 * 1024 * 1024,
        }),
      )
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.not.objectContaining({
          MediaPath: expect.anything(),
        }),
      )
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          RawBody: "<media:document>",
          Body: "<media:document>",
          BodyForAgent: "<media:document>",
          UntrustedStructuredContext: expect.arrayContaining([
            expect.objectContaining({
              type: "current_media_attachments",
              payload: { summary: "document attachment (huge-spec.pdf): https://cdn.inline.chat/huge-spec.pdf" },
            }),
          ]),
        }),
      )
    })

    await handle.stop()
  })

  it("includes entity helpers and leaves generic formatting to channel metadata", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 91n,
          message: {
            id: 7401n,
            date: 1_700_000_200n,
            fromId: 52n,
            message: "See Alice docs",
            entities: {
              entities: [
                {
                  type: 1,
                  offset: 4n,
                  length: 5n,
                  entity: {
                    oneofKind: "mention",
                    mention: { userId: 99n },
                  },
                },
                {
                  type: 3,
                  offset: 10n,
                  length: 4n,
                  entity: {
                    oneofKind: "textUrl",
                    textUrl: { url: "https://example.com/current-docs" },
                  },
                },
              ],
            },
          } as any,
        },
      ],
      chats: {
        "91": { kind: "direct", title: "Alice" },
      },
      historyByChat: {
        "91": [
          {
            id: 7300n,
            date: 1_700_000_150n,
            fromId: 52n,
            message: "Review portal",
            entities: {
              entities: [
                {
                  type: 3,
                  offset: 7n,
                  length: 6n,
                  entity: {
                    oneofKind: "textUrl",
                    textUrl: { url: "https://example.com/history-portal" },
                  },
                },
              ],
            },
          } as any,
        ],
      },
      dispatchReplyPayload: {
        text: "looks good",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        dmPolicy: "open",
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalled()
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          Body: "See Alice docs",
          BodyForAgent: "See Alice docs",
          InboundHistory: expect.arrayContaining([
            expect.objectContaining({ body: "Review portal" }),
          ]),
          UntrustedStructuredContext: expect.arrayContaining([
            expect.objectContaining({
              type: "recent_message_entities",
              payload: {
                summary:
                  'Recent message entities: #7300 user:52: text link "portal" -> https://example.com/history-portal',
              },
            }),
            expect.objectContaining({
              type: "current_message_entities",
              payload: {
                summary: 'mention "Alice" -> user:99 | text link "docs" -> https://example.com/current-docs',
              },
            }),
          ]),
        }),
      )
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          GroupSystemPrompt: "",
        }),
      )
    })

    await handle.stop()
  })

  it("passes top-level systemPrompt guidance on direct messages", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 91n,
          message: {
            id: 7402n,
            date: 1_700_000_220n,
            fromId: 52n,
            message: "check the docs",
          } as any,
        },
      ],
      chats: {
        "91": { kind: "direct", title: "Alice" },
      },
      dispatchReplyPayload: {
        text: "looks good",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        dmPolicy: "open",
        systemPrompt: "Keep replies short.",
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalled()
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          GroupSystemPrompt: expect.stringContaining("Keep replies short."),
        }),
      )
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          GroupSystemPrompt: expect.not.stringContaining("Do not wrap bare URLs in inline code"),
        }),
      )
    })

    await handle.stop()
  })

  it("passes top-level and group-specific systemPrompt via GroupSystemPrompt", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 7402n,
            date: 1_700_000_220n,
            fromId: 52n,
            message: "check the docs",
          } as any,
        },
      ],
      chats: {
        "88": { kind: "group", title: "Design" },
      },
      dispatchReplyPayload: {
        text: "looks good",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        dmPolicy: "open",
        groupPolicy: "open",
        requireMention: false,
        systemPrompt: "Keep replies short.",
        groups: {
          "inline:88": {
            requireMention: false,
            systemPrompt: "Use markdown links when helpful.",
            tools: { allow: ["message"] },
          },
        },
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalled()
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          GroupSystemPrompt: expect.stringContaining("Keep replies short."),
        }),
      )
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          GroupSystemPrompt: expect.stringContaining("Use markdown links when helpful."),
        }),
      )
    })

    await handle.stop()
  })

  it("can bypass mention gate on replies to bot messages when historyLimit=0 via reply target lookup", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 7201n,
            date: 1_700_000_102n,
            fromId: 51n,
            message: "follow up",
            mentioned: false,
            replyToMsgId: 5000n,
          },
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      historyByChat: {
        "88": [
          {
            id: 5000n,
            date: 1_700_000_099n,
            fromId: 777n,
            message: "earlier bot message",
            out: true,
          },
        ],
      },
      dispatchReplyPayload: {
        text: "threaded reply",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        groupPolicy: "open",
        requireMention: true,
        replyToBotWithoutMention: true,
        historyLimit: 0,
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalledTimes(1)
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 88n,
          text: "threaded reply",
          replyToMsgId: 7201n,
        }),
      )
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          ReplyToSenderId: "777",
          ReplyToWasBot: true,
        }),
      )
    })

    await handle.stop()
  })

  it("does not bypass mention gate when reply target lookup resolves to a non-bot sender", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 7000n,
            date: 1_700_000_050n,
            fromId: 51n,
            message: "ping @bot",
            mentioned: true,
          },
        },
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 7001n,
            date: 1_700_000_051n,
            fromId: 52n,
            message: "replying to teammate",
            mentioned: false,
            replyToMsgId: 1n,
          },
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      historyByChat: {
        "88": [
          {
            id: 1n,
            date: 1_700_000_001n,
            fromId: 52n,
            message: "teammate message",
            out: false,
          },
        ],
      },
      dispatchReplyPayload: {
        text: "group reply",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        groupPolicy: "open",
        requireMention: true,
        replyToBotWithoutMention: true,
        historyLimit: 0,
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).toHaveBeenCalledTimes(1)
      expect(harness.calls.sendMessage).toHaveBeenCalledTimes(1)
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 88n,
          text: "group reply",
        }),
      )
    })

    await handle.stop()
  })

  it("does not bypass mention gate for replies when replyToBotWithoutMention=false", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.new",
          chatId: 88n,
          message: {
            id: 7101n,
            date: 1_700_000_101n,
            fromId: 51n,
            message: "follow up",
            mentioned: false,
            replyToMsgId: 5000n,
          },
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      historyByChat: {
        "88": [
          {
            id: 5000n,
            date: 1_700_000_099n,
            fromId: 777n,
            message: "earlier bot message",
            out: true,
          },
        ],
      },
      dispatchReplyPayload: {
        text: "threaded reply",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        groupPolicy: "open",
        requireMention: true,
        replyToBotWithoutMention: false,
        historyLimit: 10,
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.dispatchReply).not.toHaveBeenCalled()
      expect(harness.calls.sendMessage).not.toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 88n,
          text: "threaded reply",
        }),
      )
    })

    await handle.stop()
  })

  it("queues same-second existing bot participant-add events with prior mention guidance", async () => {
    const participantDate = BigInt(Math.floor(Date.now() / 1000))
    const harness = await setupMonitorHarness({
      me: {
        userId: 777n,
        username: "inlinebot",
      },
      events: [
        {
          kind: "chat.participant.add",
          chatId: 88n,
          participant: {
            userId: 777n,
            date: participantDate,
          },
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      participants: {
        "88": [
          { id: 51n, username: "alice", firstName: "Alice" },
          { id: 777n, username: "inlinebot", firstName: "Inline Bot" },
        ],
      },
      historyByChat: {
        "88": [
          {
            id: 5001n,
            date: participantDate,
            fromId: 51n,
            message: "@inlinebot can you check this after joining?",
            out: false,
          },
        ],
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        groupPolicy: "allowlist",
        requireMention: true,
        historyLimit: 10,
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.enqueueSystemEvent).toHaveBeenCalledWith(
        expect.stringContaining("Inline bot was added as a participant in #Project Room."),
        expect.objectContaining({
          sessionKey: "agent:main:inline:group:88",
          contextKey: `inline:participant:added:88:777:${String(participantDate)}`,
        }),
      )
      expect(harness.calls.enqueueSystemEvent.mock.calls[0]?.[0]).toContain(
        "#5001 Alice (@alice) id:51: @inlinebot can you check this after joining?",
      )
      expect(harness.calls.enqueueSystemEvent.mock.calls[0]?.[0]).toContain(
        "The bot was mentioned before it joined.",
      )
      expect(harness.calls.enqueueSystemEvent.mock.calls[0]?.[0]).toContain(
        "Prior bot mentions before join:",
      )
    })
    expect(harness.calls.dispatchReply).not.toHaveBeenCalled()
    expect(harness.calls.sendMessage).not.toHaveBeenCalled()

    await handle.stop()
  })

  it("keeps fresh bot participant-add events quiet", async () => {
    const participantDate = BigInt(Math.floor(Date.now() / 1000))
    const harness = await setupMonitorHarness({
      me: {
        userId: 777n,
        username: "inlinebot",
      },
      events: [
        {
          kind: "chat.participant.add",
          chatId: 88n,
          participant: {
            userId: 777n,
            date: participantDate,
          },
        },
      ],
      chats: {
        "88": { kind: "group", title: "Fresh Room" },
      },
      participants: {
        "88": [
          { id: 51n, username: "alice", firstName: "Alice" },
          { id: 777n, username: "inlinebot", firstName: "Inline Bot" },
        ],
      },
      historyByChat: {
        "88": [],
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        groupPolicy: "allowlist",
        requireMention: true,
        historyLimit: 10,
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.invokeRaw).toHaveBeenCalledWith(
        5,
        expect.objectContaining({
          oneofKind: "getChatHistory",
        }),
      )
    })
    expect(harness.calls.enqueueSystemEvent).not.toHaveBeenCalled()
    expect(harness.calls.sendMessage).not.toHaveBeenCalled()

    await handle.stop()
  })

  it("ignores participant-add events for other users", async () => {
    const harness = await setupMonitorHarness({
      me: {
        userId: 777n,
      },
      events: [
        {
          kind: "chat.participant.add",
          chatId: 88n,
          participant: {
            userId: 51n,
            date: 1_700_000_150n,
          },
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        groupPolicy: "open",
        requireMention: true,
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await handle.done
    expect(harness.calls.enqueueSystemEvent).not.toHaveBeenCalled()
    expect(harness.calls.dispatchReply).not.toHaveBeenCalled()

    await handle.stop()
  })

  it("queues reaction events on bot messages as system events", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "reaction.add",
          chatId: 88n,
          reaction: {
            emoji: "🔥",
            userId: 51n,
            messageId: 5000n,
            chatId: 88n,
            date: 1_700_000_110n,
          },
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      participants: {
        "88": [{ id: 51n, username: "alice", firstName: "Alice" }],
      },
      historyByChat: {
        "88": [
          {
            id: 5000n,
            date: 1_700_000_099n,
            fromId: 777n,
            message: "earlier bot message",
            out: true,
          },
        ],
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        groupPolicy: "open",
        requireMention: true,
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.enqueueSystemEvent).toHaveBeenCalledWith(
        "Inline reaction added: 🔥 by Alice (@alice) id:51 in #Project Room msg 5000",
        expect.objectContaining({
          sessionKey: "agent:main:inline:group:88",
          contextKey: "inline:reaction:added:88:5000:51:🔥",
        }),
      )
    })
    expect(harness.calls.dispatchReply).not.toHaveBeenCalled()
    expect(harness.calls.sendMessage).not.toHaveBeenCalled()

    await handle.stop()
  })

  it("queues reply-thread reaction events on the thread session", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "reaction.add",
          chatId: 7100n,
          reaction: {
            emoji: "🔥",
            userId: 51n,
            messageId: 61002n,
            chatId: 7100n,
            date: 1_700_000_110n,
          },
        },
      ],
      chats: {
        "7000": { kind: "group", title: "Deploy Room" },
        "7100": {
          kind: "group",
          title: "Re: deploy plan",
          parentChatId: 7000n,
          parentMessageId: 5000n,
        },
      },
      participants: {
        "7100": [{ id: 51n, username: "alice", firstName: "Alice" }],
      },
      historyByChat: {
        "7100": [
          {
            id: 61002n,
            date: 1_700_000_099n,
            fromId: 777n,
            message: "earlier bot message",
            out: true,
          },
        ],
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        groupPolicy: "open",
        requireMention: true,
        replyThreads: true,
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.enqueueSystemEvent).toHaveBeenCalledWith(
        expect.stringContaining("Inline reaction added"),
        expect.objectContaining({
          sessionKey: "agent:main:inline:group:7000:thread:7100",
          contextKey: "inline:reaction:added:7100:61002:51:🔥",
        }),
      )
    })

    await handle.stop()
  })

  it("queues removed reaction events on bot messages as system events", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "reaction.delete",
          chatId: 88n,
          emoji: "🔥",
          userId: 51n,
          messageId: 5000n,
          date: 1_700_000_111n,
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      participants: {
        "88": [{ id: 51n, username: "alice", firstName: "Alice" }],
      },
      historyByChat: {
        "88": [
          {
            id: 5000n,
            date: 1_700_000_099n,
            fromId: 777n,
            message: "earlier bot message",
            out: true,
          },
        ],
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        groupPolicy: "open",
        requireMention: true,
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.enqueueSystemEvent).toHaveBeenCalledWith(
        "Inline reaction removed: 🔥 by Alice (@alice) id:51 in #Project Room msg 5000",
        expect.objectContaining({
          sessionKey: "agent:main:inline:group:88",
          contextKey: "inline:reaction:removed:88:5000:51:🔥",
        }),
      )
    })
    expect(harness.calls.dispatchReply).not.toHaveBeenCalled()
    expect(harness.calls.sendMessage).not.toHaveBeenCalled()

    await handle.stop()
  })

  it("ignores reaction events that target non-bot messages", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "reaction.add",
          chatId: 88n,
          reaction: {
            emoji: "🔥",
            userId: 51n,
            messageId: 5001n,
            chatId: 88n,
            date: 1_700_000_120n,
          },
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      historyByChat: {
        "88": [
          {
            id: 5001n,
            date: 1_700_000_119n,
            fromId: 51n,
            message: "user message",
            out: false,
          },
        ],
      },
      dispatchReplyPayload: {
        text: "noted",
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        groupPolicy: "open",
        requireMention: true,
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.invokeRaw).toHaveBeenCalledWith(
        38,
        expect.objectContaining({ oneofKind: "getMessages" }),
      )
    })
    expect(harness.calls.dispatchReply).not.toHaveBeenCalled()
    expect(harness.calls.sendMessage).not.toHaveBeenCalled()

    await handle.stop()
  })

  it("skips reaction system events when reaction notifications are off", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "reaction.add",
          chatId: 88n,
          reaction: {
            emoji: "🔥",
            userId: 51n,
            messageId: 5000n,
            chatId: 88n,
            date: 1_700_000_130n,
          },
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      historyByChat: {
        "88": [
          {
            id: 5000n,
            date: 1_700_000_099n,
            fromId: 777n,
            message: "earlier bot message",
            out: true,
          },
        ],
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        groupPolicy: "open",
        requireMention: true,
        reactionNotifications: "off",
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await handle.done
    expect(harness.calls.enqueueSystemEvent).not.toHaveBeenCalled()
    expect(harness.calls.invokeRaw).not.toHaveBeenCalledWith(
      38,
      expect.objectContaining({ oneofKind: "getMessages" }),
    )

    await handle.stop()
  })

  it("queues reaction system events on any authorized message when reaction notifications are all", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "reaction.add",
          chatId: 88n,
          reaction: {
            emoji: "🔥",
            userId: 51n,
            messageId: 5001n,
            chatId: 88n,
            date: 1_700_000_131n,
          },
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      participants: {
        "88": [{ id: 51n, username: "alice", firstName: "Alice" }],
      },
      historyByChat: {
        "88": [
          {
            id: 5001n,
            date: 1_700_000_119n,
            fromId: 51n,
            message: "user message",
            out: false,
          },
        ],
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        groupPolicy: "open",
        requireMention: true,
        reactionNotifications: "all",
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.enqueueSystemEvent).toHaveBeenCalledWith(
        "Inline reaction added: 🔥 by Alice (@alice) id:51 in #Project Room msg 5001",
        expect.objectContaining({
          sessionKey: "agent:main:inline:group:88",
          contextKey: "inline:reaction:added:88:5001:51:🔥",
        }),
      )
    })
    expect(harness.calls.invokeRaw).not.toHaveBeenCalledWith(
      38,
      expect.objectContaining({ oneofKind: "getMessages" }),
    )

    await handle.stop()
  })

  it("skips reaction system events from senders outside the reaction allowlist", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "reaction.add",
          chatId: 88n,
          reaction: {
            emoji: "🔥",
            userId: 51n,
            messageId: 5001n,
            chatId: 88n,
            date: 1_700_000_132n,
          },
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        groupPolicy: "open",
        requireMention: true,
        reactionNotifications: "allowlist",
        reactionAllowlist: ["99"],
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await handle.done
    expect(harness.calls.enqueueSystemEvent).not.toHaveBeenCalled()
    expect(harness.calls.invokeRaw).not.toHaveBeenCalledWith(
      38,
      expect.objectContaining({ oneofKind: "getMessages" }),
    )

    await handle.stop()
  })

  it("queues reaction system events from senders inside the reaction allowlist", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "reaction.add",
          chatId: 88n,
          reaction: {
            emoji: "🔥",
            userId: 51n,
            messageId: 5001n,
            chatId: 88n,
            date: 1_700_000_133n,
          },
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
      participants: {
        "88": [{ id: 51n, username: "alice", firstName: "Alice" }],
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        groupPolicy: "open",
        requireMention: true,
        reactionNotifications: "allowlist",
        reactionAllowlist: ["51"],
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.enqueueSystemEvent).toHaveBeenCalledWith(
        "Inline reaction added: 🔥 by Alice (@alice) id:51 in #Project Room msg 5001",
        expect.objectContaining({
          sessionKey: "agent:main:inline:group:88",
          contextKey: "inline:reaction:added:88:5001:51:🔥",
        }),
      )
    })
    expect(harness.calls.invokeRaw).not.toHaveBeenCalledWith(
      38,
      expect.objectContaining({ oneofKind: "getMessages" }),
    )

    await handle.stop()
  })

  it("queues message edit lifecycle events as system events", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.edit",
          chatId: 88n,
          message: {
            id: 5002n,
            date: 1_700_000_121n,
            fromId: 51n,
            message: "edited text",
          },
        },
      ],
      chats: {
        "88": { kind: "group", title: "Project Room" },
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({
        groupPolicy: "open",
        requireMention: true,
      }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.enqueueSystemEvent).toHaveBeenCalledWith(
        "Inline message edited in #Project Room.",
        {
          sessionKey: "agent:main:inline:group:88",
          contextKey: "inline:message:edited:88:5002",
        },
      )
    })
    expect(harness.calls.dispatchReply).not.toHaveBeenCalled()
    expect(harness.calls.sendMessage).not.toHaveBeenCalled()

    await handle.stop()
  })

  it("ignores self-authored message edit lifecycle events", async () => {
    const harness = await setupMonitorHarness({
      me: {
        userId: 777n,
      },
      events: [
        {
          kind: "message.edit",
          chatId: 7n,
          message: {
            id: 1001n,
            date: 1_700_000_121n,
            fromId: 777n,
            message: "edited bot text",
          },
        },
      ],
      chats: {
        "7": { kind: "direct", title: "Alice", peerUserId: 42n },
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ dmPolicy: "open" }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await handle.done
    expect(harness.calls.enqueueSystemEvent).not.toHaveBeenCalled()
    expect(harness.calls.dispatchReply).not.toHaveBeenCalled()

    await handle.stop()
  })

  it("queues direct message delete lifecycle events using the direct peer route", async () => {
    const harness = await setupMonitorHarness({
      events: [
        {
          kind: "message.delete",
          chatId: 7n,
          messageIds: [1001n, 1002n],
          date: 1_700_000_121n,
        },
      ],
      chats: {
        "7": { kind: "direct", title: "Alice", peerUserId: 42n },
      },
    })

    const handle = await harness.monitorInlineProvider({
      cfg: {} as any,
      account: buildAccount({ dmPolicy: "open" }),
      runtime: { log: vi.fn(), error: vi.fn() } as any,
      abortSignal: new AbortController().signal,
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    })

    await waitFor(() => {
      expect(harness.calls.enqueueSystemEvent).toHaveBeenCalledWith(
        "Inline messages deleted in direct chat with Alice.",
        {
          sessionKey: "agent:main:inline:direct:42",
          contextKey: "inline:message:deleted:7:1001,1002",
        },
      )
    })
    expect(harness.calls.dispatchReply).not.toHaveBeenCalled()
    expect(harness.calls.sendMessage).not.toHaveBeenCalled()

    await handle.stop()
  })
})
