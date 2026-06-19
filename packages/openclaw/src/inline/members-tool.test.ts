import { describe, expect, it, vi } from "vitest"
import type { OpenClawConfig } from "openclaw/plugin-sdk"

describe("inline/members-tool", () => {
  it("lists filtered space members with explicit dm targets", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const close = vi.fn(async () => {})
    const invokeRaw = vi.fn(async (method: number) => {
      if (method === 10) {
        return {
          oneofKind: "getSpaceMembers",
          getSpaceMembers: {
            members: [
              {
                id: 1n,
                spaceId: 22n,
                userId: 99n,
                role: 2,
                date: 1_700_000_002n,
                canAccessPublicChats: true,
              },
              {
                id: 2n,
                spaceId: 22n,
                userId: 100n,
                role: 1,
                date: 1_700_000_003n,
                canAccessPublicChats: true,
              },
            ],
            users: [
              { id: 99n, username: "new-user", firstName: "New" },
              { id: 100n, username: "other-user", firstName: "Other" },
            ],
          },
        }
      }
      throw new Error(`unexpected method ${String(method)}`)
    })

    vi.doMock("@inline-chat/realtime-sdk", () => ({
      Member_Role: {
        OWNER: 0,
        ADMIN: 1,
        MEMBER: 2,
      },
      Method: {
        GET_SPACE_MEMBERS: 10,
      },
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        close = close
        invokeRaw = invokeRaw
      },
    }))

    const { createInlineMembersTool } = await import("./members-tool")

    const tool = createInlineMembersTool({
      config: {
        channels: {
          inline: {
            token: "token",
            baseUrl: "https://api.inline.chat",
          },
        },
      } satisfies OpenClawConfig,
      agentAccountId: "default",
    })

    expect(tool).not.toBeNull()

    const result = await tool?.execute("tool-1", {
      spaceId: "22",
      query: "new",
    })

    expect(result).toMatchObject({
      details: {
        ok: true,
        spaceId: "22",
        query: "new",
        count: 1,
        members: [
          {
            userId: "99",
            target: "user:99",
            role: "member",
            user: {
              id: "99",
              username: "new-user",
            },
          },
        ],
      },
    })
    expect(connect).toHaveBeenCalled()
    expect(close).toHaveBeenCalled()
  })

  it("infers the space id from the current Inline chat", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const close = vi.fn(async () => {})
    const invokeRaw = vi.fn(async (method: number) => {
      if (method === 25) {
        return {
          oneofKind: "getChat",
          getChat: {
            chat: { id: 77n, title: "Ops", spaceId: 22n },
            dialog: { chatId: 77n, spaceId: 22n },
          },
        }
      }
      if (method === 10) {
        return {
          oneofKind: "getSpaceMembers",
          getSpaceMembers: {
            members: [
              {
                id: 1n,
                spaceId: 22n,
                userId: 99n,
                role: 2,
                date: 1_700_000_002n,
                canAccessPublicChats: true,
              },
            ],
            users: [{ id: 99n, username: "new-user", firstName: "New" }],
          },
        }
      }
      throw new Error(`unexpected method ${String(method)}`)
    })

    vi.doMock("@inline-chat/realtime-sdk", () => ({
      Member_Role: {
        OWNER: 0,
        ADMIN: 1,
        MEMBER: 2,
      },
      Method: {
        GET_SPACE_MEMBERS: 10,
        GET_CHAT: 25,
      },
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        close = close
        invokeRaw = invokeRaw
      },
    }))

    const { createInlineMembersTool } = await import("./members-tool")

    const tool = createInlineMembersTool({
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

    const result = await tool?.execute("tool-1", {
      query: "new",
    })

    expect(result).toMatchObject({
      details: {
        ok: true,
        spaceId: "22",
        inferredSpaceId: true,
        spaceIdSource: "current-chat",
        sourceChatId: "77",
        query: "new",
        count: 1,
        members: [
          {
            userId: "99",
            target: "user:99",
            user: {
              username: "new-user",
            },
          },
        ],
      },
    })
    expect(invokeRaw).toHaveBeenCalledWith(
      25,
      expect.objectContaining({
        oneofKind: "getChat",
        getChat: {
          peerId: {
            type: {
              oneofKind: "chat",
              chat: { chatId: 77n },
            },
          },
        },
      }),
    )
  })
})
