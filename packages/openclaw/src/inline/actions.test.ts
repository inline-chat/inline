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
    expect(configured).toContain("send")
    expect(configured).toContain("sendAttachment")
    expect(configured).toContain("thread-reply")
    expect(configured).toContain("channel-list")
    expect(configured).toContain("renameGroup")
    expect(configured).toContain("channel-create")
    expect(configured).toContain("removeParticipant")
    expect(configured).toContain("kick")
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
                send: false,
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
    expect(gated).not.toContain("send")
    expect(gated).not.toContain("channel-list")
    expect(gated).not.toContain("removeParticipant")
    expect(gated).not.toContain("delete")
    expect(gated).not.toContain("pin")
    expect(gated).not.toContain("permissions")
  })

  it("lists actions when only a non-default inline account is configured", async () => {
    vi.resetModules()
    const { inlineMessageActions } = await import("./actions")

    const actions =
      inlineMessageActions.listActions?.({
        cfg: {
          channels: {
            inline: {
              accounts: {
                work: {
                  token: "token",
                  baseUrl: "https://api.inline.chat",
                },
              },
            },
          },
        } as OpenClawConfig,
      }) ?? []

    expect(actions).toContain("reply")
    expect(actions).toContain("read")
    expect(actions.length).toBeGreaterThan(0)
  })

  it("unions discovery across configured enabled accounts", async () => {
    vi.resetModules()
    const { inlineMessageActions } = await import("./actions")

    const actions =
      inlineMessageActions.listActions?.({
        cfg: {
          channels: {
            inline: {
              token: "default-token",
              enabled: false,
              accounts: {
                work: {
                  enabled: true,
                  token: "work-token",
                  baseUrl: "https://api.inline.chat",
                },
              },
            },
          },
        } as OpenClawConfig,
      }) ?? []

    expect(actions).toContain("send")
    expect(actions).toContain("read")
    expect(actions.length).toBeGreaterThan(0)
  })

  it("uses the SDK message-tool buttons schema", async () => {
    vi.resetModules()
    const { inlineMessageActions } = await import("./actions")

    const discovery = inlineMessageActions.describeMessageTool?.({
      cfg: {
        channels: {
          inline: {
            token: "token",
            baseUrl: "https://api.inline.chat",
          },
        },
      } as OpenClawConfig,
    })

    const schema = Array.isArray(discovery?.schema) ? discovery.schema[0] : discovery?.schema
    const buttonsSchema = schema?.properties?.buttons as Record<string | symbol, unknown> | undefined

    expect(discovery?.capabilities).toEqual(["interactive", "buttons"])
    expect(buttonsSchema).toBeDefined()
    expect(buttonsSchema?.type).toBe("array")
    expect(buttonsSchema?.description).toBe("Button rows for channels that support button-style actions.")
  })

  it("extracts explicit user targets for send routing", async () => {
    vi.resetModules()
    const { inlineMessageActions } = await import("./actions")

    const extracted = inlineMessageActions.extractToolSend?.({
      args: { action: "sendMessage", to: "inline:user:99" },
    } as any)

    expect(extracted).toEqual({ to: "user:99" })
  })

  it("dispatches expanded rpc action set via Inline RPC", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const close = vi.fn(async () => {})
    const sendMessage = vi.fn(async () => ({ messageId: 88n }))
    const uploadInlineMediaFromUrl = vi.fn(async () => ({ kind: "photo", photoId: 901n }))
    const getMe = vi.fn(async () => ({ userId: 500n, firstName: "Inline", username: "inline-bot" }))
    const sampleMessageWithReaction = {
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
    }
    const invokeRaw = vi.fn(async (method: number) => {
      if (method === 4) {
        return { oneofKind: "deleteMessages", deleteMessages: { updates: [] } }
      }
      if (method === 5) {
        return {
          oneofKind: "getChatHistory",
          getChatHistory: {
            messages: [sampleMessageWithReaction],
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
      if (method === 38) {
        return {
          oneofKind: "getMessages",
          getMessages: {
            messages: [sampleMessageWithReaction],
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
        GET_MESSAGES: 38,
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
    vi.doMock("./media", () => ({
      uploadInlineMediaFromUrl,
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
      action: "send",
      cfg,
      params: { to: "user:99", message: "dm body" },
    } as any)

    await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "send",
      cfg,
      params: { userId: "99", message: "dm by user id" },
    } as any)

    await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "sendAttachment",
      cfg,
      params: { to: "user:99", mediaUrl: "https://cdn.inline.chat/outbound-image.jpg", caption: "caption" },
    } as any)

    await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "sendAttachment",
      cfg,
      params: { to: "user:99", filePath: "/Users/mo/.openclaw/workspace/half-vertical.png", caption: "local file" },
    } as any)

    await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "send",
      cfg,
      params: { to: "user:99", message: "media alias", media: "/Users/mo/.openclaw/workspace/half-vertical.png" },
    } as any)

    await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "sendAttachment",
      cfg,
      params: {
        to: "user:99",
        caption: "multi",
        filePaths: [
          "/Users/mo/.openclaw/workspace/half-vertical.png",
          "/Users/mo/.openclaw/workspace/half-vertical-2.png",
        ],
      },
    } as any)

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
      params: { threadId: "7", replyToId: "10", text: "thread reply body" },
    } as any)

    await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "edit",
      cfg,
      params: { to: "7", messageId: "10", message: "**edited** body" },
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
      params: { threadName: "Alias Thread", participant: "@new-user", spaceId: "22" },
    } as any)

    await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "channel-edit",
      cfg,
      params: { to: "7", threadName: "Alias Rename" },
    } as any)

    await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "renameGroup",
      cfg,
      params: { to: "7", threadName: "Alias Rename" },
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
      params: { to: "7", participant: "@new-user" },
    } as any)

    await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "removeParticipant",
      cfg,
      params: { to: "7", participant: "@new-user" },
    } as any)

    await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "kick",
      cfg,
      params: { to: "7", participant: "@new-user" },
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

    await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "reactions",
      cfg,
      params: { to: "7", messageId: "10" },
    } as any)

    expect(sendMessage).toHaveBeenCalledWith(
      expect.objectContaining({
        userId: 99n,
        text: "dm body",
      }),
    )
    expect(sendMessage).toHaveBeenCalledWith(
      expect.objectContaining({
        userId: 99n,
        text: "dm by user id",
      }),
    )
    expect(sendMessage).toHaveBeenCalledWith(
      expect.objectContaining({
        userId: 99n,
        text: "caption",
        media: { kind: "photo", photoId: 901n },
      }),
    )
    expect(sendMessage).toHaveBeenCalledWith(
      expect.objectContaining({
        userId: 99n,
        text: "local file",
        media: { kind: "photo", photoId: 901n },
      }),
    )
    expect(sendMessage).toHaveBeenCalledWith(
      expect.objectContaining({
        userId: 99n,
        text: "media alias",
        media: { kind: "photo", photoId: 901n },
      }),
    )
    expect(sendMessage).toHaveBeenCalledWith(
      expect.objectContaining({
        userId: 99n,
        text: "multi",
        media: { kind: "photo", photoId: 901n },
      }),
    )
    expect(sendMessage).toHaveBeenCalledWith(
      expect.objectContaining({
        userId: 99n,
        media: { kind: "photo", photoId: 901n },
      }),
    )
    expect(sendMessage).toHaveBeenCalledWith(
      expect.objectContaining({
        chatId: 7n,
        text: "reply body",
        replyToMsgId: 10n,
      }),
    )
    expect(sendMessage).toHaveBeenCalledWith(
      expect.objectContaining({
        chatId: 7n,
        text: "thread reply body",
        replyToMsgId: 10n,
      }),
    )
    expect(uploadInlineMediaFromUrl).toHaveBeenCalledWith(
      expect.objectContaining({
        mediaUrl: "https://cdn.inline.chat/outbound-image.jpg",
      }),
    )
    expect(uploadInlineMediaFromUrl).toHaveBeenCalledWith(
      expect.objectContaining({
        mediaUrl: "/Users/mo/.openclaw/workspace/half-vertical.png",
      }),
    )
    expect(uploadInlineMediaFromUrl).toHaveBeenCalledWith(
      expect.objectContaining({
        mediaUrl: "/Users/mo/.openclaw/workspace/half-vertical-2.png",
      }),
    )
    expect(invokeRaw).toHaveBeenCalledWith(
      4,
      expect.objectContaining({
        oneofKind: "deleteMessages",
      }),
    )
    expect(invokeRaw).toHaveBeenCalledWith(
      8,
      expect.objectContaining({
        oneofKind: "editMessage",
        editMessage: expect.objectContaining({
          messageId: 10n,
          text: "**edited** body",
          parseMarkdown: true,
        }),
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
      9,
      expect.objectContaining({
        oneofKind: "createChat",
        createChat: expect.objectContaining({
          title: "Alias Thread",
          participants: [{ userId: 99n }],
        }),
      }),
    )
    expect(invokeRaw).toHaveBeenCalledWith(
      32,
      expect.objectContaining({
        oneofKind: "updateChatInfo",
        updateChatInfo: expect.objectContaining({
          chatId: 7n,
          title: "Alias Rename",
        }),
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
    expect(invokeRaw).toHaveBeenCalledWith(
      10,
      expect.objectContaining({
        oneofKind: "getSpaceMembers",
        getSpaceMembers: {
          spaceId: 22n,
        },
      }),
    )
    expect(invokeRaw).toHaveBeenCalledWith(
      38,
      expect.objectContaining({
        oneofKind: "getMessages",
      }),
    )
    expect(getMe).toHaveBeenCalled()
    expect(connect).toHaveBeenCalled()
    expect(close).toHaveBeenCalled()
  })

  it("falls back to getChatHistory for reactions when getMessages is unavailable", async () => {
    vi.resetModules()

    const invokeRaw = vi.fn(async (method: number) => {
      if (method === 38) {
        throw new Error("method not supported")
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
      throw new Error(`unexpected method ${String(method)}`)
    })

    vi.doMock("@inline-chat/realtime-sdk", () => ({
      Method: {
        GET_CHAT_HISTORY: 5,
        GET_MESSAGES: 38,
      },
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = vi.fn(async () => {})
        close = vi.fn(async () => {})
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
      action: "reactions",
      cfg,
      params: { to: "7", messageId: "10" },
    } as any)

    expect(invokeRaw).toHaveBeenCalledWith(
      38,
      expect.objectContaining({
        oneofKind: "getMessages",
      }),
    )
    expect(invokeRaw).toHaveBeenCalledWith(
      5,
      expect.objectContaining({
        oneofKind: "getChatHistory",
      }),
    )
  })

  it("accepts message-prefixed ids for react actions", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const close = vi.fn(async () => {})
    const getMe = vi.fn(async () => {
      throw new Error("getMe unavailable")
    })
    const invokeRaw = vi.fn(async (method: number) => {
      if (method === 6) {
        return { oneofKind: "addReaction", addReaction: { updates: [] } }
      }
      throw new Error(`unexpected method ${String(method)}`)
    })

    vi.doMock("@inline-chat/realtime-sdk", () => ({
      Method: {
        ADD_REACTION: 6,
      },
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        close = close
        getMe = getMe
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
      action: "react",
      cfg,
      params: { to: "7", messageId: "message 322", emoji: "✔️" },
    } as any)

    expect(invokeRaw).toHaveBeenCalledWith(
      6,
      expect.objectContaining({
        oneofKind: "addReaction",
        addReaction: expect.objectContaining({
          emoji: "✔️",
          messageId: 322n,
          peerId: expect.objectContaining({
            type: expect.objectContaining({
              oneofKind: "chat",
            }),
          }),
        }),
      }),
    )
    expect(connect).toHaveBeenCalled()
    expect(close).toHaveBeenCalled()
  })

  it("treats duplicate react failures as already-present success", async () => {
    vi.resetModules()

    const invokeRaw = vi.fn(async (method: number) => {
      if (method === 6) {
        throw new Error('duplicate key value violates unique constraint "unique_reaction_per_emoji"')
      }
      throw new Error(`unexpected method ${String(method)}`)
    })

    vi.doMock("@inline-chat/realtime-sdk", () => ({
      Method: {
        ADD_REACTION: 6,
      },
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = vi.fn(async () => {})
        close = vi.fn(async () => {})
        getMe = vi.fn(async () => {
          throw new Error("getMe unavailable")
        })
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

    const result = await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "react",
      cfg,
      params: { to: "7", messageId: "322", emoji: "✔️" },
    } as any)

    expect(result?.details).toEqual(
      expect.objectContaining({
        ok: true,
        chatId: "7",
        messageId: "322",
        emoji: "✔️",
        remove: false,
        alreadyPresent: true,
      }),
    )
    expect(invokeRaw).toHaveBeenCalledWith(
      6,
      expect.objectContaining({
        oneofKind: "addReaction",
      }),
    )
  })

  it("falls back to toolContext.currentMessageId for react", async () => {
    vi.resetModules()

    const invokeRaw = vi.fn(async (method: number) => {
      if (method === 6) {
        return { oneofKind: "addReaction", addReaction: { updates: [] } }
      }
      throw new Error(`unexpected method ${String(method)}`)
    })

    vi.doMock("@inline-chat/realtime-sdk", () => ({
      Method: {
        ADD_REACTION: 6,
      },
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = vi.fn(async () => {})
        close = vi.fn(async () => {})
        getMe = vi.fn(async () => {
          throw new Error("getMe unavailable")
        })
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
      action: "react",
      cfg,
      params: { to: "7", emoji: "✔️" },
      toolContext: { currentMessageId: "322" },
    } as any)

    expect(invokeRaw).toHaveBeenCalledWith(
      6,
      expect.objectContaining({
        oneofKind: "addReaction",
        addReaction: expect.objectContaining({
          messageId: 322n,
        }),
      }),
    )
  })

  it("soft-fails react when message id is missing", async () => {
    vi.resetModules()

    vi.doMock("@inline-chat/realtime-sdk", () => ({
      Method: {
        ADD_REACTION: 6,
      },
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = vi.fn(async () => {})
        close = vi.fn(async () => {})
        getMe = vi.fn(async () => ({ userId: 42n }))
        invokeRaw = vi.fn(async () => ({ oneofKind: "addReaction", addReaction: { updates: [] } }))
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

    const result = await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "react",
      cfg,
      params: { to: "7", emoji: "✔️" },
    } as any)

    expect(result?.details).toEqual(
      expect.objectContaining({
        ok: false,
        reason: "missing_message_id",
      }),
    )
  })

  it("soft-fails react on generic add-reaction errors", async () => {
    vi.resetModules()

    const invokeRaw = vi.fn(async (method: number) => {
      if (method === 6) {
        throw new Error("network glitch")
      }
      throw new Error(`unexpected method ${String(method)}`)
    })

    vi.doMock("@inline-chat/realtime-sdk", () => ({
      Method: {
        ADD_REACTION: 6,
      },
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = vi.fn(async () => {})
        close = vi.fn(async () => {})
        getMe = vi.fn(async () => {
          throw new Error("getMe unavailable")
        })
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

    const result = await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "react",
      cfg,
      params: { to: "7", messageId: "322", emoji: "✔️" },
    } as any)

    expect(result?.details).toEqual(
      expect.objectContaining({
        ok: false,
        reason: "error",
        hint: "Reaction failed. Do not retry.",
      }),
    )
  })

  it("soft-fails react when reactions are disabled by config", async () => {
    vi.resetModules()

    const { inlineMessageActions } = await import("./actions")

    const cfg = {
      channels: {
        inline: {
          token: "token",
          baseUrl: "https://api.inline.chat",
          actions: {
            reactions: false,
          },
        },
      },
    } satisfies OpenClawConfig

    const result = await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "react",
      cfg,
      params: { to: "7", messageId: "322", emoji: "✔️" },
    } as any)

    expect(result?.details).toEqual(
      expect.objectContaining({
        ok: false,
        reason: "disabled",
      }),
    )
  })

  it("returns bot-friendly channel-list groups and peers with targets", async () => {
    vi.resetModules()

    const invokeRaw = vi.fn(async (method: number) => {
      if (method === 17) {
        return {
          oneofKind: "getChats",
          getChats: {
            chats: [
              {
                id: 7n,
                title: "Alice DM",
                spaceId: 22n,
                isPublic: false,
                peerId: {
                  type: {
                    oneofKind: "user",
                    user: { userId: 99n },
                  },
                },
              },
              {
                id: 8n,
                title: "Eng Group",
                spaceId: 22n,
                isPublic: true,
                peerId: {
                  type: {
                    oneofKind: "chat",
                    chat: { chatId: 8n },
                  },
                },
              },
            ],
            dialogs: [
              { chatId: 7n, unreadCount: 2, archived: false, pinned: true },
              { chatId: 8n, unreadCount: 0, archived: false, pinned: false },
            ],
            users: [
              { id: 99n, username: "alice", firstName: "Alice" },
              { id: 42n, username: "bob", firstName: "Bob" },
            ],
          },
        }
      }
      throw new Error(`unexpected method ${String(method)}`)
    })

    vi.doMock("@inline-chat/realtime-sdk", () => ({
      Method: {
        GET_CHATS: 17,
      },
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = vi.fn(async () => {})
        close = vi.fn(async () => {})
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

    const result = await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "channel-list",
      cfg,
      params: {},
    } as any)

    expect(result?.details).toMatchObject({
      ok: true,
      scope: "all",
      count: 2,
      groupsCount: 1,
      peersCount: 2,
      chats: expect.arrayContaining([expect.objectContaining({ id: "7", target: "chat:7" })]),
      groups: expect.arrayContaining([expect.objectContaining({ id: "8", target: "chat:8" })]),
      peers: expect.arrayContaining([expect.objectContaining({ id: "99", target: "user:99", name: "Alice" })]),
    })
  })

  it("supports channel-list scope filtering for peers", async () => {
    vi.resetModules()

    const invokeRaw = vi.fn(async (method: number) => {
      if (method === 17) {
        return {
          oneofKind: "getChats",
          getChats: {
            chats: [
              {
                id: 7n,
                title: "Alice DM",
                peerId: {
                  type: {
                    oneofKind: "user",
                    user: { userId: 99n },
                  },
                },
              },
            ],
            dialogs: [],
            users: [{ id: 99n, username: "alice", firstName: "Alice" }],
          },
        }
      }
      throw new Error(`unexpected method ${String(method)}`)
    })

    vi.doMock("@inline-chat/realtime-sdk", () => ({
      Method: {
        GET_CHATS: 17,
      },
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = vi.fn(async () => {})
        close = vi.fn(async () => {})
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

    const result = await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "channel-list",
      cfg,
      params: { scope: "peers", query: "alice" },
    } as any)

    expect(result?.details).toMatchObject({
      ok: true,
      scope: "peers",
      chats: [],
      groups: [],
      peers: [expect.objectContaining({ id: "99", target: "user:99" })],
    })
  })

  it("returns attachment-aware text and urls for read results", async () => {
    vi.resetModules()

    const invokeRaw = vi.fn(async (method: number) => {
      if (method === 5) {
        return {
          oneofKind: "getChatHistory",
          getChatHistory: {
            messages: [
              {
                id: 270n,
                fromId: 42n,
                date: 1_700_000_000n,
                message: "",
                out: false,
                media: {
                  media: {
                    oneofKind: "photo",
                    photo: {
                      photo: {
                        id: 901n,
                        sizes: [{ w: 1200, h: 900, size: 12345, cdnUrl: "https://cdn.inline.chat/image-270.jpg" }],
                      },
                    },
                  },
                },
                attachments: {
                  attachments: [
                    {
                      attachment: {
                        oneofKind: "urlPreview",
                        urlPreview: {
                          id: 902n,
                          url: "https://example.com/image-context",
                          title: "Image context",
                        },
                      },
                    },
                  ],
                },
              },
            ],
          },
        }
      }
      throw new Error(`unexpected method ${String(method)}`)
    })

    vi.doMock("@inline-chat/realtime-sdk", () => ({
      Method: {
        GET_CHAT_HISTORY: 5,
      },
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = vi.fn(async () => {})
        close = vi.fn(async () => {})
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

    const result = await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "read",
      cfg,
      params: { to: "7", limit: 1 },
    } as any)

    expect(result).toMatchObject({
      details: {
        messages: [
          expect.objectContaining({
            id: "270",
            text: "image attachment: https://cdn.inline.chat/image-270.jpg | link preview (Image context): https://example.com/image-context",
            rawText: "",
            attachmentText:
              "image attachment: https://cdn.inline.chat/image-270.jpg | link preview (Image context): https://example.com/image-context",
            attachmentUrls: [
              "https://cdn.inline.chat/image-270.jpg",
              "https://example.com/image-context",
            ],
            media: expect.objectContaining({
              kind: "photo",
              url: "https://cdn.inline.chat/image-270.jpg",
            }),
            attachments: [
              expect.objectContaining({
                kind: "urlPreview",
                url: "https://example.com/image-context",
              }),
            ],
          }),
        ],
      },
    })
  })

  it("returns media summaries for flattened media payloads in read results", async () => {
    vi.resetModules()

    const invokeRaw = vi.fn(async (method: number) => {
      if (method === 5) {
        return {
          oneofKind: "getChatHistory",
          getChatHistory: {
            messages: [
              {
                id: 272n,
                fromId: 42n,
                date: 1_700_000_020n,
                message: "",
                out: false,
                media: {
                  oneofKind: "photo",
                  photo: {
                    photo: {
                      id: 903n,
                      sizes: [{ w: 1280, h: 720, size: 67_890, cdnUrl: "https://cdn.inline.chat/image-272.jpg" }],
                    },
                  },
                },
              },
            ],
          },
        }
      }
      throw new Error(`unexpected method ${String(method)}`)
    })

    vi.doMock("@inline-chat/realtime-sdk", () => ({
      Method: {
        GET_CHAT_HISTORY: 5,
      },
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = vi.fn(async () => {})
        close = vi.fn(async () => {})
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

    const result = await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "read",
      cfg,
      params: { to: "7", limit: 1 },
    } as any)

    expect(result).toMatchObject({
      details: {
        messages: [
          expect.objectContaining({
            id: "272",
            text: "image attachment: https://cdn.inline.chat/image-272.jpg",
            rawText: "",
            attachmentText: "image attachment: https://cdn.inline.chat/image-272.jpg",
            attachmentUrls: ["https://cdn.inline.chat/image-272.jpg"],
            media: expect.objectContaining({
              kind: "photo",
              url: "https://cdn.inline.chat/image-272.jpg",
            }),
          }),
        ],
      },
    })
  })

  it("returns structured entities for read results", async () => {
    vi.resetModules()

    const invokeRaw = vi.fn(async (method: number) => {
      if (method === 5) {
        return {
          oneofKind: "getChatHistory",
          getChatHistory: {
            messages: [
              {
                id: 271n,
                fromId: 42n,
                date: 1_700_000_010n,
                message: "See Alice docs",
                out: false,
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
                        textUrl: { url: "https://example.com/docs" },
                      },
                    },
                  ],
                },
              },
            ],
          },
        }
      }
      throw new Error(`unexpected method ${String(method)}`)
    })

    vi.doMock("@inline-chat/realtime-sdk", () => ({
      Method: {
        GET_CHAT_HISTORY: 5,
      },
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = vi.fn(async () => {})
        close = vi.fn(async () => {})
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

    const result = await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "read",
      cfg,
      params: { to: "7", limit: 1 },
    } as any)

    expect(result).toMatchObject({
      details: {
        messages: [
          expect.objectContaining({
            id: "271",
            text: "See Alice docs",
            entityText: 'mention "Alice" -> user:99 | text link "docs" -> https://example.com/docs',
            entities: [
              {
                type: "mention",
                offset: 4,
                length: 5,
                text: "Alice",
                userId: "99",
              },
              {
                type: "text_link",
                offset: 10,
                length: 4,
                text: "docs",
                url: "https://example.com/docs",
              },
            ],
            links: ["https://example.com/docs"],
          }),
        ],
      },
    })
  })

  it("returns media summaries for flattened media payloads in search results", async () => {
    vi.resetModules()

    const invokeRaw = vi.fn(async (method: number) => {
      if (method === 31) {
        return {
          oneofKind: "searchMessages",
          searchMessages: {
            messages: [
              {
                id: 280n,
                fromId: 42n,
                date: 1_700_000_030n,
                message: "",
                out: false,
                media: {
                  oneofKind: "photo",
                  photo: {
                    photo: {
                      id: 905n,
                      sizes: [{ w: 640, h: 640, size: 12_345, cdnUrl: "https://cdn.inline.chat/search-photo.jpg" }],
                    },
                  },
                },
              },
            ],
          },
        }
      }
      throw new Error(`unexpected method ${String(method)}`)
    })

    vi.doMock("@inline-chat/realtime-sdk", () => ({
      Method: {
        SEARCH_MESSAGES: 31,
      },
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = vi.fn(async () => {})
        close = vi.fn(async () => {})
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

    const result = await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "search",
      cfg,
      params: { to: "7", query: "photo", limit: 1 },
    } as any)

    expect(result).toMatchObject({
      details: {
        query: "photo",
        messages: [
          expect.objectContaining({
            id: "280",
            text: "image attachment: https://cdn.inline.chat/search-photo.jpg",
            attachmentText: "image attachment: https://cdn.inline.chat/search-photo.jpg",
            attachmentUrls: ["https://cdn.inline.chat/search-photo.jpg"],
            media: expect.objectContaining({
              kind: "photo",
              url: "https://cdn.inline.chat/search-photo.jpg",
            }),
          }),
        ],
      },
    })
  })

  it("rejects sendAttachment when no media source is provided", async () => {
    vi.resetModules()

    const sendMessage = vi.fn(async () => ({ messageId: 1n }))
    const connect = vi.fn(async () => {})
    const close = vi.fn(async () => {})
    const uploadInlineMediaFromUrl = vi.fn(async () => ({ kind: "photo", photoId: 901n }))

    vi.doMock("@inline-chat/realtime-sdk", () => ({
      Method: {
        GET_CHAT: 25,
      },
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        close = close
        sendMessage = sendMessage
        invokeRaw = vi.fn(async () => ({ oneofKind: undefined }))
      },
    }))
    vi.doMock("./media", () => ({
      uploadInlineMediaFromUrl,
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

    await expect(
      inlineMessageActions.handleAction?.({
        channel: "inline",
        action: "sendAttachment",
        cfg,
        params: { to: "user:99", caption: "missing media" },
      } as any),
    ).rejects.toThrow("inline action: sendAttachment requires media/file input")

    expect(uploadInlineMediaFromUrl).not.toHaveBeenCalled()
    expect(sendMessage).not.toHaveBeenCalled()
    expect(close).toHaveBeenCalled()
  })

  it("maps send buttons to inline message actions", async () => {
    vi.resetModules()

    const sendMessage = vi.fn(async () => ({ messageId: 1n }))
    const connect = vi.fn(async () => {})
    const close = vi.fn(async () => {})

    vi.doMock("@inline-chat/realtime-sdk", () => ({
      Method: {
        EDIT_MESSAGE: 8,
      },
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        close = close
        sendMessage = sendMessage
        invokeRaw = vi.fn(async () => ({ oneofKind: undefined }))
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
      action: "send",
      cfg,
      params: {
        to: "user:99",
        message: "with buttons",
        buttons: [[{ text: "Approve", callback_data: "approve" }]],
      },
    } as any)

    expect(sendMessage).toHaveBeenCalledWith(
      expect.objectContaining({
        userId: 99n,
        text: "with buttons",
        actions: expect.objectContaining({
          rows: [
            expect.objectContaining({
              actions: [
                expect.objectContaining({
                  actionId: "btn_1_1",
                  text: "Approve",
                }),
              ],
            }),
          ],
        }),
      }),
    )
    const sent = sendMessage.mock.calls[0]?.[0]
    const data = sent?.actions?.rows?.[0]?.actions?.[0]?.action?.callback?.data
    expect(data).toBeInstanceOf(Uint8Array)
    expect(new TextDecoder().decode(data)).toBe("approve")
  })

  it("maps shared interactive payload to inline message actions when buttons are omitted", async () => {
    vi.resetModules()

    const sendMessage = vi.fn(async () => ({ messageId: 1n }))
    const connect = vi.fn(async () => {})
    const close = vi.fn(async () => {})

    vi.doMock("@inline-chat/realtime-sdk", () => ({
      Method: {
        EDIT_MESSAGE: 8,
      },
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        close = close
        sendMessage = sendMessage
        invokeRaw = vi.fn(async () => ({ oneofKind: undefined }))
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
      action: "send",
      cfg,
      params: {
        to: "user:99",
        message: "with interactive",
        interactive: {
          blocks: [
            {
              type: "buttons",
              buttons: [{ label: "Approve", value: "approve", style: "success" }],
            },
            {
              type: "select",
              placeholder: "Pick one",
              options: [
                { label: "Option A", value: "a" },
                { label: "Option B", value: "b" },
              ],
            },
          ],
        },
      },
    } as any)

    expect(sendMessage).toHaveBeenCalledWith(
      expect.objectContaining({
        userId: 99n,
        text: "with interactive",
        actions: expect.objectContaining({
          rows: expect.arrayContaining([
            expect.objectContaining({
              actions: expect.arrayContaining([
                expect.objectContaining({
                  text: "Approve",
                }),
              ]),
            }),
            expect.objectContaining({
              actions: expect.arrayContaining([
                expect.objectContaining({
                  text: "Option A",
                }),
                expect.objectContaining({
                  text: "Option B",
                }),
              ]),
            }),
          ]),
        }),
      }),
    )
    const sent = sendMessage.mock.calls[0]?.[0]
    const data = sent?.actions?.rows?.[0]?.actions?.[0]?.action?.callback?.data
    expect(data).toBeInstanceOf(Uint8Array)
    expect(new TextDecoder().decode(data)).toBe("approve")
  })

  it("passes empty buttons on edit to clear existing actions", async () => {
    vi.resetModules()

    const invokeRaw = vi.fn(async () => ({ oneofKind: "editMessage", editMessage: { updates: [] } }))
    const connect = vi.fn(async () => {})
    const close = vi.fn(async () => {})

    vi.doMock("@inline-chat/realtime-sdk", () => ({
      Method: {
        EDIT_MESSAGE: 8,
      },
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        close = close
        sendMessage = vi.fn(async () => ({ messageId: 1n }))
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
      action: "edit",
      cfg,
      params: {
        to: "7",
        messageId: "10",
        message: "updated",
        buttons: [],
      },
    } as any)

    expect(invokeRaw).toHaveBeenCalledWith(
      8,
      expect.objectContaining({
        oneofKind: "editMessage",
        editMessage: expect.objectContaining({
          messageId: 10n,
          actions: expect.objectContaining({
            rows: [],
          }),
        }),
      }),
    )
  })

  it("requires threadId for thread-reply when replyThreads is enabled", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const close = vi.fn(async () => {})
    const sendMessage = vi.fn(async () => ({ messageId: 88n }))

    vi.doMock("@inline-chat/realtime-sdk", () => ({
      Method: {},
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        close = close
        sendMessage = sendMessage
      },
    }))

    const { inlineMessageActions } = await import("./actions")

    await expect(
      inlineMessageActions.handleAction?.({
        channel: "inline",
        action: "thread-reply",
        cfg: {
          channels: {
            inline: {
              token: "token",
              baseUrl: "https://api.inline.chat",
              capabilities: {
                replyThreads: true,
              },
            },
          },
        } as OpenClawConfig,
        params: {
          to: "7",
          replyToId: "10",
          message: "thread reply body",
        },
      } as any),
    ).rejects.toThrow("inline thread-reply: threadId is required when reply threads are enabled")
  })

  it("sends thread-reply into the child reply-thread chat when enabled", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const close = vi.fn(async () => {})
    const sendMessage = vi.fn(async () => ({ messageId: 88n }))

    vi.doMock("@inline-chat/realtime-sdk", () => ({
      Method: {},
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        close = close
        sendMessage = sendMessage
      },
    }))

    const { inlineMessageActions } = await import("./actions")

    await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "thread-reply",
      cfg: {
        channels: {
          inline: {
            token: "token",
            baseUrl: "https://api.inline.chat",
            capabilities: {
              replyThreads: true,
            },
          },
        },
      } as OpenClawConfig,
      params: {
        to: "7",
        threadId: "77",
        replyToId: "10",
        message: "thread reply body",
      },
    } as any)

    expect(sendMessage).toHaveBeenCalledWith(
      expect.objectContaining({
        chatId: 77n,
        text: "thread reply body",
        replyToMsgId: 10n,
      }),
    )
  })

  it("uses createSubthread for thread-create when enabled", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const close = vi.fn(async () => {})
    const getMe = vi.fn(async () => ({ userId: 500n, firstName: "Inline", username: "inline-bot" }))
    const invokeRaw = vi.fn(async (method: number) => {
      if (method !== 43) {
        throw new Error(`unexpected method ${String(method)}`)
      }
      return {
        oneofKind: "createSubthread",
        createSubthread: {
          chat: { id: 71n, title: "Follow-up thread", parentChatId: 7n, parentMessageId: 10n },
          dialog: { chatId: 71n },
          anchorMessage: { id: 10n, fromId: 42n, message: "anchor" },
        },
      }
    })

    vi.doMock("@inline-chat/realtime-sdk", () => ({
      Method: {
        CREATE_SUBTHREAD: 43,
      },
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        close = close
        getMe = getMe
        invokeRaw = invokeRaw
      },
    }))

    const { inlineMessageActions } = await import("./actions")

    await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "thread-create",
      cfg: {
        channels: {
          inline: {
            token: "token",
            baseUrl: "https://api.inline.chat",
            capabilities: {
              replyThreads: true,
            },
          },
        },
      } as OpenClawConfig,
      params: {
        to: "7",
        replyToId: "10",
        threadName: "Follow-up thread",
      },
    } as any)

    expect(invokeRaw).toHaveBeenCalledWith(
      43,
      expect.objectContaining({
        oneofKind: "createSubthread",
        createSubthread: expect.objectContaining({
          parentChatId: 7n,
          parentMessageId: 10n,
          title: "Follow-up thread",
        }),
      }),
    )
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
