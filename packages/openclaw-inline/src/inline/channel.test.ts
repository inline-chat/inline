import { describe, expect, it, vi } from "vitest"
import type { OpenClawConfig, PluginRuntime } from "openclaw/plugin-sdk"

describe("inline/channel", () => {
  it("declares minimal capabilities (no subthreads/parents)", async () => {
    vi.resetModules()
    const { inlineChannelPlugin } = await import("./channel")

    expect(inlineChannelPlugin.capabilities.chatTypes).toEqual(["direct", "group"])
    expect(inlineChannelPlugin.capabilities.threads).toBe(false)
    expect(inlineChannelPlugin.threading).toBeUndefined()
  })

  it("outbound sendText uses the Inline SDK client (mocked)", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const sendMessage = vi.fn(async () => ({ messageId: null }))
    const close = vi.fn(async () => {})

    vi.doMock("@inline-chat/realtime-sdk", () => ({
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        sendMessage = sendMessage
        close = close
      },
    }))

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

    vi.doMock("@inline-chat/realtime-sdk", () => ({
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        sendMessage = sendMessage
        close = close
      },
    }))

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

  it("pairing notifyApproval supports inline:/user:/raw ids and sends using userId", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const sendMessage = vi.fn(async () => ({ messageId: null }))
    const close = vi.fn(async () => {})

    vi.doMock("@inline-chat/realtime-sdk", () => ({
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        sendMessage = sendMessage
        close = close
      },
    }))

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
