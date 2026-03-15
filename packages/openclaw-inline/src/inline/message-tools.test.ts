import { describe, expect, it, vi } from "vitest"
import type { OpenClawConfig } from "openclaw/plugin-sdk"

describe("inline/message-tools", () => {
  it("nudges the current Inline chat when no target is provided", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const close = vi.fn(async () => {})
    const invokeRaw = vi.fn(async (method: number, input: unknown) => {
      if (method !== 2) {
        throw new Error(`unexpected method ${String(method)}`)
      }
      return {
        oneofKind: "sendMessage",
        sendMessage: {
          updates: [
            {
              update: {
                oneofKind: "newMessage",
                newMessage: {
                  message: { id: 901n },
                },
              },
            },
          ],
        },
      }
    })

    vi.doMock("@inline-chat/realtime-sdk", async () => {
      const actual = await vi.importActual<Record<string, unknown>>("@inline-chat/realtime-sdk")
      return {
        ...actual,
        Method: {
          SEND_MESSAGE: 2,
        },
        InlineSdkClient: class {
          constructor(_opts: unknown) {}
          connect = connect
          close = close
          invokeRaw = invokeRaw
        },
      }
    })

    const { createInlineMessageTools } = await import("./message-tools")

    const tools = createInlineMessageTools({
      config: {
        channels: {
          inline: {
            token: "token",
            baseUrl: "https://api.inline.chat",
          },
        },
      } satisfies OpenClawConfig,
      agentAccountId: "default",
      messageChannel: "inline",
      sessionKey: "agent:main:inline:chat:77",
    })

    const tool = tools.find((item) => item.name === "inline_nudge")
    expect(tool).toBeDefined()

    const result = await tool?.execute("tool-1", {
      message: "ping",
    })

    expect(result).toMatchObject({
      details: {
        ok: true,
        nudged: true,
        target: "77",
        usedCurrentChatDefault: true,
        messageId: "901",
      },
    })
    expect(invokeRaw).toHaveBeenCalledWith(
      2,
      expect.objectContaining({
        oneofKind: "sendMessage",
        sendMessage: expect.objectContaining({
          peerId: {
            type: {
              oneofKind: "chat",
              chat: { chatId: 77n },
            },
          },
          message: "ping",
          media: {
            media: {
              oneofKind: "nudge",
              nudge: {},
            },
          },
        }),
      }),
    )
    expect(connect).toHaveBeenCalled()
    expect(close).toHaveBeenCalled()
  })

  it("forwards messages from an explicit source and defaults destination/account aliases correctly", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const close = vi.fn(async () => {})
    const invokeRaw = vi.fn(async (method: number, input: unknown) => {
      if (method !== 29) {
        throw new Error(`unexpected method ${String(method)}`)
      }
      return {
        oneofKind: "forwardMessages",
        forwardMessages: {
          updates: [
            {
              update: {
                oneofKind: "newMessage",
                newMessage: {
                  message: { id: 902n },
                },
              },
            },
          ],
        },
      }
    })

    vi.doMock("@inline-chat/realtime-sdk", async () => {
      const actual = await vi.importActual<Record<string, unknown>>("@inline-chat/realtime-sdk")
      return {
        ...actual,
        Method: {
          FORWARD_MESSAGES: 29,
        },
        InlineSdkClient: class {
          constructor(_opts: unknown) {}
          connect = connect
          close = close
          invokeRaw = invokeRaw
        },
      }
    })

    const { createInlineMessageTools } = await import("./message-tools")

    const tools = createInlineMessageTools({
      config: {
        channels: {
          inline: {
            token: "token",
            baseUrl: "https://api.inline.chat",
          },
        },
      } satisfies OpenClawConfig,
      agentAccountId: "default",
      messageChannel: "inline",
      sessionKey: "agent:main:inline:chat:77",
    })

    const tool = tools.find((item) => item.name === "inline_forward")
    expect(tool).toBeDefined()

    const result = await tool?.execute("tool-2", {
      to: "user:99",
      from: "chat:55",
      messageIds: ["10", "11"],
      shareForwardHeader: false,
    })

    expect(result).toMatchObject({
      details: {
        ok: true,
        from: "55",
        to: "user:99",
        messageIds: ["10", "11"],
        usedCurrentChatDefault: false,
        forwardedMessageId: "902",
      },
    })
    expect(invokeRaw).toHaveBeenCalledWith(
      29,
      expect.objectContaining({
        oneofKind: "forwardMessages",
        forwardMessages: {
          fromPeerId: {
            type: {
              oneofKind: "chat",
              chat: { chatId: 55n },
            },
          },
          toPeerId: {
            type: {
              oneofKind: "user",
              user: { userId: 99n },
            },
          },
          messageIds: [10n, 11n],
          shareForwardHeader: false,
        },
      }),
    )
    expect(connect).toHaveBeenCalled()
    expect(close).toHaveBeenCalled()
  })

  it("defaults forward source chat from the current Inline session", async () => {
    vi.resetModules()

    const invokeRaw = vi.fn(async () => ({
      oneofKind: "forwardMessages",
      forwardMessages: {
        updates: [],
      },
    }))

    vi.doMock("@inline-chat/realtime-sdk", async () => {
      const actual = await vi.importActual<Record<string, unknown>>("@inline-chat/realtime-sdk")
      return {
        ...actual,
        Method: {
          FORWARD_MESSAGES: 29,
        },
        InlineSdkClient: class {
          constructor(_opts: unknown) {}
          connect = vi.fn(async () => {})
          close = vi.fn(async () => {})
          invokeRaw = invokeRaw
        },
      }
    })

    const { createInlineMessageTools } = await import("./message-tools")

    const tools = createInlineMessageTools({
      config: {
        channels: {
          inline: {
            token: "token",
            baseUrl: "https://api.inline.chat",
          },
        },
      } satisfies OpenClawConfig,
      agentAccountId: "default",
      messageChannel: "inline",
      sessionKey: "agent:main:inline:user:42",
    })

    const tool = tools.find((item) => item.name === "inline_forward")
    expect(tool).toBeDefined()

    const result = await tool?.execute("tool-3", {
      to: "chat:77",
      messageId: "10",
    })

    expect(result).toMatchObject({
      details: {
        ok: true,
        from: "user:42",
        to: "77",
        messageIds: ["10"],
        usedCurrentChatDefault: true,
      },
    })
    expect(invokeRaw).toHaveBeenCalledWith(
      29,
      expect.objectContaining({
        oneofKind: "forwardMessages",
        forwardMessages: expect.objectContaining({
          fromPeerId: {
            type: {
              oneofKind: "user",
              user: { userId: 42n },
            },
          },
          toPeerId: {
            type: {
              oneofKind: "chat",
              chat: { chatId: 77n },
            },
          },
          messageIds: [10n],
        }),
      }),
    )
  })
})
