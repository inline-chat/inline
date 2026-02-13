import os from "node:os"
import path from "node:path"
import { describe, expect, it, vi } from "vitest"

type MonitorHarness = {
  monitorInlineProvider: typeof import("./monitor")["monitorInlineProvider"]
  calls: {
    sendMessage: ReturnType<typeof vi.fn>
    uploadFile: ReturnType<typeof vi.fn>
    resolveAgentRoute: ReturnType<typeof vi.fn>
    recordInboundSession: ReturnType<typeof vi.fn>
    finalizeInboundContext: ReturnType<typeof vi.fn>
    dispatchReply: ReturnType<typeof vi.fn>
    upsertPairingRequest: ReturnType<typeof vi.fn>
    buildPairingReply: ReturnType<typeof vi.fn>
    readAllowFromStore: ReturnType<typeof vi.fn>
  }
}

type MonitorSetup = {
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
  >
  chats: Record<string, { kind: "direct" | "group"; title?: string }>
  participants?: Record<string, Array<{ id: bigint; username?: string; firstName?: string; lastName?: string }>>
  historyByChat?: Record<string, Array<{
    id: bigint
    date: bigint
    fromId: bigint
    message?: string
    out?: boolean
    replyToMsgId?: bigint
  }>>
  dispatchReplyPayload?: { text?: string; replyToId?: string; mediaUrl?: string; mediaUrls?: string[] }
}

function buildAccount(overrides?: {
  dmPolicy?: "pairing" | "allowlist" | "open" | "disabled"
  groupPolicy?: "allowlist" | "open" | "disabled"
  allowFrom?: string[]
  groupAllowFrom?: string[]
  requireMention?: boolean
  replyToBotWithoutMention?: boolean
  historyLimit?: number
  dmHistoryLimit?: number
  parseMarkdown?: boolean
  blockStreaming?: boolean
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
      requireMention: overrides?.requireMention ?? true,
      replyToBotWithoutMention: overrides?.replyToBotWithoutMention,
      historyLimit: overrides?.historyLimit,
      dmHistoryLimit: overrides?.dmHistoryLimit,
      parseMarkdown: overrides?.parseMarkdown ?? true,
      blockStreaming: overrides?.blockStreaming,
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

  const sendMessage = vi.fn(async () => ({ messageId: 1n }))
  const uploadFile = vi.fn(async () => ({ fileUniqueId: "INP_1", photoId: 200n }))
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
  const dispatchReply = vi.fn(async ({ dispatcherOptions }: any) => {
    if (!setup.dispatchReplyPayload) return
    await dispatcherOptions.deliver(setup.dispatchReplyPayload)
  })
  const upsertPairingRequest = vi.fn(async () => ({ code: "PAIR-123", created: true }))
  const buildPairingReply = vi.fn(() => "PAIRING_REPLY")
  const readAllowFromStore = vi.fn(async () => [])

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
        GET_CHAT_HISTORY: 5,
        GET_CHAT_PARTICIPANTS: 13,
      },
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = vi.fn(async () => {})
        getMe = vi.fn(async () => ({ userId: 777n }))
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
          }
        })
        sendMessage = sendMessage
        uploadFile = uploadFile
        sendTyping = vi.fn(async () => {})
        invokeRaw = vi.fn(async (
          method: number,
          input: {
            oneofKind?: string
            getChatParticipants?: { chatId?: bigint }
            getChatHistory?: { peerId?: { type?: { oneofKind?: string; chat?: { chatId?: bigint } } } }
          },
        ) => {
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
          return { oneofKind: undefined }
        })
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
      resolveMentionGatingWithBypass: vi.fn((params: any) => ({
        shouldSkip: Boolean(
          params.isGroup &&
          params.requireMention &&
          !params.wasMentioned &&
          !params.implicitMention,
        ),
        effectiveWasMentioned: Boolean(params.wasMentioned || params.implicitMention),
      })),
    }
  })

  const runtimeMod = await import("../runtime")
  runtimeMod.setInlineRuntime({
    version: "test",
    state: {
      resolveStateDir: () => path.join(os.tmpdir(), "openclaw-inline-tests"),
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
      text: {
        hasControlCommand: () => false,
      },
      routing: {
        resolveAgentRoute,
      },
      mentions: {
        buildMentionRegexes: () => [],
        matchesMentionPatterns: () => false,
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
      uploadFile,
      resolveAgentRoute,
      recordInboundSession,
      finalizeInboundContext,
      dispatchReply,
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
