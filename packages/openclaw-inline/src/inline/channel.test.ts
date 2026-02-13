import os from "node:os"
import path from "node:path"
import { describe, expect, it, vi } from "vitest"
import type { OpenClawConfig, PluginRuntime } from "openclaw/plugin-sdk"

function mockRealtimeSdk(overrides: Record<string, unknown>): void {
  vi.doMock("@inline-chat/realtime-sdk", async () => {
    const actual = await vi.importActual<Record<string, unknown>>("@inline-chat/realtime-sdk")
    return {
      ...actual,
      ...overrides,
    }
  })
}

describe("inline/channel", () => {
  it("declares minimal capabilities (no subthreads/parents)", async () => {
    vi.resetModules()
    const { inlineChannelPlugin } = await import("./channel")

    expect(inlineChannelPlugin.capabilities.chatTypes).toEqual(["direct", "group"])
    expect(inlineChannelPlugin.capabilities.media).toBe(true)
    expect(inlineChannelPlugin.capabilities.reactions).toBe(true)
    expect(inlineChannelPlugin.capabilities.reply).toBe(true)
    expect(inlineChannelPlugin.capabilities.threads).toBe(false)
    expect(inlineChannelPlugin.threading).toBeUndefined()
    expect(inlineChannelPlugin.streaming?.blockStreamingCoalesceDefaults).toEqual({
      minChars: 1500,
      idleMs: 1000,
    })
  })

  it("resolves group mention + tool policy from channels.inline.groups", async () => {
    vi.resetModules()
    const { inlineChannelPlugin } = await import("./channel")

    const cfg = {
      channels: {
        inline: {
          requireMention: true,
          groups: {
            "88": {
              requireMention: false,
              tools: { allow: ["message"] },
            },
          },
        },
      },
    } satisfies OpenClawConfig

    const requireMention = inlineChannelPlugin.groups?.resolveRequireMention?.({
      cfg,
      accountId: "default",
      groupId: "88",
    } as any)
    const tools = inlineChannelPlugin.groups?.resolveToolPolicy?.({
      cfg,
      accountId: "default",
      groupId: "88",
      senderId: "42",
    } as any)

    expect(requireMention).toBe(false)
    expect(tools).toEqual({ allow: ["message"] })
  })

  it("defaults group requireMention to false when unset", async () => {
    vi.resetModules()
    const { inlineChannelPlugin } = await import("./channel")

    const requireMention = inlineChannelPlugin.groups?.resolveRequireMention?.({
      cfg: {
        channels: {
          inline: {},
        },
      } as OpenClawConfig,
      accountId: "default",
      groupId: "88",
    } as any)

    expect(requireMention).toBe(false)
  })

  it("exposes inline rpc-backed message actions", async () => {
    vi.resetModules()
    const { inlineChannelPlugin } = await import("./channel")

    const actions = inlineChannelPlugin.actions?.listActions?.({
      cfg: {
        channels: {
          inline: {
            token: "token",
          },
        },
      } as OpenClawConfig,
    }) ?? []

    expect(actions).toContain("read")
    expect(actions).toContain("reply")
    expect(actions).toContain("react")
    expect(actions).toContain("reactions")
    expect(actions).toContain("edit")
    expect(actions).toContain("channel-edit")
    expect(actions).toContain("addParticipant")
  })

  it("outbound sendText uses the Inline SDK client (mocked)", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const sendMessage = vi.fn(async () => ({ messageId: null }))
    const close = vi.fn(async () => {})

    mockRealtimeSdk({
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        sendMessage = sendMessage
        close = close
      },
    })

    // The channel plugin uses getInlineRuntime() for state dir + chunker.
    const runtimeMod = await import("../runtime")
    runtimeMod.setInlineRuntime({
      version: "test",
      state: { resolveStateDir: () => "/tmp" },
      channel: { text: { chunkMarkdownText: (t: string) => [t] } },
    } as unknown as PluginRuntime)

    const { inlineChannelPlugin } = await import("./channel")

    const cfg = {
      channels: {
        inline: {
          token: "token",
          baseUrl: "https://api.inline.chat",
          parseMarkdown: true,
        },
      },
    } satisfies OpenClawConfig

    await inlineChannelPlugin.outbound.sendText?.({
      cfg,
      to: "chat:7",
      text: "hi",
      accountId: "default",
    } as any)

    expect(connect).toHaveBeenCalled()
    expect(sendMessage).toHaveBeenCalledWith(
      expect.objectContaining({ chatId: 7n, text: "hi", parseMarkdown: true }),
    )
    expect(close).toHaveBeenCalled()
  })

  it("outbound uses replyToId (not threadId) for Inline replyToMsgId", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const sendMessage = vi.fn(async () => ({ messageId: null }))
    const close = vi.fn(async () => {})

    mockRealtimeSdk({
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        sendMessage = sendMessage
        close = close
      },
    })

    const runtimeMod = await import("../runtime")
    runtimeMod.setInlineRuntime({
      version: "test",
      state: { resolveStateDir: () => "/tmp" },
      channel: { text: { chunkMarkdownText: (t: string) => [t] } },
    } as unknown as PluginRuntime)

    const { inlineChannelPlugin } = await import("./channel")

    const cfg = {
      channels: {
        inline: {
          token: "token",
          baseUrl: "https://api.inline.chat",
          parseMarkdown: true,
        },
      },
    } satisfies OpenClawConfig

    await inlineChannelPlugin.outbound.sendText?.({
      cfg,
      to: "chat:7",
      text: "hi",
      accountId: "default",
      threadId: "42",
    } as any)

    expect(sendMessage).toHaveBeenCalledWith(
      expect.objectContaining({ chatId: 7n, text: "hi" }),
    )
    expect(sendMessage).not.toHaveBeenCalledWith(
      expect.objectContaining({ replyToMsgId: 42n }),
    )

    await inlineChannelPlugin.outbound.sendText?.({
      cfg,
      to: "chat:7",
      text: "hi",
      accountId: "default",
      replyToId: "99",
      threadId: "42",
    } as any)

    expect(sendMessage).toHaveBeenCalledWith(
      expect.objectContaining({ chatId: 7n, text: "hi", replyToMsgId: 99n }),
    )

    expect(connect).toHaveBeenCalled()
    expect(close).toHaveBeenCalled()
  })

  it("outbound sendMedia uploads and sends Inline media", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const uploadFile = vi.fn(async () => ({ fileUniqueId: "INP_1", photoId: 101n }))
    const sendMessage = vi.fn(async () => ({ messageId: 55n }))
    const close = vi.fn(async () => {})

    mockRealtimeSdk({
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        uploadFile = uploadFile
        sendMessage = sendMessage
        close = close
      },
    })

    vi.doMock("openclaw/plugin-sdk", async () => {
      const actual = await vi.importActual<Record<string, unknown>>("openclaw/plugin-sdk")
      return {
        ...actual,
        loadWebMedia: vi.fn(async () => ({
          buffer: Buffer.from([1, 2, 3]),
          contentType: "image/png",
          kind: "image",
          fileName: "image.png",
        })),
        detectMime: vi.fn(async () => "image/png"),
      }
    })

    const runtimeMod = await import("../runtime")
    runtimeMod.setInlineRuntime({
      version: "test",
      state: { resolveStateDir: () => "/tmp" },
      channel: { text: { chunkMarkdownText: (t: string) => [t] } },
    } as unknown as PluginRuntime)

    const { inlineChannelPlugin } = await import("./channel")

    const cfg = {
      channels: {
        inline: {
          token: "token",
          baseUrl: "https://api.inline.chat",
          parseMarkdown: true,
        },
      },
    } satisfies OpenClawConfig

    await inlineChannelPlugin.outbound.sendMedia?.({
      cfg,
      to: "chat:7",
      text: "caption",
      mediaUrl: "https://example.com/image.png",
      accountId: "default",
      replyToId: "9",
    } as any)

    expect(uploadFile).toHaveBeenCalledWith(
      expect.objectContaining({
        type: "photo",
      }),
    )
    expect(sendMessage).toHaveBeenCalledWith(
      expect.objectContaining({
        chatId: 7n,
        text: "caption",
        replyToMsgId: 9n,
        media: {
          kind: "photo",
          photoId: 101n,
        },
        parseMarkdown: true,
      }),
    )
    expect(close).toHaveBeenCalled()
  })

  it("outbound sendMedia falls back to loadWebMedia kind when mime/ext are missing", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const uploadFile = vi.fn(async () => ({ fileUniqueId: "INP_1", photoId: 101n }))
    const sendMessage = vi.fn(async () => ({ messageId: 55n }))
    const close = vi.fn(async () => {})

    mockRealtimeSdk({
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        uploadFile = uploadFile
        sendMessage = sendMessage
        close = close
      },
    })

    vi.doMock("openclaw/plugin-sdk", async () => {
      const actual = await vi.importActual<Record<string, unknown>>("openclaw/plugin-sdk")
      return {
        ...actual,
        loadWebMedia: vi.fn(async () => ({
          buffer: Buffer.from([1, 2, 3]),
          contentType: undefined,
          kind: "image",
          fileName: undefined,
        })),
        detectMime: vi.fn(async () => undefined),
      }
    })

    const runtimeMod = await import("../runtime")
    runtimeMod.setInlineRuntime({
      version: "test",
      state: { resolveStateDir: () => "/tmp" },
      channel: { text: { chunkMarkdownText: (t: string) => [t] } },
    } as unknown as PluginRuntime)

    const { inlineChannelPlugin } = await import("./channel")

    const cfg = {
      channels: {
        inline: {
          token: "token",
          baseUrl: "https://api.inline.chat",
        },
      },
    } satisfies OpenClawConfig

    await inlineChannelPlugin.outbound.sendMedia?.({
      cfg,
      to: "chat:7",
      text: "caption",
      mediaUrl: "https://example.com/no-meta",
      accountId: "default",
    } as any)

    expect(uploadFile).toHaveBeenCalledWith(
      expect.objectContaining({
        type: "photo",
      }),
    )
    expect(sendMessage).toHaveBeenCalledWith(
      expect.objectContaining({
        chatId: 7n,
        media: {
          kind: "photo",
          photoId: 101n,
        },
      }),
    )
    expect(close).toHaveBeenCalled()
  })

  it("outbound sendMedia retries blocked local media paths with localRoots:any", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const uploadFile = vi.fn(async () => ({ fileUniqueId: "INP_1", photoId: 101n }))
    const sendMessage = vi.fn(async () => ({ messageId: 55n }))
    const close = vi.fn(async () => {})
    const loadWebMedia = vi.fn(async (...args: unknown[]) => {
      if (args.length < 3) {
        throw new Error("Local media path is not under an allowed directory: /tmp/latest-download.jpeg")
      }
      return {
        buffer: Buffer.from([1, 2, 3]),
        contentType: "image/jpeg",
        kind: "image",
        fileName: "latest-download.jpeg",
      }
    })

    mockRealtimeSdk({
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        uploadFile = uploadFile
        sendMessage = sendMessage
        close = close
      },
    })

    vi.doMock("openclaw/plugin-sdk", async () => {
      const actual = await vi.importActual<Record<string, unknown>>("openclaw/plugin-sdk")
      return {
        ...actual,
        loadWebMedia,
        detectMime: vi.fn(async () => "image/jpeg"),
      }
    })

    const runtimeMod = await import("../runtime")
    runtimeMod.setInlineRuntime({
      version: "test",
      state: { resolveStateDir: () => "/tmp" },
      channel: { text: { chunkMarkdownText: (t: string) => [t] } },
    } as unknown as PluginRuntime)

    const { inlineChannelPlugin } = await import("./channel")

    const mediaPath = path.join(os.homedir(), ".openclaw", "workspace", "tmp", "latest-download.jpeg")

    const cfg = {
      channels: {
        inline: {
          token: "token",
          baseUrl: "https://api.inline.chat",
        },
      },
    } satisfies OpenClawConfig

    await inlineChannelPlugin.outbound.sendMedia?.({
      cfg,
      to: "chat:7",
      text: "caption",
      mediaUrl: mediaPath,
      accountId: "default",
    } as any)

    expect(loadWebMedia).toHaveBeenNthCalledWith(
      1,
      mediaPath,
      expect.any(Number),
    )
    expect(loadWebMedia).toHaveBeenNthCalledWith(
      2,
      mediaPath,
      expect.any(Number),
      expect.objectContaining({ localRoots: "any" }),
    )
    expect(uploadFile).toHaveBeenCalledWith(
      expect.objectContaining({
        type: "photo",
      }),
    )
    expect(sendMessage).toHaveBeenCalled()
    expect(close).toHaveBeenCalled()
  })

  it("outbound sendPayload sends multi-media replies and threads only first payload", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const uploadFile = vi.fn(async () => ({ fileUniqueId: "INP_1", photoId: 101n }))
    const sendMessage = vi.fn(async () => ({ messageId: 55n }))
    const close = vi.fn(async () => {})

    mockRealtimeSdk({
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        uploadFile = uploadFile
        sendMessage = sendMessage
        close = close
      },
    })

    vi.doMock("openclaw/plugin-sdk", async () => {
      const actual = await vi.importActual<Record<string, unknown>>("openclaw/plugin-sdk")
      return {
        ...actual,
        loadWebMedia: vi.fn(async () => ({
          buffer: Buffer.from([1, 2, 3]),
          contentType: "image/png",
          kind: "image",
          fileName: "image.png",
        })),
        detectMime: vi.fn(async () => "image/png"),
      }
    })

    const runtimeMod = await import("../runtime")
    runtimeMod.setInlineRuntime({
      version: "test",
      state: { resolveStateDir: () => "/tmp" },
      channel: { text: { chunkMarkdownText: (t: string) => [t] } },
    } as unknown as PluginRuntime)

    const { inlineChannelPlugin } = await import("./channel")

    const cfg = {
      channels: {
        inline: {
          token: "token",
          baseUrl: "https://api.inline.chat",
          parseMarkdown: true,
        },
      },
    } satisfies OpenClawConfig

    await inlineChannelPlugin.outbound.sendPayload?.({
      cfg,
      to: "chat:7",
      payload: {
        text: "caption",
        mediaUrls: ["https://example.com/1.png", "https://example.com/2.png"],
      },
      replyToId: "9",
      accountId: "default",
    } as any)

    expect(sendMessage).toHaveBeenNthCalledWith(
      1,
      expect.objectContaining({
        chatId: 7n,
        text: "caption",
        replyToMsgId: 9n,
        parseMarkdown: true,
      }),
    )
    expect(sendMessage).toHaveBeenNthCalledWith(
      2,
      expect.objectContaining({
        chatId: 7n,
      }),
    )
    const secondCall = sendMessage.mock.calls[1]?.[0]
    expect(secondCall?.replyToMsgId).toBeUndefined()
    expect(secondCall?.parseMarkdown).toBeUndefined()
  })

  it("directory and resolver use inline getChats/getChatParticipants", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const close = vi.fn(async () => {})
    const invokeRaw = vi.fn(async (method: number) => {
      if (method === 1) {
        return {
          oneofKind: "getMe",
          getMe: {
            user: { id: 777n, firstName: "Inline", username: "inline-bot" },
          },
        }
      }
      if (method === 17) {
        return {
          oneofKind: "getChats",
          getChats: {
            chats: [
              {
                id: 7n,
                title: "General",
                peerId: { type: { oneofKind: "chat", chat: { chatId: 7n } } },
              },
            ],
            dialogs: [{ chatId: 7n, unreadCount: 2 }],
            users: [{ id: 42n, firstName: "Mo", username: "morajabi" }],
            spaces: [],
            messages: [],
          },
        }
      }
      if (method === 13) {
        return {
          oneofKind: "getChatParticipants",
          getChatParticipants: {
            participants: [{ userId: 42n, date: 1_700_000_000n }],
            users: [{ id: 42n, firstName: "Mo", username: "morajabi" }],
          },
        }
      }
      throw new Error(`unexpected method ${String(method)}`)
    })

    mockRealtimeSdk({
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        close = close
        invokeRaw = invokeRaw
      },
    })

    const runtimeMod = await import("../runtime")
    runtimeMod.setInlineRuntime({
      version: "test",
      state: { resolveStateDir: () => "/tmp" },
      channel: { text: { chunkMarkdownText: (t: string) => [t] } },
    } as unknown as PluginRuntime)

    const { inlineChannelPlugin } = await import("./channel")

    const cfg = {
      channels: {
        inline: {
          token: "token",
          baseUrl: "https://api.inline.chat",
        },
      },
    } satisfies OpenClawConfig

    const self = await inlineChannelPlugin.directory?.self?.({
      cfg,
      accountId: "default",
      runtime: {} as any,
    } as any)
    expect(self?.id).toBe("777")

    const peers = await inlineChannelPlugin.directory?.listPeers?.({
      cfg,
      accountId: "default",
      query: "mor",
      limit: 10,
      runtime: {} as any,
    } as any)
    expect(peers?.[0]?.id).toBe("42")

    const groups = await inlineChannelPlugin.directory?.listGroups?.({
      cfg,
      accountId: "default",
      query: "gene",
      limit: 10,
      runtime: {} as any,
    } as any)
    expect(groups?.[0]?.id).toBe("7")

    const members = await inlineChannelPlugin.directory?.listGroupMembers?.({
      cfg,
      accountId: "default",
      groupId: "7",
      limit: 10,
      runtime: {} as any,
    } as any)
    expect(members?.[0]?.id).toBe("42")

    const resolvedUser = await inlineChannelPlugin.resolver?.resolveTargets?.({
      cfg,
      accountId: "default",
      inputs: ["@morajabi"],
      kind: "user",
      runtime: {} as any,
    } as any)
    expect(resolvedUser?.[0]).toEqual(
      expect.objectContaining({
        resolved: true,
        id: "42",
      }),
    )

    const resolvedGroup = await inlineChannelPlugin.resolver?.resolveTargets?.({
      cfg,
      accountId: "default",
      inputs: ["General"],
      kind: "group",
      runtime: {} as any,
    } as any)
    expect(resolvedGroup?.[0]).toEqual(
      expect.objectContaining({
        resolved: true,
        id: "7",
      }),
    )

    expect(invokeRaw).toHaveBeenCalledWith(
      17,
      expect.objectContaining({ oneofKind: "getChats" }),
    )
    expect(invokeRaw).toHaveBeenCalledWith(
      13,
      expect.objectContaining({ oneofKind: "getChatParticipants" }),
    )
  })

  it("pairing notifyApproval supports inline:/user:/raw ids and sends using userId", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const sendMessage = vi.fn(async () => ({ messageId: null }))
    const close = vi.fn(async () => {})

    mockRealtimeSdk({
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        sendMessage = sendMessage
        close = close
      },
    })

    const runtimeMod = await import("../runtime")
    runtimeMod.setInlineRuntime({
      version: "test",
      state: { resolveStateDir: () => "/tmp" },
      channel: { text: { chunkMarkdownText: (t: string) => [t] } },
    } as unknown as PluginRuntime)

    const { inlineChannelPlugin } = await import("./channel")

    const cfg = {
      channels: {
        inline: {
          token: "token",
          baseUrl: "https://api.inline.chat",
        },
      },
    } satisfies OpenClawConfig

    await inlineChannelPlugin.pairing?.notifyApproval?.({ cfg, id: "inline:42" } as any)
    await inlineChannelPlugin.pairing?.notifyApproval?.({ cfg, id: "user:42" } as any)
    await inlineChannelPlugin.pairing?.notifyApproval?.({ cfg, id: "42" } as any)

    expect(sendMessage).toHaveBeenNthCalledWith(
      1,
      expect.objectContaining({ userId: 42n, text: expect.any(String) }),
    )
    expect(sendMessage).toHaveBeenNthCalledWith(
      2,
      expect.objectContaining({ userId: 42n, text: expect.any(String) }),
    )
    expect(sendMessage).toHaveBeenNthCalledWith(
      3,
      expect.objectContaining({ userId: 42n, text: expect.any(String) }),
    )
    expect(connect).toHaveBeenCalled()
    expect(close).toHaveBeenCalled()
  })
})
