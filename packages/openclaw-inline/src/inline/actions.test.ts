import { describe, expect, it, vi } from "vitest"
import type { OpenClawConfig } from "openclaw/plugin-sdk"

describe("inline/actions", () => {
  it("lists gated actions only when inline is configured", async () => {
    vi.resetModules()
    const { inlineMessageActions } = await import("./actions")

    const unconfigured = inlineMessageActions.listActions?.({ cfg: {} as OpenClawConfig }) ?? []
    expect(unconfigured).toEqual([])

    const configured =
      inlineMessageActions.listActions?.({
        cfg: {
          channels: {
            inline: {
              token: "token",
              baseUrl: "https://api.inline.chat",
            },
          },
        } as OpenClawConfig,
      }) ?? []

    expect(configured).toContain("reply")
    expect(configured).toContain("thread-reply")
    expect(configured).toContain("channel-list")
    expect(configured).toContain("channel-create")
    expect(configured).toContain("removeParticipant")
    expect(configured).toContain("leaveGroup")
    expect(configured).toContain("delete")
    expect(configured).toContain("pin")
    expect(configured).toContain("permissions")

    const gated =
      inlineMessageActions.listActions?.({
        cfg: {
          channels: {
            inline: {
              token: "token",
              baseUrl: "https://api.inline.chat",
              actions: {
                channels: false,
                participants: false,
                delete: false,
                pins: false,
                permissions: false,
              },
            },
          },
        } as OpenClawConfig,
      }) ?? []

    expect(gated).toContain("reply")
    expect(gated).not.toContain("channel-list")
    expect(gated).not.toContain("removeParticipant")
    expect(gated).not.toContain("delete")
    expect(gated).not.toContain("pin")
    expect(gated).not.toContain("permissions")
  })

  it("dispatches expanded rpc action set via Inline RPC", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const close = vi.fn(async () => {})
    const sendMessage = vi.fn(async () => ({ messageId: 88n }))
    const getMe = vi.fn(async () => ({ userId: 500n, firstName: "Inline", username: "inline-bot" }))
    const invokeRaw = vi.fn(async (method: number) => {
      if (method === 4) {
        return { oneofKind: "deleteMessages", deleteMessages: { updates: [] } }
      }
      if (method === 5) {
        return {
          oneofKind: "getChatHistory",
          getChatHistory: {
            messages: [
              {
                id: 10n,
                fromId: 42n,
                date: 1_700_000_000n,
                message: "older",
                out: false,
                reactions: {
                  reactions: [
                    {
                      emoji: "🔥",
                      userId: 42n,
                      messageId: 10n,
                      chatId: 7n,
                      date: 1_700_000_001n,
                    },
                  ],
                },
              },
            ],
          },
        }
      }
      if (method === 6) {
        return { oneofKind: "addReaction", addReaction: { updates: [] } }
      }
      if (method === 7) {
        return { oneofKind: "deleteReaction", deleteReaction: { updates: [] } }
      }
      if (method === 8) {
        return { oneofKind: "editMessage", editMessage: { updates: [] } }
      }
      if (method === 9) {
        return {
          oneofKind: "createChat",
          createChat: {
            chat: { id: 71n, title: "New Thread", spaceId: 22n },
            dialog: { chatId: 71n },
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
      if (method === 11) {
        return { oneofKind: "deleteChat", deleteChat: {} }
      }
      if (method === 13) {
        return {
          oneofKind: "getChatParticipants",
          getChatParticipants: {
            participants: [{ userId: 99n, date: 1_700_000_003n }],
            users: [{ id: 99n, username: "new-user", firstName: "New" }],
          },
        }
      }
      if (method === 14) {
        return {
          oneofKind: "addChatParticipant",
          addChatParticipant: { participant: { userId: 99n, date: 1_700_000_003n } },
        }
      }
      if (method === 15) {
        return {
          oneofKind: "removeChatParticipant",
          removeChatParticipant: {},
        }
      }
      if (method === 17) {
        return {
          oneofKind: "getChats",
          getChats: {
            chats: [
              {
                id: 7n,
                title: "Renamed Thread",
                spaceId: 22n,
                isPublic: false,
                peerId: {
                  type: {
                    oneofKind: "user",
                    user: {
                      userId: 99n,
                    },
                  },
                },
              },
            ],
            dialogs: [{ chatId: 7n, unreadCount: 2, archived: false, pinned: true }],
            users: [{ id: 99n, username: "new-user", firstName: "New" }],
            spaces: [],
            messages: [],
          },
        }
      }
      if (method === 25) {
        return {
          oneofKind: "getChat",
          getChat: {
            chat: { id: 7n, title: "Renamed Thread", spaceId: 22n },
            dialog: { chatId: 7n, spaceId: 22n },
            pinnedMessageIds: [11n, 12n],
          },
        }
      }
      if (method === 27) {
        return {
          oneofKind: "updateMemberAccess",
          updateMemberAccess: { updates: [] },
        }
      }
      if (method === 31) {
        return {
          oneofKind: "pinMessage",
          pinMessage: { updates: [] },
        }
      }
      if (method === 32) {
        return {
          oneofKind: "updateChatInfo",
          updateChatInfo: {
            chat: { id: 7n, title: "Renamed Thread" },
          },
        }
      }
      if (method === 35) {
        return {
          oneofKind: "moveThread",
          moveThread: {
            chat: { id: 7n, title: "Renamed Thread", spaceId: 30n },
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
        DELETE_MESSAGES: 4,
        GET_CHAT_HISTORY: 5,
        ADD_REACTION: 6,
        DELETE_REACTION: 7,
        EDIT_MESSAGE: 8,
        CREATE_CHAT: 9,
        GET_SPACE_MEMBERS: 10,
        DELETE_CHAT: 11,
        GET_CHAT_PARTICIPANTS: 13,
        ADD_CHAT_PARTICIPANT: 14,
        REMOVE_CHAT_PARTICIPANT: 15,
        GET_CHATS: 17,
        GET_CHAT: 25,
        UPDATE_MEMBER_ACCESS: 27,
        PIN_MESSAGE: 31,
        UPDATE_CHAT_INFO: 32,
        MOVE_THREAD: 35,
      },
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        close = close
        getMe = getMe
        sendMessage = sendMessage
        invokeRaw = invokeRaw
      },
    }))

    const { inlineMessageActions } = await import("./actions")

    const cfg = {
      channels: {
        inline: {
          token: "token",
          baseUrl: "https://api.inline.chat",
        },
      },
    } satisfies OpenClawConfig

    await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "reply",
      cfg,
      params: { to: "7", messageId: "10", message: "reply body" },
    } as any)

    await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "thread-reply",
      cfg,
      params: { to: "7", messageId: "10", message: "reply body" },
    } as any)

    await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "delete",
      cfg,
      params: { to: "7", messageIds: ["10", "11"] },
    } as any)

    await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "unsend",
      cfg,
      params: { to: "7", messageId: "12" },
    } as any)

    await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "pin",
      cfg,
      params: { to: "7", messageId: "10" },
    } as any)

    await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "unpin",
      cfg,
      params: { to: "7", messageId: "10" },
    } as any)

    await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "list-pins",
      cfg,
      params: { to: "7" },
    } as any)

    await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "channel-list",
      cfg,
      params: { query: "renamed" },
    } as any)

    await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "thread-list",
      cfg,
      params: { query: "renamed" },
    } as any)

    await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "channel-create",
      cfg,
      params: { title: "New Thread", participants: ["99"], spaceId: "22" },
    } as any)

    await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "thread-create",
      cfg,
      params: { title: "New Thread", participants: ["99"], spaceId: "22" },
    } as any)

    await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "channel-delete",
      cfg,
      params: { to: "7" },
    } as any)

    await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "channel-move",
      cfg,
      params: { to: "7", spaceId: "30" },
    } as any)

    await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "addParticipant",
      cfg,
      params: { to: "7", userId: "99" },
    } as any)

    await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "removeParticipant",
      cfg,
      params: { to: "7", userId: "99" },
    } as any)

    await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "leaveGroup",
      cfg,
      params: { to: "7" },
    } as any)

    await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "member-info",
      cfg,
      params: { to: "7", userId: "99" },
    } as any)

    await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "permissions",
      cfg,
      params: { to: "7", userId: "99", role: "member", canAccessPublicChats: true },
    } as any)

    expect(sendMessage).toHaveBeenCalledWith(
      expect.objectContaining({
        chatId: 7n,
        text: "reply body",
        replyToMsgId: 10n,
      }),
    )
    expect(invokeRaw).toHaveBeenCalledWith(
      4,
      expect.objectContaining({
        oneofKind: "deleteMessages",
      }),
    )
    expect(invokeRaw).toHaveBeenCalledWith(
      31,
      expect.objectContaining({
        oneofKind: "pinMessage",
      }),
    )
    expect(invokeRaw).toHaveBeenCalledWith(
      17,
      expect.objectContaining({
        oneofKind: "getChats",
      }),
    )
    expect(invokeRaw).toHaveBeenCalledWith(
      9,
      expect.objectContaining({
        oneofKind: "createChat",
      }),
    )
    expect(invokeRaw).toHaveBeenCalledWith(
      11,
      expect.objectContaining({
        oneofKind: "deleteChat",
      }),
    )
    expect(invokeRaw).toHaveBeenCalledWith(
      35,
      expect.objectContaining({
        oneofKind: "moveThread",
      }),
    )
    expect(invokeRaw).toHaveBeenCalledWith(
      15,
      expect.objectContaining({
        oneofKind: "removeChatParticipant",
      }),
    )
    expect(invokeRaw).toHaveBeenCalledWith(
      27,
      expect.objectContaining({
        oneofKind: "updateMemberAccess",
      }),
    )
    expect(getMe).toHaveBeenCalled()
    expect(connect).toHaveBeenCalled()
    expect(close).toHaveBeenCalled()
  })

  it("rejects disabled actions from config", async () => {
    vi.resetModules()

    vi.doMock("@inline-chat/realtime-sdk", () => ({
      Method: {
        GET_CHAT: 25,
      },
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = vi.fn(async () => {})
        close = vi.fn(async () => {})
        invokeRaw = vi.fn(async () => ({ oneofKind: "getChat", getChat: {} }))
      },
    }))

    const { inlineMessageActions } = await import("./actions")

    const cfg = {
      channels: {
        inline: {
          token: "token",
          baseUrl: "https://api.inline.chat",
          actions: {
            channels: false,
          },
        },
      },
    } satisfies OpenClawConfig

    await expect(
      inlineMessageActions.handleAction?.({
        channel: "inline",
        action: "channel-info",
        cfg,
        params: { to: "7" },
      } as any),
    ).rejects.toThrow(/disabled by channels\.inline\.actions/)
  })
})
