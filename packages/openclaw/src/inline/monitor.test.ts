import os from "node:os"
import path from "node:path"
import { describe, expect, it, vi } from "vitest"

const modelRuntimeMocks = vi.hoisted(() => ({
  buildModelsProviderData: vi.fn(),
  resolveDefaultModelForAgent: vi.fn(),
  updateSessionStore: vi.fn(),
  applyModelOverrideToSessionEntry: vi.fn(),
}))

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

vi.mock("openclaw/plugin-sdk/config-runtime", async () => {
  const actual = await vi.importActual<typeof import("openclaw/plugin-sdk/config-runtime")>(
    "openclaw/plugin-sdk/config-runtime",
  )
  return {
    ...actual,
    updateSessionStore: modelRuntimeMocks.updateSessionStore,
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
    answerMessageAction: ReturnType<typeof vi.fn>
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
    parentChatId?: bigint
    parentMessageId?: bigint
  }>
  participants?: Record<string, Array<{ id: bigint; username?: string; firstName?: string; lastName?: string }>>
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
  dispatchReplyPayload?: {
    text?: string
    replyToId?: string
    mediaUrl?: string
    mediaUrls?: string[]
    buttons?: Array<Array<{ text?: string; callback_data?: string }>>
    channelData?: Record<string, unknown>
  }
  dispatchReplyPayloads?: Array<{
    text?: string
    replyToId?: string
    mediaUrl?: string
    mediaUrls?: string[]
    buttons?: Array<Array<{ text?: string; callback_data?: string }>>
    channelData?: Record<string, unknown>
  }>
  partialReplies?: Array<{ text?: string; mediaUrls?: string[] }>
  reasoningReplies?: Array<{ text?: string; mediaUrls?: string[] }>
  partialRepliesConcurrent?: boolean
  assistantMessageStartBeforePayloadIndexes?: number[]
  toolStartBeforePayloadIndexes?: number[]
  compactionStartBeforePayloadIndexes?: number[]
  compactionEndBeforePayloadIndexes?: number[]
  payloadInfoKinds?: Array<"final" | "partial" | "error">
  skipInfos?: Array<{ reason?: string }>
  dispatchErrorInfos?: Array<{ kind?: string }>
  sendMessageDelayMs?: number
}

function buildAccount(overrides?: {
  dmPolicy?: "pairing" | "allowlist" | "open" | "disabled"
  groupPolicy?: "allowlist" | "open" | "disabled"
  allowFrom?: string[]
  groupAllowFrom?: string[]
  systemPrompt?: string
  groups?: Record<string, {
    requireMention?: boolean
    systemPrompt?: string
    tools?: { allow?: string[]; deny?: string[] }
    toolsBySender?: Record<string, { allow?: string[]; deny?: string[] }>
  }>
  requireMention?: boolean
  replyToBotWithoutMention?: boolean
  historyLimit?: number
  dmHistoryLimit?: number
  parseMarkdown?: boolean
  blockStreaming?: boolean
  streamViaEditMessage?: boolean
  mediaMaxMb?: number
  replyThreads?: boolean
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
      groupPolicy: overrides?.groupPolicy ?? "allowlist",
      groupAllowFrom: overrides?.groupAllowFrom ?? [],
      systemPrompt: overrides?.systemPrompt,
      groups: overrides?.groups,
      requireMention: overrides?.requireMention ?? true,
      replyToBotWithoutMention: overrides?.replyToBotWithoutMention,
      historyLimit: overrides?.historyLimit,
      dmHistoryLimit: overrides?.dmHistoryLimit,
      parseMarkdown: overrides?.parseMarkdown ?? true,
      blockStreaming: overrides?.blockStreaming,
      streamViaEditMessage: overrides?.streamViaEditMessage,
      mediaMaxMb: overrides?.mediaMaxMb,
      capabilities: overrides?.replyThreads != null ? { replyThreads: overrides.replyThreads } : undefined,
      textChunkLimit: 4000,
    },
  } as any
}

