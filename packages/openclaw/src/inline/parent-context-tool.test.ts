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
      if (method === 38) {
        expect(input).toMatchObject({
          oneofKind: "getMessages",
          getMessages: {
            peerId: {
              type: {
                oneofKind: "chat",
                chat: { chatId: 77n },
              },
            },
            messageIds: [20n],
          },
        })
        return {
          oneofKind: "getMessages",
          getMessages: {
            messages: [
              {
                id: 20n,
                fromId: 42n,
                date: 1_700_000_020n,
                message: "@inlinebot can you answer from the discussion above?",
              },
            ],
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
            offsetId: 20n,
            limit: 49,
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
          GET_MESSAGES: 38,
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
        limit: 50,
        includeAnchor: true,
        usedCurrentThreadDefault: true,
        nextBeforeMessageId: "19",
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
        limit: 2,
        includeAnchor: false,
        usedCurrentThreadDefault: false,
        nextBeforeMessageId: "53",
        messages: [
          expect.objectContaining({ id: "53", text: "first parent line", isAnchor: false }),
          expect.objectContaining({ id: "54", text: "second parent line", isAnchor: false }),
        ],
      },
    })
  })
})
