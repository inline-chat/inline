import { describe, expect, it, vi } from "vitest"
import type { OpenClawConfig } from "openclaw/plugin-sdk"

describe("inline/parent-context-tool", () => {
  it("fetches parent chat context for the current Inline reply-thread session", async () => {
    vi.resetModules()

    const invokeRaw = vi.fn(async (method: number, input: any) => {
      if (method === 25) {
        return {
          oneofKind: "getChat",
          getChat: {
            chat: {
              id: 88n,
              title: "Re: launch plan",
              parentChatId: 77n,
              parentMessageId: 20n,
            },
          },
        }
      }
      if (method === 5) {
        expect(input).toMatchObject({
          oneofKind: "getChatHistory",
          getChatHistory: {
            peerId: {
              type: {
                oneofKind: "chat",
                chat: { chatId: 77n },
              },
            },
            mode: 4,
            anchorId: 20n,
            beforeLimit: 49,
            afterLimit: 0,
            includeAnchor: true,
            limit: 50,
          },
        })
        return {
          oneofKind: "getChatHistory",
          getChatHistory: {
            messages: [
              {
                id: 20n,
                fromId: 42n,
                date: 1_700_000_020n,
                message: "@inlinebot can you answer from the discussion above?",
              },
              {
                id: 19n,
                fromId: 41n,
                date: 1_700_000_019n,
                message: "we should ship after qa signs off",
              },
            ],
          },
        }
      }
      throw new Error(`unexpected method ${String(method)}`)
    })

    vi.doMock("@inline-chat/realtime-sdk", async () => {
      const actual = await vi.importActual<Record<string, unknown>>("@inline-chat/realtime-sdk")
      return {
        ...actual,
        Method: {
          GET_CHAT: 25,
          GET_CHAT_HISTORY: 5,
        },
        InlineSdkClient: class {
          constructor(_opts: unknown) {}
          connect = vi.fn(async () => {})
          close = vi.fn(async () => {})
          invokeRaw = invokeRaw
        },
      }
    })

    const { createInlineParentContextTool } = await import("./parent-context-tool")
    const tool = createInlineParentContextTool({
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
      sessionKey: "agent:main:inline:group:77:thread:88",
    })

    expect(tool).toBeDefined()
    const result = await tool?.execute("tool-parent", {})

    expect(result).toMatchObject({
      details: {
        ok: true,
        accountId: "default",
        parentChatId: "77",
        threadId: "88",
        threadTitle: "Re: launch plan",
        parentMessageId: "20",
        mode: "around",
        aroundMessageId: "20",
        beforeLimit: 49,
        afterLimit: 0,
        limit: 50,
        includeAnchor: true,
        usedCurrentThreadDefault: true,
        nextBeforeMessageId: "19",
        nextAfterMessageId: "20",
        messages: [
          expect.objectContaining({
            id: "19",
            text: "we should ship after qa signs off",
            isAnchor: false,
          }),
          expect.objectContaining({
            id: "20",
            text: "@inlinebot can you answer from the discussion above?",
            isAnchor: true,
          }),
        ],
      },
    })
  })

  it("fetches explicit around-message windows and marks the requested anchor", async () => {
    vi.resetModules()

    const invokeRaw = vi.fn(async (method: number, input: any) => {
      if (method === 25) {
        return {
          oneofKind: "getChat",
          getChat: {
            chat: {
              id: 88n,
              title: "Re: reused id",
              parentChatId: 77n,
              parentMessageId: 20n,
            },
          },
        }
      }
      if (method === 5) {
        expect(input).toMatchObject({
          oneofKind: "getChatHistory",
          getChatHistory: {
            peerId: {
              type: {
                oneofKind: "chat",
                chat: { chatId: 77n },
              },
            },
            mode: 4,
            anchorId: 18n,
            beforeLimit: 1,
            afterLimit: 1,
            includeAnchor: true,
            limit: 50,
          },
        })
        return {
          oneofKind: "getChatHistory",
          getChatHistory: {
            messages: [
              {
                id: 19n,
                fromId: 41n,
                date: 1_700_000_019n,
                message: "follow-up after the question",
              },
              {
                id: 18n,
                fromId: 42n,
                date: 1_700_000_018n,
                message: "the question to inspect",
              },
              {
                id: 17n,
                fromId: 41n,
                date: 1_700_000_017n,
                message: "setup before the question",
              },
            ],
          },
        }
      }
      throw new Error(`unexpected method ${String(method)}`)
    })

    vi.doMock("@inline-chat/realtime-sdk", async () => {
      const actual = await vi.importActual<Record<string, unknown>>("@inline-chat/realtime-sdk")
      return {
        ...actual,
        Method: {
          GET_CHAT: 25,
          GET_CHAT_HISTORY: 5,
        },
        InlineSdkClient: class {
          constructor(_opts: unknown) {}
          connect = vi.fn(async () => {})
          close = vi.fn(async () => {})
          invokeRaw = invokeRaw
        },
      }
    })

    const { createInlineParentContextTool } = await import("./parent-context-tool")
    const tool = createInlineParentContextTool({
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
      sessionKey: "agent:main:inline:group:77:thread:88",
    })

    const result = await tool?.execute("tool-parent", {
      messageId: "18",
      beforeLimit: 1,
      afterLimit: 1,
    })

    expect(result).toMatchObject({
      details: {
        parentMessageId: "20",
        mode: "around",
        aroundMessageId: "18",
        beforeLimit: 1,
        afterLimit: 1,
        nextBeforeMessageId: "17",
        nextAfterMessageId: "19",
        messages: [
          expect.objectContaining({ id: "17", text: "setup before the question", isAnchor: false }),
          expect.objectContaining({ id: "18", text: "the question to inspect", isAnchor: true }),
          expect.objectContaining({ id: "19", text: "follow-up after the question", isAnchor: false }),
        ],
      },
    })
  })

  it("accepts chat-prefixed parent targets for explicit parent history lookup", async () => {
    vi.resetModules()

    const invokeRaw = vi.fn(async (method: number, input: any) => {
      if (method !== 5) {
        throw new Error(`unexpected method ${String(method)}`)
      }
      expect(input).toMatchObject({
        oneofKind: "getChatHistory",
        getChatHistory: {
          peerId: {
            type: {
              oneofKind: "chat",
              chat: { chatId: 77n },
            },
          },
          mode: 2,
          beforeId: 55n,
          offsetId: 55n,
          limit: 2,
        },
      })
      return {
        oneofKind: "getChatHistory",
        getChatHistory: {
          messages: [
            {
              id: 54n,
              fromId: 41n,
              date: 1_700_000_054n,
              message: "second parent line",
            },
            {
              id: 53n,
              fromId: 42n,
              date: 1_700_000_053n,
              message: "first parent line",
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
          GET_CHAT_HISTORY: 5,
        },
        InlineSdkClient: class {
          constructor(_opts: unknown) {}
          connect = vi.fn(async () => {})
          close = vi.fn(async () => {})
          invokeRaw = invokeRaw
        },
      }
    })

    const { createInlineParentContextTool } = await import("./parent-context-tool")
    const tool = createInlineParentContextTool({
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
      sessionKey: "agent:main:inline:group:77",
    })

    const result = await tool?.execute("tool-parent", {
      parentChatId: "chat:77",
      beforeMessageId: "55",
      limit: 2,
      includeAnchor: false,
    })

    expect(invokeRaw).toHaveBeenCalledTimes(1)
    expect(result).toMatchObject({
      details: {
        ok: true,
        parentChatId: "77",
        parentMessageId: null,
        mode: "older",
        beforeMessageId: "55",
        limit: 2,
        includeAnchor: false,
        usedCurrentThreadDefault: false,
        nextBeforeMessageId: "53",
        nextAfterMessageId: "54",
        messages: [
          expect.objectContaining({ id: "53", text: "first parent line", isAnchor: false }),
          expect.objectContaining({ id: "54", text: "second parent line", isAnchor: false }),
        ],
      },
    })
  })

  it("fetches newer parent-chat context after a message id", async () => {
    vi.resetModules()

    const invokeRaw = vi.fn(async (method: number, input: any) => {
      if (method !== 5) {
        throw new Error(`unexpected method ${String(method)}`)
      }
      expect(input).toMatchObject({
        oneofKind: "getChatHistory",
        getChatHistory: {
          peerId: {
            type: {
              oneofKind: "chat",
              chat: { chatId: 77n },
            },
          },
          mode: 3,
          afterId: 55n,
          limit: 2,
        },
      })
      return {
        oneofKind: "getChatHistory",
        getChatHistory: {
          messages: [
            {
              id: 57n,
              fromId: 41n,
              date: 1_700_000_057n,
              message: "newest parent line",
            },
            {
              id: 56n,
              fromId: 42n,
              date: 1_700_000_056n,
              message: "newer parent line",
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
          GET_CHAT_HISTORY: 5,
        },
        InlineSdkClient: class {
          constructor(_opts: unknown) {}
          connect = vi.fn(async () => {})
          close = vi.fn(async () => {})
          invokeRaw = invokeRaw
        },
      }
    })

    const { createInlineParentContextTool } = await import("./parent-context-tool")
    const tool = createInlineParentContextTool({
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
      sessionKey: "agent:main:inline:group:77",
    })

    const result = await tool?.execute("tool-parent", {
      parentChatId: "chat:77",
      afterMessageId: "55",
      limit: 2,
    })

    expect(invokeRaw).toHaveBeenCalledTimes(1)
    expect(result).toMatchObject({
      details: {
        ok: true,
        parentChatId: "77",
        parentMessageId: null,
        mode: "newer",
        afterMessageId: "55",
        limit: 2,
        nextBeforeMessageId: "56",
        nextAfterMessageId: "57",
        messages: [
          expect.objectContaining({ id: "56", text: "newer parent line", isAnchor: false }),
          expect.objectContaining({ id: "57", text: "newest parent line", isAnchor: false }),
        ],
      },
    })
  })
})