async function waitFor(assertion: () => void, timeoutMs = 1_500): Promise<void> {
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

async function setupMonitorHarness(setup: MonitorSetup): Promise<MonitorHarness> {
  vi.resetModules()

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
  modelRuntimeMocks.updateSessionStore.mockReset().mockImplementation(async (_storePath: string, update: (store: any) => void | Promise<void>) => {
    const store: Record<string, unknown> = {}
    await update(store)
  })
  modelRuntimeMocks.applyModelOverrideToSessionEntry.mockReset().mockImplementation(({ entry, selection }: any) => {
    entry.provider = selection.provider
    entry.model = selection.model
    entry.isDefault = selection.isDefault
    return { updated: true }
  })

  const sendMessage = vi.fn(async () => {
    if (setup.sendMessageDelayMs != null && setup.sendMessageDelayMs > 0) {
      await new Promise((resolve) => setTimeout(resolve, setup.sendMessageDelayMs))
    }
    return { messageId: 1n }
  })
  const uploadFile = vi.fn(async () => ({ fileUniqueId: "INP_1", photoId: 200n }))
  const answerMessageAction = vi.fn(async () => {})
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
  const dispatchReply = vi.fn(async ({ dispatcherOptions, replyOptions }: any) => {
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
        await replyOptions?.onToolStart?.({ name: "tool.test" })
      }
      if (setup.compactionStartBeforePayloadIndexes?.includes(index)) {
        await replyOptions?.onCompactionStart?.()
      }
      if (setup.compactionEndBeforePayloadIndexes?.includes(index)) {
        await replyOptions?.onCompactionEnd?.()
      }
      const payload = payloads[index]
      if (!payload) continue
      const kind = setup.payloadInfoKinds?.[index]
      if (kind) {
        await dispatcherOptions.deliver(payload, { kind })
      } else {
        await dispatcherOptions.deliver(payload)
      }
    }
    for (const skipInfo of setup.skipInfos ?? []) {
      await dispatcherOptions.onSkip?.({ isError: false }, skipInfo)
    }
    for (const errInfo of setup.dispatchErrorInfos ?? []) {
      await dispatcherOptions.onError?.(new Error("dispatch error"), { kind: errInfo.kind ?? "final" })
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
    },
  ) => {
    if (method === 1 && input?.oneofKind === "getMe") {
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
      if (!info || info.kind === "direct") {
        return {
          oneofKind: "getChat",
          getChat: {},
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
          },
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
    if (method === 8 && input?.oneofKind === "editMessage") {
      return {
        oneofKind: "editMessage",
        editMessage: { updates: [] },
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

    return {
      JsonFileStateStore: class {
        constructor(_path: string) {}
      },
      Method: {
        GET_ME: 1,
        GET_CHAT_HISTORY: 5,
        GET_CHAT: 25,
        GET_CHAT_PARTICIPANTS: 13,
        EDIT_MESSAGE: 8,
        GET_MESSAGES: 38,
        INVOKE_MESSAGE_ACTION: 48,
        ANSWER_MESSAGE_ACTION: 49,
      },
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = vi.fn(async () => {})
        getMe = vi.fn(async () => ({ userId: setup.me?.userId ?? 777n }))
        getChat = vi.fn(async ({ chatId }: { chatId: bigint }) => {
          const key = String(chatId)
          const info = setup.chats[key] ?? { kind: "group", title: `chat-${key}` }
          if (info.kind === "direct") {
            return {
              chatId,
              title: info.title ?? "Direct",
              peer: { type: { oneofKind: "user" } },
            }
          }
          return {
            chatId,
            title: info.title ?? "Group",
            peer: { type: { oneofKind: "chat", chat: { chatId } } },
            ...(info.parentChatId != null ? { parentChatId: info.parentChatId } : {}),
            ...(info.parentMessageId != null ? { parentMessageId: info.parentMessageId } : {}),
          }
        })
        sendMessage = sendMessage
        uploadFile = uploadFile
        sendTyping = vi.fn(async () => {})
        answerMessageAction = answerMessageAction
        invokeRaw = invokeRaw
        invokeUncheckedRaw = this.invokeRaw
        close = vi.fn(async () => {})
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
      resolveControlCommandGate: vi.fn(() => ({ shouldBlock: false, commandAuthorized: true })),
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
      createChannelReplyPipeline: vi.fn(() => ({
        onModelSelected: vi.fn(),
      })),
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
    state: {
      resolveStateDir: () => path.join(os.tmpdir(), "openclaw-inline-tests"),
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
    channel: {
      pairing: {
        readAllowFromStore,
        upsertPairingRequest,
        buildPairingReply,
      },
      commands: {
        shouldHandleTextCommands: () => true,
      },
      media: {
        fetchRemoteMedia,
        saveMediaBuffer,
      },
      text: {
        hasControlCommand: (text?: string) => /^\/\S+/.test((text ?? "").trim()),
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
        resolveStorePath: () => path.join(os.tmpdir(), "openclaw-inline-tests", "sessions.json"),
        readSessionUpdatedAt: () => null,
        recordInboundSession,
      },
      reply: {
        resolveEnvelopeFormatOptions: () => ({ mode: "compact" }),
        formatAgentEnvelope: ({ body }: { body: string }) => body,
        finalizeInboundContext,
        dispatchReplyWithBufferedBlockDispatcher: dispatchReply,
      },
    },
  } as any)

  const mod = await import("./monitor")
  return {
    monitorInlineProvider: mod.monitorInlineProvider,
    calls: {
      sendMessage,
      invokeRaw,
      uploadFile,
      fetchRemoteMedia,
      saveMediaBuffer,
      resolveAgentRoute,
      recordInboundSession,
      finalizeInboundContext,
      dispatchReply,
      answerMessageAction,
      upsertPairingRequest,
      buildPairingReply,
      readAllowFromStore,
    },
  }
}

describe("inline/monitor", () => {
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
          ReplyToId: "9",
          From: "inline:42",
          To: "inline:7",
        }),
      )
      expect(harness.calls.finalizeInboundContext.mock.calls[0]?.[0]).not.toHaveProperty("MessageThreadId")
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
          To: "inline:7000",
          OriginatingTo: "inline:7000",
          GroupSubject: "Deploy Room",
          MessageThreadId: "7100",
          ThreadLabel: "Re: deploy plan",
          Body: expect.stringContaining("Parent thread anchor"),
          InboundHistory: expect.arrayContaining([
            expect.objectContaining({ body: "Parent thread anchor" }),
            expect.objectContaining({ body: "thread follow-up context" }),
          ]),
        }),
      )
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          InboundHistory: expect.not.arrayContaining([
            expect.objectContaining({ body: "unrelated parent chat line" }),
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
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          MessageActionInteractionId: "22",
          MessageActionId: "pick",
          MessageActionDataBase64: "eyJrIjoxfQ==",
        }),
      )
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

  it("renders native command menu buttons for /subagents and skips agent dispatch", async () => {
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
    expect(new TextDecoder().decode(firstButtonData)).toBe("/subagents list")

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
          telegram: {
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
          Surface: "telegram",
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

  it("maps telegram-style buttons to inline message actions on text replies", async () => {
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

  it("preserves native telegram model callbacks on rendered buttons", async () => {
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

  it("attaches telegram-style buttons only to the first media send", async () => {
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
          GroupSubject: "Project Room",
          From: "inline:chat:88",
          To: "inline:88",
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

  it("accepts allowFrom entries with user: prefix", async () => {
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
        allowFrom: ["user:42"],
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
          Body: expect.stringContaining("#60020 user:51: context before mention"),
          BodyForAgent: "@inlinebot can you summarize?",
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
          Body: expect.stringContaining("#60028 user:52: we changed the deployment config"),
          BodyForAgent: "@inlinebot can you catch up?",
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
          BodyForAgent: "@inlinebot are you here?",
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
          Body: expect.stringContaining("we deployed to staging and saw an error"),
          BodyForAgent: "@inlinebot can you summarize what happened?",
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
          Body: expect.stringContaining(`image attachment: ${longMediaUrl}`),
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
          Body: expect.stringContaining("Recent thread messages (oldest -> newest):"),
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
          Body: expect.stringContaining("#7300 user:52: link preview (Design mock): https://example.com/design"),
        }),
      )
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          Body: expect.stringContaining("Recent media/attachments:\n#7300 user:52: link preview (Design mock): https://example.com/design"),
        }),
      )
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          Body: expect.stringMatching(
            /Current message:\n<media:image>[\s\S]*Current media\/attachments:\nimage attachment: https:\/\/cdn\.inline\.chat\/current-photo\.jpg/,
          ),
          MediaPath: "/tmp/current-photo.jpg",
          MediaType: "image/jpeg",
          MediaUrl: "/tmp/current-photo.jpg",
          MediaPaths: ["/tmp/current-photo.jpg"],
          MediaUrls: ["/tmp/current-photo.jpg"],
          MediaTypes: ["image/jpeg"],
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
          Body: expect.stringContaining(
            `Recent thread messages (oldest -> newest):\n#7300 user:52: image attachment: ${longMediaUrl}`,
          ),
        }),
      )
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          Body: expect.stringContaining(
            `Recent media/attachments:\n#7300 user:52: image attachment: ${longMediaUrl}`,
          ),
          InboundHistory: expect.arrayContaining([
            expect.objectContaining({
              sender: "user:52",
              body: `image attachment: ${longMediaUrl}`,
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
          Body: expect.stringMatching(
            /Current message:\n<media:document>[\s\S]*Current media\/attachments:\ndocument attachment \(spec\.pdf\): https:\/\/cdn\.inline\.chat\/spec\.pdf/,
          ),
          RawBody: "<media:document>",
          CommandBody: "<media:document>",
          MediaPath: "/tmp/spec.pdf",
          MediaType: "application/pdf",
          MediaUrl: "/tmp/spec.pdf",
          MediaPaths: ["/tmp/spec.pdf"],
          MediaUrls: ["/tmp/spec.pdf"],
          MediaTypes: ["application/pdf"],
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
          Body: expect.stringMatching(
            /Current message:\n<media:image>[\s\S]*Current media\/attachments:\nimage attachment: https:\/\/cdn\.inline\.chat\/flattened-photo\.jpg/,
          ),
          RawBody: "<media:image>",
          CommandBody: "<media:image>",
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
                oneofKind: "photo",
                photo: {
                  photo: {
                    id: 901n,
                    sizes: [{ w: 400, h: 300, size: 4567, cdnUrl: "https://cdn.inline.chat/broken-photo.jpg" }],
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
          Body: expect.stringMatching(
            /Current message:\n<media:image>[\s\S]*Current media\/attachments:\nimage attachment: https:\/\/cdn\.inline\.chat\/broken-photo\.jpg/,
          ),
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
          Body: expect.stringMatching(
            /Current message:\n<media:document>[\s\S]*Current media\/attachments:\ndocument attachment \(huge-spec\.pdf\): https:\/\/cdn\.inline\.chat\/huge-spec\.pdf/,
          ),
        }),
      )
    })

    await handle.stop()
  })

  it("includes entity helpers and inline formatting guidance in inbound context", async () => {
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
          Body: expect.stringContaining(
            'Recent message entities:\n#7300 user:52: text link "portal" -> https://example.com/history-portal',
          ),
        }),
      )
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          Body: expect.stringContaining(
            "Inline formatting note: prefer bullet lists over markdown tables. If a table is necessary, render it inside a fenced code block.",
          ),
        }),
      )
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          Body: expect.stringContaining(
            'Current message entities:\nmention "Alice" -> user:99 | text link "docs" -> https://example.com/current-docs',
          ),
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
          GroupSystemPrompt: expect.stringContaining("Do not wrap bare URLs in inline code"),
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
          "88": {
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

  it("routes reaction events on bot messages as inbound context and replies in-thread", async () => {
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
      expect(harness.calls.dispatchReply).toHaveBeenCalled()
      expect(harness.calls.finalizeInboundContext).toHaveBeenCalledWith(
        expect.objectContaining({
          Body: expect.stringContaining("@alice reacted with 🔥 to your message #5000"),
          ReplyToId: "5000",
          MessageSid: "5000",
        }),
      )
      expect(harness.calls.sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 88n,
          text: "noted",
          replyToMsgId: 5000n,
        }),
      )
    })

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

    await new Promise((resolve) => setTimeout(resolve, 80))
    expect(harness.calls.dispatchReply).not.toHaveBeenCalled()
    expect(harness.calls.sendMessage).not.toHaveBeenCalled()

    await handle.stop()
  })
})
