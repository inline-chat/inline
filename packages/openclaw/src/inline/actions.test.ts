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
    expect(configured).toContain("upload-file")
    expect(configured).toContain("compose-action")
    expect(configured).toContain("typing")
    expect(configured).toContain("stop-typing")
    expect(configured).toContain("uploading-photo")
    expect(configured).toContain("uploading-document")
    expect(configured).toContain("uploading-video")
    expect(configured).toContain("recording-voice")
    expect(configured).toContain("forward")
    expect(configured).toContain("forwardMessages")
    expect(configured).toContain("thread-reply")
    expect(configured).toContain("get-messages")
    expect(configured).toContain("getMessages")
    expect(configured).toContain("bot-commands")
    expect(configured).toContain("botCommands")
    expect(configured).toContain("peer-bot-commands")
    expect(configured).toContain("peerBotCommands")
    expect(configured).toContain("download-file")
    expect(configured).toContain("translate")
    expect(configured).toContain("translateMessages")
    expect(configured).toContain("channel-list")
    expect(configured).toContain("renameGroup")
    expect(configured).toContain("channel-create")
    expect(configured).toContain("removeParticipant")
    expect(configured).toContain("invite-to-space")
    expect(configured).toContain("inviteToSpace")
    expect(configured).toContain("kick")
    expect(configured).toContain("leaveGroup")
    expect(configured).toContain("delete")
    expect(configured).toContain("delete-attachment")
    expect(configured).toContain("deleteMessageAttachment")
    expect(configured).toContain("pin")
    expect(configured).toContain("permissions")
    for (const removedAction of [
      "mark-read",
      "mark-unread",
      "show-in-chat-list",
      "showInChatList",
      "archive",
      "unarchive",
      "mute",
      "unmute",
      "notification-settings",
      "set-notifications",
      "pin-chat",
      "unpin-chat",
      "pinChat",
      "unpinChat",
      "follow-thread",
      "unfollow-thread",
      "followThread",
      "unfollowThread",
    ]) {
      expect(configured).not.toContain(removedAction)
    }

    const gated =
      inlineMessageActions.listActions?.({
        cfg: {
          channels: {
            inline: {
              token: "token",
              baseUrl: "https://api.inline.chat",
              actions: {
                send: false,
                read: false,
                channels: false,
                participants: false,
                delete: false,
                pins: false,
                permissions: false,
                translate: false,
              },
            },
          },
        } as OpenClawConfig,
      }) ?? []

    expect(gated).toContain("reply")
    expect(gated).not.toContain("send")
    expect(gated).not.toContain("upload-file")
    expect(gated).not.toContain("compose-action")
    expect(gated).not.toContain("typing")
    expect(gated).not.toContain("stop-typing")
    expect(gated).not.toContain("uploading-photo")
    expect(gated).not.toContain("uploading-document")
    expect(gated).not.toContain("uploading-video")
    expect(gated).not.toContain("recording-voice")
    expect(gated).not.toContain("forward")
    expect(gated).not.toContain("forwardMessages")
    expect(gated).not.toContain("read")
    expect(gated).not.toContain("get-messages")
    expect(gated).not.toContain("getMessages")
    expect(gated).not.toContain("bot-commands")
    expect(gated).not.toContain("botCommands")
    expect(gated).not.toContain("peer-bot-commands")
    expect(gated).not.toContain("peerBotCommands")
    expect(gated).not.toContain("download-file")
    expect(gated).not.toContain("mark-read")
    expect(gated).not.toContain("mark-unread")
    expect(gated).not.toContain("channel-list")
    expect(gated).not.toContain("show-in-chat-list")
    expect(gated).not.toContain("showInChatList")
    expect(gated).not.toContain("archive")
    expect(gated).not.toContain("unarchive")
    expect(gated).not.toContain("mute")
    expect(gated).not.toContain("unmute")
    expect(gated).not.toContain("notification-settings")
    expect(gated).not.toContain("set-notifications")
    expect(gated).not.toContain("pin-chat")
    expect(gated).not.toContain("unpin-chat")
    expect(gated).not.toContain("pinChat")
    expect(gated).not.toContain("unpinChat")
    expect(gated).not.toContain("follow-thread")
    expect(gated).not.toContain("unfollow-thread")
    expect(gated).not.toContain("followThread")
    expect(gated).not.toContain("unfollowThread")
    expect(gated).not.toContain("translate")
    expect(gated).not.toContain("removeParticipant")
    expect(gated).not.toContain("invite-to-space")
    expect(gated).not.toContain("inviteToSpace")
    expect(gated).not.toContain("delete")
    expect(gated).not.toContain("delete-attachment")
    expect(gated).not.toContain("deleteMessageAttachment")
    expect(gated).not.toContain("pin")
    expect(gated).not.toContain("unpin")
    expect(gated).not.toContain("list-pins")
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

  it("keeps generated message buttons inside Inline server action limits", async () => {
    vi.resetModules()
    const { resolveInlineMessageActionsParam } = await import("./actions")
    const { INLINE_ACTION_CALLBACK_DATA_MAX_BYTES, INLINE_ACTION_LABEL_MAX_LENGTH } =
      await import("./outbound-sanitize")

    const actions = resolveInlineMessageActionsParam({
      buttons: [
        [
          { text: "x".repeat(80), callback_data: "approve" },
          {
            text: "Oversized",
            callback_data: "y".repeat(INLINE_ACTION_CALLBACK_DATA_MAX_BYTES + 1),
          },
        ],
      ],
    })

    expect(actions?.rows).toHaveLength(1)
    expect(actions?.rows?.[0]?.actions).toHaveLength(1)
    expect(actions?.rows?.[0]?.actions?.[0]?.text).toHaveLength(INLINE_ACTION_LABEL_MAX_LENGTH)
    const data = actions?.rows?.[0]?.actions?.[0]?.action?.callback?.data
    expect(data).toBeInstanceOf(Uint8Array)
    expect(new TextDecoder().decode(data)).toBe("approve")
  })

  it("maps copy-text buttons to Inline copyText message actions", async () => {
    vi.resetModules()
    const { resolveInlineMessageActionsParam } = await import("./actions")

    const actions = resolveInlineMessageActionsParam({
      buttons: [[{ text: "Copy command", copy_text: "bun run typecheck" }]],
    })

    const action = actions?.rows?.[0]?.actions?.[0]
    expect(action?.text).toBe("Copy command")
    expect(action?.action).toEqual({
      oneofKind: "copyText",
      copyText: {
        text: "bun run typecheck",
      },
    })
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
    const allSchemaActions = Array.isArray(discovery?.schema)
      ? discovery.schema.flatMap((entry) => entry.actions ?? [])
      : []
    const buttonsSchema = schema?.properties?.buttons as Record<string | symbol, unknown> | undefined
    const threadCreateSchema = (Array.isArray(discovery?.schema)
      ? discovery.schema.find((entry) => entry.actions?.includes("thread-create"))
      : discovery?.schema
    )?.properties.spaceId as { type?: string; description?: string } | undefined
    const translateSchema = (Array.isArray(discovery?.schema)
      ? discovery.schema.find((entry) => entry.actions?.includes("translate"))
      : discovery?.schema
    )?.properties.language as { type?: string; description?: string } | undefined
    const channelEditSchema = (Array.isArray(discovery?.schema)
      ? discovery.schema.find((entry) => entry.actions?.includes("channel-edit"))
      : discovery?.schema
    )?.properties.emoji as { type?: string; description?: string } | undefined
    const readSchema = (Array.isArray(discovery?.schema)
      ? discovery.schema.find((entry) => entry.actions?.includes("read"))
      : discovery?.schema
    )?.properties.after as { type?: string; description?: string } | undefined
    const reactionSchema = (Array.isArray(discovery?.schema)
      ? discovery.schema.find((entry) => entry.actions?.includes("react"))
      : discovery?.schema
    )?.properties.messageId as { type?: string; description?: string } | undefined
    const getMessagesSchema = (Array.isArray(discovery?.schema)
      ? discovery.schema.find((entry) => entry.actions?.includes("get-messages" as never))
      : discovery?.schema
    )?.properties.messageIds as { oneOf?: unknown[]; description?: string } | undefined
    const botCommandsSchema = (Array.isArray(discovery?.schema)
      ? discovery.schema.find((entry) => entry.actions?.includes("peer-bot-commands" as never))
      : discovery?.schema
    )?.properties.threadId as { type?: string; description?: string } | undefined
    const downloadFileSchema = (Array.isArray(discovery?.schema)
      ? discovery.schema.find((entry) => entry.actions?.includes("download-file" as never))
      : discovery?.schema
    )?.properties.mediaUrl as { type?: string; description?: string } | undefined
    const deleteAttachmentSchema = (Array.isArray(discovery?.schema)
      ? discovery.schema.find((entry) => entry.actions?.includes("delete-attachment" as never))
      : discovery?.schema
    )?.properties.attachmentId as { type?: string; description?: string } | undefined
    const pinMessageSchema = (Array.isArray(discovery?.schema)
      ? discovery.schema.find((entry) => entry.actions?.includes("pin"))
      : discovery?.schema
    )?.properties.messageId as { type?: string; description?: string } | undefined
    const listPinsSchema = (Array.isArray(discovery?.schema)
      ? discovery.schema.find((entry) => entry.actions?.includes("list-pins"))
      : discovery?.schema
    )?.properties.threadId as { type?: string; description?: string } | undefined
    const uploadFileSchema = (Array.isArray(discovery?.schema)
      ? discovery.schema.find((entry) => entry.actions?.includes("upload-file"))
      : discovery?.schema
    )?.properties.filePath as { type?: string; description?: string } | undefined
    const composeActionSchema = (Array.isArray(discovery?.schema)
      ? discovery.schema.find((entry) => entry.actions?.includes("typing" as never))
      : discovery?.schema
    )?.properties.composeAction as { type?: string; enum?: string[]; description?: string } | undefined
    const forwardSchema = (Array.isArray(discovery?.schema)
      ? discovery.schema.find((entry) => entry.actions?.includes("forward" as never))
      : discovery?.schema
    )?.properties.from as { type?: string; description?: string } | undefined
    const inviteSchema = (Array.isArray(discovery?.schema)
      ? discovery.schema.find((entry) => entry.actions?.includes("invite-to-space" as never))
      : discovery?.schema
    )?.properties.email as { type?: string; description?: string } | undefined
    const channelDataSchema = (Array.isArray(discovery?.schema)
      ? discovery.schema.find((entry) => entry.properties.channelData)
      : discovery?.schema
    )?.properties.channelData as
      | {
          type?: string
          properties?: {
            inline?: {
              properties?: {
                botPresence?: {
                  properties?: {
                    kind?: { enum?: string[] }
                    comment?: { maxLength?: number }
                  }
                }
              }
            }
          }
        }
      | undefined

    expect(discovery?.capabilities).toEqual(["presentation"])
    expect(buttonsSchema).toBeDefined()
    expect(buttonsSchema?.type).toBe("array")
    expect(buttonsSchema?.description).toContain("copy_text")
    expect(
      (
        (buttonsSchema?.items as { items?: { properties?: Record<string, unknown> } } | undefined)
          ?.items?.properties ?? {}
      ).copy_text,
    ).toBeDefined()
    expect(threadCreateSchema?.type).toBe("string")
    expect(translateSchema?.type).toBe("string")
    expect(channelEditSchema?.type).toBe("string")
    for (const removedAction of [
      "mark-read",
      "mark-unread",
      "show-in-chat-list",
      "showInChatList",
      "archive",
      "unarchive",
      "mute",
      "unmute",
      "notification-settings",
      "set-notifications",
      "pin-chat",
      "unpin-chat",
      "pinChat",
      "unpinChat",
      "follow-thread",
      "unfollow-thread",
      "followThread",
      "unfollowThread",
    ]) {
      expect(allSchemaActions).not.toContain(removedAction)
      expect(inlineMessageActions.messageActionTargetAliases?.[removedAction as never]).toBeUndefined()
    }
    expect(readSchema?.type).toBe("string")
    expect(reactionSchema?.type).toBe("string")
    expect(reactionSchema?.description).toContain("current inbound message")
    expect(getMessagesSchema?.oneOf).toBeDefined()
    expect(botCommandsSchema?.type).toBe("string")
    expect(downloadFileSchema?.type).toBe("string")
    expect(downloadFileSchema?.description).toContain("download")
    expect(deleteAttachmentSchema?.type).toBe("string")
    expect(pinMessageSchema?.type).toBe("string")
    expect(pinMessageSchema?.description).toContain("current inbound message")
    expect(listPinsSchema?.type).toBe("string")
    expect(uploadFileSchema?.type).toBe("string")
    expect(composeActionSchema?.type).toBe("string")
    expect(composeActionSchema?.enum).toContain("recording-voice")
    expect(forwardSchema?.type).toBe("string")
    expect(inviteSchema?.type).toBe("string")
    expect(channelDataSchema?.type).toBe("object")
    expect(channelDataSchema?.properties?.inline?.properties?.botPresence?.properties?.kind?.enum).toContain("waving")
    expect(channelDataSchema?.properties?.inline?.properties?.botPresence?.properties?.comment?.maxLength).toBe(30)
    expect(inlineMessageActions.messageActionTargetAliases?.["thread-create"]?.aliases).toContain("spaceId")
    expect(inlineMessageActions.messageActionTargetAliases?.["thread-create"]?.aliases).toContain("participant")
    expect(inlineMessageActions.messageActionTargetAliases?.["thread-reply"]?.aliases).toContain("threadId")
    expect(inlineMessageActions.messageActionTargetAliases?.["thread-reply"]?.aliases).toContain("parentMessageId")
    expect(inlineMessageActions.messageActionTargetAliases?.react?.aliases).toContain("threadId")
    expect(inlineMessageActions.messageActionTargetAliases?.reactions?.aliases).toContain("messageId")
    expect(inlineMessageActions.messageActionTargetAliases?.["channel-edit"]?.aliases).toContain("visibility")
    expect(inlineMessageActions.messageActionTargetAliases?.translate?.aliases).toContain("messageIds")
    expect(inlineMessageActions.messageActionTargetAliases?.read?.aliases).toContain("threadId")
    expect(inlineMessageActions.messageActionTargetAliases?.read?.aliases).toContain("after")
    expect(inlineMessageActions.messageActionTargetAliases?.read?.aliases).toContain("anchorId")
    expect(inlineMessageActions.messageActionTargetAliases?.["get-messages"]?.aliases).toContain("messageIds")
    expect(inlineMessageActions.messageActionTargetAliases?.getMessages?.aliases).toContain("threadId")
    expect(inlineMessageActions.messageActionTargetAliases?.["peer-bot-commands"]?.aliases).toContain("threadId")
    expect(inlineMessageActions.messageActionTargetAliases?.botCommands?.aliases).toContain("userId")
    expect(inlineMessageActions.messageActionTargetAliases?.["download-file"]?.aliases).toContain("mediaId")
    expect(inlineMessageActions.messageActionTargetAliases?.["download-file"]?.aliases).toContain("attachmentId")
    expect(inlineMessageActions.messageActionTargetAliases?.["delete-attachment"]?.aliases).toContain("attachmentId")
    expect(inlineMessageActions.messageActionTargetAliases?.["upload-file"]?.aliases).toContain("filePath")
    expect(inlineMessageActions.messageActionTargetAliases?.["compose-action"]?.aliases).toContain("composeAction")
    expect(inlineMessageActions.messageActionTargetAliases?.typing?.aliases).toContain("target")
    expect(inlineMessageActions.messageActionTargetAliases?.["recording-voice"]?.aliases).toContain("chatId")
    expect(inlineMessageActions.messageActionTargetAliases?.sendAttachment?.aliases).toContain("media")
    expect(inlineMessageActions.messageActionTargetAliases?.forward?.aliases).toContain("sourceChatId")
    expect(inlineMessageActions.messageActionTargetAliases?.forwardMessages?.aliases).toContain("toUserId")
    expect(inlineMessageActions.messageActionTargetAliases?.["invite-to-space"]?.aliases).toContain("spaceId")
    expect(inlineMessageActions.messageActionTargetAliases?.inviteToSpace?.aliases).toContain("email")
    expect(inlineMessageActions.messageActionTargetAliases?.pin?.aliases).toContain("messageId")
    expect(inlineMessageActions.messageActionTargetAliases?.unpin?.aliases).toContain("threadId")
    expect(inlineMessageActions.messageActionTargetAliases?.["list-pins"]?.aliases).toContain("threadId")
  })

  it("does not advertise presentation capability when message mutations are gated off", async () => {
    vi.resetModules()
    const { inlineMessageActions } = await import("./actions")

    const discovery = inlineMessageActions.describeMessageTool?.({
      cfg: {
        channels: {
          inline: {
            token: "token",
            baseUrl: "https://api.inline.chat",
            actions: {
              send: false,
              reply: false,
              edit: false,
            },
          },
        },
      } as OpenClawConfig,
    })

    expect(discovery?.actions).not.toContain("send")
    expect(discovery?.actions).not.toContain("upload-file")
    expect(discovery?.actions).not.toContain("compose-action")
    expect(discovery?.actions).not.toContain("typing")
    expect(discovery?.actions).not.toContain("stop-typing")
    expect(discovery?.actions).not.toContain("recording-voice")
    expect(discovery?.actions).not.toContain("forward")
    expect(discovery?.actions).not.toContain("forwardMessages")
    expect(discovery?.actions).not.toContain("reply")
    expect(discovery?.actions).not.toContain("thread-reply")
    expect(discovery?.actions).not.toContain("edit")
    expect(discovery?.capabilities).toEqual([])
    expect(discovery?.schema).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          actions: ["channel-create", "thread-create"],
        }),
        expect.objectContaining({
          actions: ["translate", "translateMessages"],
        }),
      ]),
    )
  })

  it("scopes message-tool discovery to the active Inline account", async () => {
    vi.resetModules()
    const { inlineMessageActions } = await import("./actions")
    const cfg = {
      channels: {
        inline: {
          token: "default-token",
          accounts: {
            work: {
              token: "work-token",
              actions: {
                send: false,
                reply: false,
                edit: false,
              },
            },
          },
        },
      },
    } as OpenClawConfig

    const defaultDiscovery = inlineMessageActions.describeMessageTool?.({
      cfg,
      accountId: "default",
    })
    const workDiscovery = inlineMessageActions.describeMessageTool?.({
      cfg,
      accountId: "work",
    })

    expect(defaultDiscovery?.actions).toContain("send")
    expect(defaultDiscovery?.capabilities).toEqual(["presentation"])
    expect(inlineMessageActions.supportsButtons?.({ cfg, accountId: "default" })).toBe(true)
    expect(workDiscovery?.actions).not.toContain("send")
    expect(workDiscovery?.actions).not.toContain("reply")
    expect(workDiscovery?.actions).not.toContain("edit")
    expect(workDiscovery?.capabilities).toEqual([])
    expect(inlineMessageActions.supportsButtons?.({ cfg, accountId: "work" })).toBe(false)
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
    const downloadInlineMediaFromUrl = vi.fn(async () => ({
      path: "/tmp/openclaw-inline-downloads/photo.jpg",
      sourceUrl: "https://cdn.inline.chat/inbound-photo.jpg",
      fileName: "photo.jpg",
      sizeBytes: 12,
      contentType: "image/jpeg",
    }))
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
      if (method === 12) {
        return {
          oneofKind: "inviteToSpace",
          inviteToSpace: {
            user: { id: 99n, username: "new-user", firstName: "New" },
            member: {
              id: 2n,
              spaceId: 22n,
              userId: 99n,
              role: 2,
              date: 1_700_000_005n,
              canAccessPublicChats: true,
            },
          },
        }
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
      if (method === 16) {
        return {
          oneofKind: "translateMessages",
          translateMessages: {
            translations: [
              {
                messageId: 10n,
                language: "es",
                translation: "hola",
                date: 1_700_000_004n,
                msgRev: 2n,
              },
            ],
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
      if (method === 20) {
        return {
          oneofKind: "sendComposeAction",
          sendComposeAction: {},
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
      if (method === 29) {
        return {
          oneofKind: "forwardMessages",
          forwardMessages: {
            updates: [
              {
                update: {
                  oneofKind: "newMessage",
                  newMessage: {
                    message: { id: 88n },
                  },
                },
              },
            ],
          },
        }
      }
      if (method === 30) {
        return {
          oneofKind: "updateChatVisibility",
          updateChatVisibility: {
            chat: { id: 7n, title: "Renamed Thread", isPublic: false },
          },
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
      if (method === 42) {
        return {
          oneofKind: "createSubthread",
          createSubthread: {
            chat: { id: 710n, title: "Alias Thread", parentChatId: 7n, parentMessageId: 10n },
            dialog: { chatId: 710n },
            anchorMessage: sampleMessageWithReaction,
          },
        }
      }
      if (method === 45) {
        return {
          oneofKind: "getPeerBotCommands",
          getPeerBotCommands: {
            bots: [
              {
                bot: { id: 500n, username: "inline-bot", firstName: "Inline", bot: true },
                commands: [
                  { command: "threadreply", description: "Set thread reply mode", sortOrder: 10 },
                ],
              },
            ],
          },
        }
      }
      if (method === 55) {
        return {
          oneofKind: "deleteMessageAttachment",
          deleteMessageAttachment: { updates: [] },
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
        INVITE_TO_SPACE: 12,
        GET_CHAT_PARTICIPANTS: 13,
        ADD_CHAT_PARTICIPANT: 14,
        REMOVE_CHAT_PARTICIPANT: 15,
        TRANSLATE_MESSAGES: 16,
        GET_CHATS: 17,
        SEND_COMPOSE_ACTION: 20,
        GET_CHAT: 25,
        UPDATE_MEMBER_ACCESS: 27,
        FORWARD_MESSAGES: 29,
        UPDATE_CHAT_VISIBILITY: 30,
        PIN_MESSAGE: 31,
        UPDATE_CHAT_INFO: 32,
        MOVE_THREAD: 35,
        GET_MESSAGES: 38,
        CREATE_SUBTHREAD: 42,
        GET_PEER_BOT_COMMANDS: 45,
        DELETE_MESSAGE_ATTACHMENT: 55,
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
      downloadInlineMediaFromUrl,
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
      action: "upload-file",
      cfg,
      params: { to: "user:99", path: "/Users/mo/.openclaw/workspace/report.pdf", message: "file upload" },
    } as any)

    const typingResult = await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "typing",
      cfg,
      params: { to: "7" },
    } as any)

    const stopTypingResult = await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "stop-typing",
      cfg,
      params: { to: "7" },
    } as any)

    const composeActionResult = await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "compose-action",
      cfg,
      params: { to: "user:99", state: "uploadingVideo" },
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

    const deleteAttachmentResult = await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "delete-attachment",
      cfg,
      params: { to: "7", messageId: "10", attachmentId: "902" },
    } as any)

    const forwardResult = await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "forward",
      cfg,
      params: { from: "7", to: "user:99", messageIds: ["10", "11"], shareForwardHeader: false },
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
      params: { to: "7", messageId: "10", threadName: "Alias Thread", participant: "@new-user", spaceId: "22" },
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

    const visibilityEditResult = await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "channel-edit",
      cfg,
      params: { to: "7", emoji: "🔥", visibility: "private", participants: ["99"] },
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

    const spaceInviteResult = await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "invite-to-space",
      cfg,
      params: { spaceId: "22", userId: "99", role: "member", canAccessPublicChats: true },
    } as any)

    const emailInviteResult = await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "inviteToSpace",
      cfg,
      params: { spaceId: "22", email: "new@example.com", role: "admin" },
    } as any)

    await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "reactions",
      cfg,
      params: { to: "7", messageId: "10" },
    } as any)

    const translateResult = await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "translate",
      cfg,
      params: { to: "7", messageIds: ["10", "11"], language: "es" },
    } as any)

    const botCommandsResult = await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "peer-bot-commands",
      cfg,
      params: { to: "7" },
    } as any)

    expect(visibilityEditResult).toMatchObject({
      details: {
        ok: true,
        chatId: "7",
        emoji: "🔥",
        isPublic: false,
        infoUpdated: true,
        visibilityUpdated: true,
      },
    })
    expect(spaceInviteResult).toMatchObject({
      details: {
        ok: true,
        spaceId: "22",
        role: "member",
        canAccessPublicChats: true,
        invite: {
          kind: "userId",
          userId: "99",
        },
      },
    })
    expect(emailInviteResult).toMatchObject({
      details: {
        ok: true,
        spaceId: "22",
        role: "admin",
        canAccessPublicChats: null,
        invite: {
          kind: "email",
          email: "new@example.com",
        },
      },
    })
    expect(deleteAttachmentResult).toMatchObject({
      details: {
        ok: true,
        chatId: "7",
        messageId: "10",
        attachmentId: "902",
      },
    })
    expect(forwardResult).toMatchObject({
      details: {
        ok: true,
        from: "7",
        to: "user:99",
        messageIds: ["10", "11"],
        shareForwardHeader: false,
        usedCurrentChatDefault: false,
        forwardedMessageIds: ["88"],
        forwardedMessageId: "88",
      },
    })
    expect(typingResult).toMatchObject({
      details: {
        ok: true,
        target: "7",
        composeAction: "typing",
        action: "typing",
        rpcAction: 1,
        usedCurrentChatDefault: false,
      },
    })
    expect(stopTypingResult).toMatchObject({
      details: {
        ok: true,
        target: "7",
        composeAction: "none",
        action: "none",
        rpcAction: 0,
        usedCurrentChatDefault: false,
      },
    })
    expect(composeActionResult).toMatchObject({
      details: {
        ok: true,
        target: "user:99",
        composeAction: "uploading-video",
        action: "uploading-video",
        rpcAction: 4,
        usedCurrentChatDefault: false,
      },
    })
    expect(translateResult).toMatchObject({
      details: {
        ok: true,
        chatId: "7",
        messageIds: ["10", "11"],
        language: "es",
        translations: [
          {
            messageId: "10",
            language: "es",
            text: "hola",
            date: 1_700_000_004_000,
            messageRevision: "2",
          },
        ],
      },
    })
    expect(botCommandsResult).toMatchObject({
      details: {
        ok: true,
        target: "7",
        chatId: "7",
        count: 1,
        commandsCount: 1,
        bots: [
          {
            bot: {
              id: "500",
              target: "user:500",
              username: "inline-bot",
              name: "Inline",
            },
            count: 1,
            commands: [
              {
                command: "threadreply",
                description: "Set thread reply mode",
                sortOrder: 10,
              },
            ],
          },
        ],
      },
    })

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
        text: "file upload",
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
        mediaUrl: "/Users/mo/.openclaw/workspace/report.pdf",
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
      55,
      expect.objectContaining({
        oneofKind: "deleteMessageAttachment",
        deleteMessageAttachment: {
          peerId: {
            type: {
              oneofKind: "chat",
              chat: { chatId: 7n },
            },
          },
          messageId: 10n,
          attachmentId: 902n,
        },
      }),
    )
    expect(invokeRaw).toHaveBeenCalledWith(
      29,
      expect.objectContaining({
        oneofKind: "forwardMessages",
        forwardMessages: {
          fromPeerId: {
            type: {
              oneofKind: "chat",
              chat: { chatId: 7n },
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
    expect(invokeRaw).toHaveBeenCalledWith(
      20,
      expect.objectContaining({
        oneofKind: "sendComposeAction",
        sendComposeAction: {
          peerId: {
            type: {
              oneofKind: "chat",
              chat: { chatId: 7n },
            },
          },
          action: 1,
        },
      }),
    )
    expect(invokeRaw).toHaveBeenCalledWith(
      20,
      expect.objectContaining({
        oneofKind: "sendComposeAction",
        sendComposeAction: {
          peerId: {
            type: {
              oneofKind: "chat",
              chat: { chatId: 7n },
            },
          },
          action: 0,
        },
      }),
    )
    expect(invokeRaw).toHaveBeenCalledWith(
      20,
      expect.objectContaining({
        oneofKind: "sendComposeAction",
        sendComposeAction: {
          peerId: {
            type: {
              oneofKind: "user",
              user: { userId: 99n },
            },
          },
          action: 4,
        },
      }),
    )
    expect(invokeRaw).toHaveBeenCalledWith(
      45,
      expect.objectContaining({
        oneofKind: "getPeerBotCommands",
        getPeerBotCommands: {
          peerId: {
            type: {
              oneofKind: "chat",
              chat: { chatId: 7n },
            },
          },
        },
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
      42,
      expect.objectContaining({
        oneofKind: "createSubthread",
        createSubthread: expect.objectContaining({
          parentChatId: 7n,
          parentMessageId: 10n,
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
      32,
      expect.objectContaining({
        oneofKind: "updateChatInfo",
        updateChatInfo: expect.objectContaining({
          chatId: 7n,
          emoji: "🔥",
        }),
      }),
    )
    expect(invokeRaw).toHaveBeenCalledWith(
      30,
      expect.objectContaining({
        oneofKind: "updateChatVisibility",
        updateChatVisibility: {
          chatId: 7n,
          isPublic: false,
          participants: [{ userId: 99n }],
        },
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
      12,
      expect.objectContaining({
        oneofKind: "inviteToSpace",
        inviteToSpace: {
          spaceId: 22n,
          role: {
            role: {
              oneofKind: "member",
              member: {
                canAccessPublicChats: true,
              },
            },
          },
          via: {
            oneofKind: "userId",
            userId: 99n,
          },
        },
      }),
    )
    expect(invokeRaw).toHaveBeenCalledWith(
      12,
      expect.objectContaining({
        oneofKind: "inviteToSpace",
        inviteToSpace: {
          spaceId: 22n,
          role: {
            role: {
              oneofKind: "admin",
              admin: {},
            },
          },
          via: {
            oneofKind: "email",
            email: "new@example.com",
          },
        },
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
      16,
      expect.objectContaining({
        oneofKind: "translateMessages",
        translateMessages: {
          peerId: {
            type: {
              oneofKind: "chat",
              chat: { chatId: 7n },
            },
          },
          messageIds: [10n, 11n],
          language: "es",
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

  it("downloads an explicit media URL without opening the Inline client", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const close = vi.fn(async () => {})
    const downloadInlineMediaFromUrl = vi.fn(async () => ({
      path: "/tmp/openclaw-inline-downloads/report.pdf",
      sourceUrl: "https://cdn.inline.chat/report.pdf",
      fileName: "report.pdf",
      sizeBytes: 24,
      contentType: "application/pdf",
    }))

    vi.doMock("@inline-chat/realtime-sdk", () => ({
      Method: {},
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        close = close
      },
    }))
    vi.doMock("./media", () => ({
      downloadInlineMediaFromUrl,
      uploadInlineMediaFromUrl: vi.fn(),
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
      action: "download-file",
      cfg,
      params: {
        mediaUrl: "https://cdn.inline.chat/report.pdf",
        fileName: "report.pdf",
      },
    } as any)

    expect(result).toMatchObject({
      details: {
        ok: true,
        source: "explicit",
        sourceUrl: "https://cdn.inline.chat/report.pdf",
        path: "/tmp/openclaw-inline-downloads/report.pdf",
        fileName: "report.pdf",
        contentType: "application/pdf",
        media: {
          mediaUrl: "/tmp/openclaw-inline-downloads/report.pdf",
          mediaUrls: ["/tmp/openclaw-inline-downloads/report.pdf"],
          trustedLocalMedia: true,
          contentType: "application/pdf",
        },
      },
    })
    expect(downloadInlineMediaFromUrl).toHaveBeenCalledWith(
      expect.objectContaining({
        mediaUrl: "https://cdn.inline.chat/report.pdf",
        fileName: "report.pdf",
      }),
    )
    expect(connect).not.toHaveBeenCalled()
    expect(close).not.toHaveBeenCalled()
  })

  it("downloads current-message media from current Inline chat context", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const close = vi.fn(async () => {})
    const downloadInlineMediaFromUrl = vi.fn(async () => ({
      path: "/tmp/openclaw-inline-downloads/voice.ogg",
      sourceUrl: "https://cdn.inline.chat/voice.ogg",
      fileName: "voice.ogg",
      sizeBytes: 42,
      contentType: "audio/ogg",
    }))
    const invokeRaw = vi.fn(async () => ({
      oneofKind: "getMessages",
      getMessages: {
        messages: [
          {
            id: 77n,
            fromId: 42n,
            date: 1_700_000_000n,
            message: "voice caption",
            media: {
              media: {
                oneofKind: "voice",
                voice: {
                  voice: {
                    id: 555n,
                    cdnUrl: "https://cdn.inline.chat/voice.ogg",
                    mimeType: "audio/ogg",
                    size: 42,
                    duration: 3,
                  },
                },
              },
            },
          },
        ],
      },
    }))

    vi.doMock("@inline-chat/realtime-sdk", () => ({
      Method: {
        GET_MESSAGES: 38,
      },
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        close = close
        invokeRaw = invokeRaw
      },
    }))
    vi.doMock("./media", () => ({
      downloadInlineMediaFromUrl,
      uploadInlineMediaFromUrl: vi.fn(),
    }))

    const { inlineMessageActions } = await import("./actions")
    const result = await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "download-file",
      cfg: {
        channels: {
          inline: {
            token: "token",
            baseUrl: "https://api.inline.chat",
          },
        },
      } satisfies OpenClawConfig,
      params: {},
      toolContext: {
        currentChannelId: "7",
        currentMessageId: "77",
      },
    } as any)

    expect(result).toMatchObject({
      details: {
        ok: true,
        target: "7",
        chatId: "7",
        messageId: "77",
        source: "media",
        sourceId: "555",
        sourceUrl: "https://cdn.inline.chat/voice.ogg",
        path: "/tmp/openclaw-inline-downloads/voice.ogg",
        contentType: "audio/ogg",
        usedCurrentChatDefault: true,
        usedCurrentThreadDefault: false,
      },
    })
    expect(invokeRaw).toHaveBeenCalledWith(38, {
      oneofKind: "getMessages",
      getMessages: {
        peerId: {
          type: {
            oneofKind: "chat",
            chat: { chatId: 7n },
          },
        },
        messageIds: [77n],
      },
    })
    expect(downloadInlineMediaFromUrl).toHaveBeenCalledWith(
      expect.objectContaining({
        mediaUrl: "https://cdn.inline.chat/voice.ogg",
      }),
    )
    expect(connect).toHaveBeenCalled()
    expect(close).toHaveBeenCalled()
  })

  it("uses current chat and message context for forward source defaults", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const close = vi.fn(async () => {})
    const invokeRaw = vi.fn(async () => ({
      oneofKind: "forwardMessages",
      forwardMessages: {
        updates: [
          {
            update: {
              oneofKind: "newMessage",
              newMessage: {
                message: { id: 91n },
              },
            },
          },
        ],
      },
    }))

    vi.doMock("@inline-chat/realtime-sdk", () => ({
      Method: {
        FORWARD_MESSAGES: 29,
      },
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        close = close
        invokeRaw = invokeRaw
      },
    }))

    const { inlineMessageActions } = await import("./actions")
    const result = await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "forwardMessages",
      cfg: {
        channels: {
          inline: {
            token: "token",
            baseUrl: "https://api.inline.chat",
          },
        },
      } satisfies OpenClawConfig,
      params: { to: "8" },
      toolContext: {
        currentChannelId: "7",
        currentMessageId: "10",
      },
    } as any)

    expect(result).toMatchObject({
      details: {
        ok: true,
        from: "7",
        to: "8",
        messageIds: ["10"],
        shareForwardHeader: true,
        usedCurrentChatDefault: true,
        forwardedMessageIds: ["91"],
      },
    })
    expect(invokeRaw).toHaveBeenCalledWith(29, {
      oneofKind: "forwardMessages",
      forwardMessages: {
        fromPeerId: {
          type: {
            oneofKind: "chat",
            chat: { chatId: 7n },
          },
        },
        toPeerId: {
          type: {
            oneofKind: "chat",
            chat: { chatId: 8n },
          },
        },
        messageIds: [10n],
      },
    })
    expect(connect).toHaveBeenCalled()
    expect(close).toHaveBeenCalled()
  })

  it("suppresses copied OpenClaw runtime text in send actions", async () => {
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
    const result = await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "send",
      cfg: {
        channels: {
          inline: {
            token: "token",
            baseUrl: "https://api.inline.chat",
          },
        },
      } satisfies OpenClawConfig,
      params: {
        to: "user:99",
        message: [
          "OpenClaw runtime context for the immediately preceding user message.",
          "This context is runtime-generated, not user-authored. Keep internal details private.",
          "",
          "Read HEARTBEAT.md if it exists. If nothing needs attention, reply HEARTBEAT_OK.",
        ].join("\n"),
      },
    } as any)

    expect(result).toMatchObject({
      details: {
        ok: false,
        reason: "suppressed_internal_context",
      },
    })
    expect(connect).toHaveBeenCalled()
    expect(sendMessage).not.toHaveBeenCalled()
    expect(close).toHaveBeenCalled()
  })

  it("rejects ambiguous space invite targets before dispatching the RPC", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const close = vi.fn(async () => {})
    const invokeRaw = vi.fn(async () => ({ oneofKind: "inviteToSpace", inviteToSpace: {} }))

    vi.doMock("@inline-chat/realtime-sdk", () => ({
      Method: {
        INVITE_TO_SPACE: 12,
      },
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        close = close
        invokeRaw = invokeRaw
      },
    }))

    const { inlineMessageActions } = await import("./actions")

    await expect(
      inlineMessageActions.handleAction?.({
        channel: "inline",
        action: "invite-to-space",
        cfg: {
          channels: {
            inline: {
              token: "token",
              baseUrl: "https://api.inline.chat",
            },
          },
        } satisfies OpenClawConfig,
        params: {
          spaceId: "22",
          userId: "99",
          email: "new@example.com",
        },
      } as any),
    ).rejects.toThrow("inline action: invite-to-space accepts only one invite target")

    expect(connect).toHaveBeenCalled()
    expect(invokeRaw).not.toHaveBeenCalled()
    expect(close).toHaveBeenCalled()
  })

  it("rejects delete-attachment without an attachment id before dispatching the RPC", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const close = vi.fn(async () => {})
    const invokeRaw = vi.fn(async () => ({ oneofKind: "deleteMessageAttachment", deleteMessageAttachment: {} }))

    vi.doMock("@inline-chat/realtime-sdk", () => ({
      Method: {
        DELETE_MESSAGE_ATTACHMENT: 55,
      },
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        close = close
        invokeRaw = invokeRaw
      },
    }))

    const { inlineMessageActions } = await import("./actions")

    await expect(
      inlineMessageActions.handleAction?.({
        channel: "inline",
        action: "delete-attachment",
        cfg: {
          channels: {
            inline: {
              token: "token",
              baseUrl: "https://api.inline.chat",
            },
          },
        } satisfies OpenClawConfig,
        params: {
          to: "7",
          messageId: "10",
        },
      } as any),
    ).rejects.toThrow("missing attachmentId")

    expect(connect).toHaveBeenCalled()
    expect(invokeRaw).not.toHaveBeenCalled()
    expect(close).toHaveBeenCalled()
  })

  it("strips copied OpenClaw runtime captions in attachment actions", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const close = vi.fn(async () => {})
    const sendMessage = vi.fn(async () => ({ messageId: 88n }))
    const uploadInlineMediaFromUrl = vi.fn(async () => ({ kind: "photo", photoId: 901n }))
    const downloadInlineMediaFromUrl = vi.fn()

    vi.doMock("@inline-chat/realtime-sdk", () => ({
      Method: {},
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        close = close
        sendMessage = sendMessage
      },
    }))
    vi.doMock("./media", () => ({
      downloadInlineMediaFromUrl,
      uploadInlineMediaFromUrl,
    }))

    const { inlineMessageActions } = await import("./actions")
    await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "sendAttachment",
      cfg: {
        channels: {
          inline: {
            token: "token",
            baseUrl: "https://api.inline.chat",
          },
        },
      } satisfies OpenClawConfig,
      params: {
        to: "user:99",
        mediaUrl: "https://example.com/image.png",
        caption: [
          "OpenClaw runtime event.",
          "This context is runtime-generated, not user-authored. Keep internal details private.",
          "",
          "Read HEARTBEAT.md if it exists. If nothing needs attention, reply HEARTBEAT_OK.",
        ].join("\n"),
      },
    } as any)

    expect(sendMessage).toHaveBeenCalledWith(
      expect.objectContaining({
        userId: 99n,
        media: { kind: "photo", photoId: 901n },
      }),
    )
    expect(sendMessage).not.toHaveBeenCalledWith(expect.objectContaining({ text: expect.any(String) }))
  })

  it("passes media access through attachment actions", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const close = vi.fn(async () => {})
    const sendMessage = vi.fn(async () => ({ messageId: 88n }))
    const uploadInlineMediaFromUrl = vi.fn(async () => ({ kind: "photo", photoId: 901n }))
    const downloadInlineMediaFromUrl = vi.fn()
    const mediaReadFile = vi.fn(async () => Buffer.from([1, 2, 3]))
    const mediaAccess = {
      localRoots: ["/tmp/inline-media"],
      readFile: mediaReadFile,
    }

    vi.doMock("@inline-chat/realtime-sdk", () => ({
      Method: {},
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        close = close
        sendMessage = sendMessage
      },
    }))
    vi.doMock("./media", () => ({
      downloadInlineMediaFromUrl,
      uploadInlineMediaFromUrl,
    }))

    const { inlineMessageActions } = await import("./actions")
    await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "sendAttachment",
      cfg: {
        channels: {
          inline: {
            token: "token",
            baseUrl: "https://api.inline.chat",
          },
        },
      } satisfies OpenClawConfig,
      params: {
        to: "user:99",
        mediaUrl: "/tmp/inline-media/photo.png",
        caption: "photo",
      },
      mediaAccess,
    } as any)

    expect(uploadInlineMediaFromUrl).toHaveBeenCalledWith(
      expect.objectContaining({
        mediaUrl: "/tmp/inline-media/photo.png",
        mediaAccess,
      }),
    )
    expect(sendMessage).toHaveBeenCalledWith(
      expect.objectContaining({
        userId: 99n,
        media: { kind: "photo", photoId: 901n },
      }),
    )
  })

  it("rejects copied OpenClaw runtime text in channel titles", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const close = vi.fn(async () => {})
    const invokeRaw = vi.fn(async () => ({
      oneofKind: "updateChatInfo",
      updateChatInfo: { chat: { id: 7n, title: "should not happen" } },
    }))

    vi.doMock("@inline-chat/realtime-sdk", () => ({
      Method: {
        UPDATE_CHAT_INFO: 32,
      },
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        close = close
        invokeRaw = invokeRaw
      },
    }))

    const { inlineMessageActions } = await import("./actions")
    await expect(
      inlineMessageActions.handleAction?.({
        channel: "inline",
        action: "channel-edit",
        cfg: {
          channels: {
            inline: {
              token: "token",
              baseUrl: "https://api.inline.chat",
            },
          },
        } satisfies OpenClawConfig,
        params: {
          to: "7",
          title: [
            "OpenClaw runtime context for the immediately preceding user message.",
            "This context is runtime-generated, not user-authored. Keep internal details private.",
            "",
            "Read HEARTBEAT.md if it exists. If nothing needs attention, reply HEARTBEAT_OK.",
          ].join("\n"),
        },
      } as any),
    ).rejects.toThrow(/title contains internal runtime text/)

    expect(connect).toHaveBeenCalled()
    expect(invokeRaw).not.toHaveBeenCalled()
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

    const result = await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "react",
      cfg,
      params: { emoji: "✔️" },
      toolContext: {
        currentChannelId: "7",
        currentMessageId: "322",
      },
    } as any)

    expect(result).toMatchObject({
      details: {
        ok: true,
        chatId: "7",
        messageId: "322",
        emoji: "✔️",
        usedCurrentChatDefault: true,
        usedCurrentThreadDefault: false,
      },
    })
    expect(invokeRaw).toHaveBeenCalledWith(
      6,
      expect.objectContaining({
        oneofKind: "addReaction",
        addReaction: expect.objectContaining({
          peerId: {
            type: {
              oneofKind: "chat",
              chat: { chatId: 7n },
            },
          },
          messageId: 322n,
        }),
      }),
    )
  })

  it("uses current Inline thread context for listing reactions", async () => {
    vi.resetModules()

    const invokeRaw = vi.fn(async (method: number) => {
      if (method === 38) {
        return {
          oneofKind: "getMessages",
          getMessages: {
            messages: [
              {
                id: 322n,
                reactions: {
                  reactions: [
                    {
                      emoji: "✔️",
                      userId: 42n,
                      messageId: 322n,
                      chatId: 710n,
                      date: 1_700_000_000n,
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

    const result = await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "reactions",
      cfg,
      params: {},
      toolContext: {
        currentChannelId: "7",
        currentThreadTs: "710",
        currentMessageId: "322",
      },
    } as any)

    expect(result).toMatchObject({
      details: {
        ok: true,
        chatId: "710",
        messageId: "322",
        usedCurrentChatDefault: false,
        usedCurrentThreadDefault: true,
        reactions: [
          {
            emoji: "✔️",
            userIds: ["42"],
            count: 1,
          },
        ],
      },
    })
    expect(invokeRaw).toHaveBeenCalledWith(
      38,
      expect.objectContaining({
        oneofKind: "getMessages",
        getMessages: expect.objectContaining({
          peerId: {
            type: {
              oneofKind: "chat",
              chat: { chatId: 710n },
            },
          },
          messageIds: [322n],
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

  it("supports read history modes and current reply-thread targeting", async () => {
    vi.resetModules()

    const invokeRaw = vi.fn(async (method: number) => {
      if (method === 5) {
        return {
          oneofKind: "getChatHistory",
          getChatHistory: {
            messages: [
              {
                id: 11n,
                fromId: 42n,
                date: 1_700_000_001n,
                message: "newer",
                out: false,
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

    const aroundResult = await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "read",
      cfg,
      params: {
        messageId: "10",
        beforeLimit: 2,
        afterLimit: 0,
        includeAnchor: false,
        limit: 8,
      },
      toolContext: {
        currentChannelId: "7",
        currentThreadTs: "710",
      },
    } as any)

    const newerResult = await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "read",
      cfg,
      params: { to: "7", after: "10", limit: 5 },
    } as any)

    expect(aroundResult).toMatchObject({
      details: {
        ok: true,
        target: "710",
        chatId: "710",
        threadId: "710",
        mode: "around",
        limit: 8,
        anchorId: "10",
        includeAnchor: false,
        usedCurrentThreadDefault: true,
      },
    })
    expect(newerResult).toMatchObject({
      details: {
        ok: true,
        target: "7",
        chatId: "7",
        mode: "newer",
        limit: 5,
        afterId: "10",
        usedCurrentThreadDefault: false,
      },
    })
    expect(invokeRaw).toHaveBeenCalledWith(5, {
      oneofKind: "getChatHistory",
      getChatHistory: {
        peerId: {
          type: {
            oneofKind: "chat",
            chat: { chatId: 710n },
          },
        },
        mode: 4,
        anchorId: 10n,
        limit: 8,
        beforeLimit: 2,
        afterLimit: 0,
        includeAnchor: false,
      },
    })
    expect(invokeRaw).toHaveBeenCalledWith(5, {
      oneofKind: "getChatHistory",
      getChatHistory: {
        peerId: {
          type: {
            oneofKind: "chat",
            chat: { chatId: 7n },
          },
        },
        mode: 3,
        afterId: 10n,
        limit: 5,
      },
    })
  })

  it("fetches exact messages by id with reply-thread targeting", async () => {
    vi.resetModules()

    const invokeRaw = vi.fn(async (method: number) => {
      if (method === 38) {
        return {
          oneofKind: "getMessages",
          getMessages: {
            messages: [
              {
                id: 10n,
                fromId: 42n,
                date: 1_700_000_001n,
                message: "first",
                out: false,
              },
              {
                id: 11n,
                fromId: 43n,
                date: 1_700_000_002n,
                message: "second",
                out: true,
              },
            ],
          },
        }
      }
      throw new Error(`unexpected method ${String(method)}`)
    })

    vi.doMock("@inline-chat/realtime-sdk", () => ({
      Method: {
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

    const result = await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "get-messages",
      cfg: {
        channels: {
          inline: {
            token: "token",
            baseUrl: "https://api.inline.chat",
          },
        },
      } satisfies OpenClawConfig,
      params: { messageIds: ["10", "11", "10"] },
      toolContext: {
        currentChannelId: "7",
        currentThreadTs: "710",
      },
    } as any)

    expect(result).toMatchObject({
      details: {
        ok: true,
        target: "710",
        chatId: "710",
        threadId: "710",
        messageIds: ["10", "11"],
        usedCurrentThreadDefault: true,
        messages: [
          expect.objectContaining({ id: "10", text: "first" }),
          expect.objectContaining({ id: "11", text: "second" }),
        ],
      },
    })
    expect(invokeRaw).toHaveBeenCalledWith(38, {
      oneofKind: "getMessages",
      getMessages: {
        peerId: {
          type: {
            oneofKind: "chat",
            chat: { chatId: 710n },
          },
        },
        messageIds: [10n, 11n],
      },
    })
  })

  it("rejects read before and after cursors before dispatching history", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const close = vi.fn(async () => {})
    const invokeRaw = vi.fn(async () => ({ oneofKind: "getChatHistory", getChatHistory: { messages: [] } }))

    vi.doMock("@inline-chat/realtime-sdk", () => ({
      Method: {
        GET_CHAT_HISTORY: 5,
      },
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        close = close
        invokeRaw = invokeRaw
      },
    }))

    const { inlineMessageActions } = await import("./actions")

    await expect(
      inlineMessageActions.handleAction?.({
        channel: "inline",
        action: "read",
        cfg: {
          channels: {
            inline: {
              token: "token",
              baseUrl: "https://api.inline.chat",
            },
          },
        } satisfies OpenClawConfig,
        params: {
          to: "7",
          before: "10",
          after: "11",
        },
      } as any),
    ).rejects.toThrow("inline action: read accepts only one of before or after")

    expect(connect).toHaveBeenCalled()
    expect(invokeRaw).not.toHaveBeenCalled()
    expect(close).toHaveBeenCalled()
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
                      id: 920n,
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
                id: "920",
                urlPreviewId: "902",
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

  it("rejects attachment upload actions when no media source is provided", async () => {
    vi.resetModules()

    const sendMessage = vi.fn(async () => ({ messageId: 1n }))
    const connect = vi.fn(async () => {})
    const close = vi.fn(async () => {})
    const uploadInlineMediaFromUrl = vi.fn(async () => ({ kind: "photo", photoId: 901n }))
    const downloadInlineMediaFromUrl = vi.fn()

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
      downloadInlineMediaFromUrl,
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

    for (const action of ["sendAttachment", "upload-file"] as const) {
      await expect(
        inlineMessageActions.handleAction?.({
          channel: "inline",
          action,
          cfg,
          params: { to: "user:99", caption: "missing media" },
        } as any),
      ).rejects.toThrow(`inline action: ${action} requires media/file input`)
    }

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

  it("uses shared interactive labels as send fallback text when text is omitted", async () => {
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
        interactive: {
          blocks: [
            {
              type: "buttons",
              buttons: [{ label: "Approve", value: "approve", style: "success" }],
            },
          ],
        },
      },
    } as any)

    expect(sendMessage).toHaveBeenCalledWith(
      expect.objectContaining({
        userId: 99n,
        text: "- Approve",
        actions: expect.objectContaining({
          rows: [
            expect.objectContaining({
              actions: [
                expect.objectContaining({
                  text: "Approve",
                }),
              ],
            }),
          ],
        }),
      }),
    )
  })

  it("sanitizes Inline-specific visible action text before sending", async () => {
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
        text: "See `https://example.com/docs`.\n\n/focus - Bind this thread (Discord) or topic/conversation (Telegram) to a session target.",
      },
    } as any)

    expect(sendMessage).toHaveBeenCalledWith(
      expect.objectContaining({
        userId: 99n,
        text: "See https://example.com/docs.\n\n/focus - Bind this Inline conversation to a session target.",
      }),
    )
  })

  it("skips shared interactive buttons without callback values", async () => {
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
        message: "with partial interactive",
        interactive: {
          blocks: [
            {
              type: "buttons",
              buttons: [
                { label: "Missing value" },
                { label: "Approve", value: "approve" },
              ],
            },
          ],
        },
      },
    } as any)

    const actions = sendMessage.mock.calls[0]?.[0]?.actions
    expect(actions?.rows).toHaveLength(1)
    expect(actions?.rows?.[0]?.actions).toHaveLength(1)
    expect(actions?.rows?.[0]?.actions?.[0]?.text).toBe("Approve")
    const data = actions?.rows?.[0]?.actions?.[0]?.action?.callback?.data
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

  it("requires threadId for thread-reply", async () => {
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
            },
          },
        } as OpenClawConfig,
        params: {
          message: "thread reply body",
        },
      } as any),
    ).rejects.toThrow("inline thread-reply: threadId is required")
  })

  it("sends thread-reply into the child reply-thread chat", async () => {
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

  it("uses current reply-thread context for thread-reply when threadId is omitted", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const close = vi.fn(async () => {})
    const sendMessage = vi.fn(async () => ({ messageId: 89n }))

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

    const result = await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "thread-reply",
      cfg: {
        channels: {
          inline: {
            token: "token",
            baseUrl: "https://api.inline.chat",
          },
        },
      } as OpenClawConfig,
      params: {
        message: "thread context reply",
      },
      toolContext: {
        currentThreadTs: "77",
      },
    } as any)

    expect(sendMessage).toHaveBeenCalledWith(
      expect.objectContaining({
        chatId: 77n,
        text: "thread context reply",
      }),
    )
    expect(result).toMatchObject({
      details: {
        ok: true,
        threadId: "77",
        resolvedBy: "current-thread",
      },
    })
  })

  it("resolves thread-reply through a saved parent message route", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const close = vi.fn(async () => {})
    const sendMessage = vi.fn(async () => ({ messageId: 90n }))
    const invokeRaw = vi.fn(async (method: number) => {
      if (method !== 42) {
        throw new Error(`unexpected method ${String(method)}`)
      }
      return {
        oneofKind: "createSubthread",
        createSubthread: {
          chat: { id: 770n, title: "Route thread", parentChatId: 70n, parentMessageId: 700n },
          dialog: { chatId: 770n },
          anchorMessage: { id: 700n, fromId: 42n, message: "anchor" },
        },
      }
    })

    vi.doMock("@inline-chat/realtime-sdk", () => ({
      Method: {
        CREATE_SUBTHREAD: 42,
      },
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        close = close
        sendMessage = sendMessage
        invokeRaw = invokeRaw
      },
    }))

    const register = vi.fn(async () => {})
    const openKeyedStore = vi.fn(() => ({ register, lookup: vi.fn(async () => undefined) }))
    const { clearInlineRuntime, setInlineRuntime } = await import("../runtime")
    setInlineRuntime({
      state: {
        resolveStateDir: () => "/tmp/openclaw-inline-actions-test",
        openKeyedStore,
      },
      logging: {
        getChildLogger: () => ({ warn: vi.fn() }),
      },
    } as any)

    const { inlineMessageActions } = await import("./actions")

    try {
      await inlineMessageActions.handleAction?.({
        channel: "inline",
        action: "thread-create",
        cfg: {
          channels: {
            inline: {
              token: "token",
              baseUrl: "https://api.inline.chat",
            },
          },
        } as OpenClawConfig,
        params: {
          to: "70",
          parentMessageId: "700",
          threadName: "Route thread",
        },
      } as any)

      const result = await inlineMessageActions.handleAction?.({
        channel: "inline",
        action: "thread-reply",
        cfg: {
          channels: {
            inline: {
              token: "token",
              baseUrl: "https://api.inline.chat",
            },
          },
        } as OpenClawConfig,
        params: {
          to: "70",
          parentMessageId: "700",
          message: "reply through route",
          __agentId: "main",
        },
      } as any)

      expect(sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 770n,
          text: "reply through route",
        }),
      )
      expect(sendMessage).not.toHaveBeenCalledWith(
        expect.objectContaining({
          replyToMsgId: 700n,
        }),
      )
      expect(register).toHaveBeenCalledWith(
        "default:70:770",
        expect.objectContaining({
          agentId: "main",
          repliedAt: expect.any(Number),
        }),
        { ttlMs: 86_400_000 },
      )
      expect(result).toMatchObject({
        details: {
          ok: true,
          threadId: "770",
          resolvedBy: "route",
          parentChatId: "70",
          parentMessageId: "700",
        },
      })
    } finally {
      clearInlineRuntime()
    }
  })

  it("records participation for explicit threadId replies when route metadata exists", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const close = vi.fn(async () => {})
    const sendMessage = vi.fn(async () => ({ messageId: 92n }))
    const invokeRaw = vi.fn(async (method: number) => {
      if (method !== 42) {
        throw new Error(`unexpected method ${String(method)}`)
      }
      return {
        oneofKind: "createSubthread",
        createSubthread: {
          chat: { id: 780n, title: "Route thread", parentChatId: 70n, parentMessageId: 700n },
          dialog: { chatId: 780n },
          anchorMessage: { id: 700n, fromId: 42n, message: "anchor" },
        },
      }
    })

    vi.doMock("@inline-chat/realtime-sdk", () => ({
      Method: {
        CREATE_SUBTHREAD: 42,
      },
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        close = close
        sendMessage = sendMessage
        invokeRaw = invokeRaw
      },
    }))

    const register = vi.fn(async () => {})
    const openKeyedStore = vi.fn(() => ({ register, lookup: vi.fn(async () => undefined) }))
    const { clearInlineRuntime, setInlineRuntime } = await import("../runtime")
    setInlineRuntime({
      state: {
        resolveStateDir: () => "/tmp/openclaw-inline-actions-test",
        openKeyedStore,
      },
      logging: {
        getChildLogger: () => ({ warn: vi.fn() }),
      },
    } as any)

    const { inlineMessageActions } = await import("./actions")

    try {
      await inlineMessageActions.handleAction?.({
        channel: "inline",
        action: "thread-create",
        cfg: {
          channels: {
            inline: {
              token: "token",
              baseUrl: "https://api.inline.chat",
            },
          },
        } as OpenClawConfig,
        params: {
          to: "70",
          parentMessageId: "700",
          threadName: "Route thread",
        },
      } as any)

      const result = await inlineMessageActions.handleAction?.({
        channel: "inline",
        action: "thread-reply",
        cfg: {
          channels: {
            inline: {
              token: "token",
              baseUrl: "https://api.inline.chat",
            },
          },
        } as OpenClawConfig,
        params: {
          threadId: "780",
          message: "reply through explicit thread id",
          __agentId: "main",
        },
      } as any)

      expect(sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          chatId: 780n,
          text: "reply through explicit thread id",
        }),
      )
      expect(register).toHaveBeenCalledWith(
        "default:70:780",
        expect.objectContaining({
          agentId: "main",
          repliedAt: expect.any(Number),
        }),
        { ttlMs: 86_400_000 },
      )
      expect(result).toMatchObject({
        details: {
          ok: true,
          threadId: "780",
          resolvedBy: "threadId",
          parentChatId: "70",
          parentMessageId: "700",
        },
      })
    } finally {
      clearInlineRuntime()
    }
  })

  it("keeps active thread-reply routes isolated per agent when agent metadata is present", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const close = vi.fn(async () => {})
    const sendMessage = vi.fn(async () => ({ messageId: 90n }))
    const createdThreadIds = [8801n, 8802n]
    const invokeRaw = vi.fn(async (method: number) => {
      if (method !== 42) {
        throw new Error(`unexpected method ${String(method)}`)
      }
      const id = createdThreadIds.shift()
      if (id == null) {
        throw new Error("unexpected createSubthread call")
      }
      return {
        oneofKind: "createSubthread",
        createSubthread: {
          chat: { id, title: `Route thread ${String(id)}`, parentChatId: 8800n },
          dialog: { chatId: id },
        },
      }
    })

    vi.doMock("@inline-chat/realtime-sdk", () => ({
      Method: {
        CREATE_SUBTHREAD: 42,
      },
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        close = close
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
    } as OpenClawConfig

    await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "thread-create",
      cfg,
      params: {
        to: "8800",
        threadName: "Alpha route thread",
        __agentId: "alpha",
      },
    } as any)

    await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "thread-create",
      cfg,
      params: {
        to: "8800",
        threadName: "Beta route thread",
        __agentId: "beta",
      },
    } as any)

    const alphaResult = await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "thread-reply",
      cfg,
      params: {
        to: "8800",
        message: "alpha follow-up",
        __agentId: "alpha",
      },
    } as any)

    const betaResult = await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "thread-reply",
      cfg,
      params: {
        to: "8800",
        message: "beta follow-up",
        __agentId: "beta",
      },
    } as any)

    expect(sendMessage).toHaveBeenNthCalledWith(
      1,
      expect.objectContaining({
        chatId: 8801n,
        text: "alpha follow-up",
      }),
    )
    expect(sendMessage).toHaveBeenNthCalledWith(
      2,
      expect.objectContaining({
        chatId: 8802n,
        text: "beta follow-up",
      }),
    )
    expect(alphaResult).toMatchObject({
      details: {
        ok: true,
        threadId: "8801",
        resolvedBy: "route",
        parentChatId: "8800",
      },
    })
    expect(betaResult).toMatchObject({
      details: {
        ok: true,
        threadId: "8802",
        resolvedBy: "route",
        parentChatId: "8800",
      },
    })
  })

  it("falls back to active thread-reply route when inherited message context has no route", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const close = vi.fn(async () => {})
    const sendMessage = vi.fn(async () => ({ messageId: 91n }))
    const invokeRaw = vi.fn(async (method: number) => {
      if (method !== 42) {
        throw new Error(`unexpected method ${String(method)}`)
      }
      return {
        oneofKind: "createSubthread",
        createSubthread: {
          chat: { id: 9901n, title: "Active route thread", parentChatId: 9900n },
          dialog: { chatId: 9901n },
        },
      }
    })

    vi.doMock("@inline-chat/realtime-sdk", () => ({
      Method: {
        CREATE_SUBTHREAD: 42,
      },
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        close = close
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
    } as OpenClawConfig

    await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "thread-create",
      cfg,
      params: {
        to: "9900",
        threadName: "Active route thread",
      },
    } as any)

    const result = await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "thread-reply",
      cfg,
      params: {
        to: "9900",
        message: "reply through active route",
      },
      toolContext: {
        currentMessageId: "990099",
      },
    } as any)

    expect(sendMessage).toHaveBeenCalledWith(
      expect.objectContaining({
        chatId: 9901n,
        text: "reply through active route",
      }),
    )
    expect(result).toMatchObject({
      details: {
        ok: true,
        threadId: "9901",
        resolvedBy: "route",
        parentChatId: "9900",
        parentMessageId: null,
      },
    })
  })

  it("uses createSubthread for thread-create", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const close = vi.fn(async () => {})
    const getMe = vi.fn(async () => ({ userId: 500n, firstName: "Inline", username: "inline-bot" }))
    const invokeRaw = vi.fn(async (method: number) => {
      if (method !== 42) {
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
        CREATE_SUBTHREAD: 42,
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
      42,
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

  it("uses current inbound message id for thread-create when no parent id is provided", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const close = vi.fn(async () => {})
    const getMe = vi.fn(async () => ({ userId: 500n, firstName: "Inline", username: "inline-bot" }))
    const invokeRaw = vi.fn(async (method: number) => {
      if (method !== 42) {
        throw new Error(`unexpected method ${String(method)}`)
      }
      return {
        oneofKind: "createSubthread",
        createSubthread: {
          chat: { id: 715n, title: "Follow-up thread", parentChatId: 7n, parentMessageId: 15n },
          dialog: { chatId: 715n },
          anchorMessage: { id: 15n, fromId: 42n, message: "anchor" },
        },
      }
    })

    vi.doMock("@inline-chat/realtime-sdk", () => ({
      Method: {
        CREATE_SUBTHREAD: 42,
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
            },
          },
        } as OpenClawConfig,
      params: {
        to: "7",
        threadName: "Follow-up thread",
      },
      toolContext: {
        currentMessageId: "15",
      },
    } as any)

    expect(invokeRaw).toHaveBeenCalledWith(
      42,
      expect.objectContaining({
        oneofKind: "createSubthread",
        createSubthread: expect.objectContaining({
          parentChatId: 7n,
          parentMessageId: 15n,
          title: "Follow-up thread",
        }),
      }),
    )
  })

  it("creates a public top-level space thread with thread-create", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const close = vi.fn(async () => {})
    const invokeRaw = vi.fn(async (method: number) => {
      if (method !== 9) {
        throw new Error(`unexpected method ${String(method)}`)
      }
      return {
        oneofKind: "createChat",
        createChat: {
          chat: { id: 81n, title: "Space thread", spaceId: 22n, isPublic: true },
          dialog: { chatId: 81n, spaceId: 22n },
        },
      }
    })

    vi.doMock("@inline-chat/realtime-sdk", () => ({
      Method: {
        CREATE_CHAT: 9,
        CREATE_SUBTHREAD: 42,
      },
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        close = close
        invokeRaw = invokeRaw
      },
    }))

    const { inlineMessageActions } = await import("./actions")

    const result = await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "thread-create",
      cfg: {
        channels: {
          inline: {
            token: "token",
            baseUrl: "https://api.inline.chat",
          },
        },
      } as OpenClawConfig,
      params: {
        spaceId: "22",
        threadName: "Space thread",
      },
    } as any)

    expect(invokeRaw).toHaveBeenCalledWith(
      9,
      expect.objectContaining({
        oneofKind: "createChat",
        createChat: expect.objectContaining({
          title: "Space thread",
          spaceId: 22n,
          isPublic: true,
          participants: [],
        }),
      }),
    )
    expect(result).toMatchObject({
      details: {
        ok: true,
        mode: "top-level",
        isPublic: true,
        spaceId: "22",
      },
    })
  })

  it("creates a private top-level thread with participants using thread-create", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const close = vi.fn(async () => {})
    const invokeRaw = vi.fn(async (method: number) => {
      if (method !== 9) {
        throw new Error(`unexpected method ${String(method)}`)
      }
      return {
        oneofKind: "createChat",
        createChat: {
          chat: { id: 82n, title: "Private thread", isPublic: false },
          dialog: { chatId: 82n },
        },
      }
    })

    vi.doMock("@inline-chat/realtime-sdk", () => ({
      Method: {
        CREATE_CHAT: 9,
        CREATE_SUBTHREAD: 42,
      },
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        close = close
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
          },
        },
      } as OpenClawConfig,
      params: {
        participant: "99,100",
        threadName: "Private thread",
      },
      toolContext: {
        currentChannelId: "7",
        currentMessageId: "10",
      },
    } as any)

    expect(invokeRaw).toHaveBeenCalledWith(
      9,
      expect.objectContaining({
        oneofKind: "createChat",
        createChat: expect.objectContaining({
          title: "Private thread",
          isPublic: false,
          participants: [{ userId: 99n }, { userId: 100n }],
        }),
      }),
    )
  })

  it("keeps participant thread-create top-level when optional placeholders and parent aliases are over-filled", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const close = vi.fn(async () => {})
    const invokeRaw = vi.fn(async (method: number) => {
      if (method !== 9) {
        throw new Error(`unexpected method ${String(method)}`)
      }
      return {
        oneofKind: "createChat",
        createChat: {
          chat: { id: 83n, title: "cool", isPublic: false },
          dialog: { chatId: 83n },
        },
      }
    })

    vi.doMock("@inline-chat/realtime-sdk", () => ({
      Method: {
        CREATE_CHAT: 9,
        CREATE_SUBTHREAD: 42,
      },
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        close = close
        invokeRaw = invokeRaw
      },
    }))

    const { inlineMessageActions } = await import("./actions")

    const result = await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "thread-create",
      cfg: {
        channels: {
          inline: {
            token: "token",
            baseUrl: "https://api.inline.chat",
          },
        },
      } as OpenClawConfig,
      params: {
        target: "chat:570",
        to: "chat:570",
        chatId: "570",
        channelId: "inline:570",
        message: "cool",
        spaceId: "x",
        space: "x",
        threadId: "x",
        replyTo: "149",
        replyToId: "149",
        messageId: "149",
        parentMessageId: "149",
        anchorMessageId: "149",
        isPublic: false,
        participant: "10000",
        participants: "10000",
        participantId: "10000",
        participantIds: "10000",
        userId: "10000",
        userIds: "10000",
      },
      toolContext: {
        currentChannelId: "570",
        currentMessageId: "149",
      },
    } as any)

    expect(invokeRaw).toHaveBeenCalledTimes(1)
    expect(invokeRaw).toHaveBeenCalledWith(
      9,
      expect.objectContaining({
        oneofKind: "createChat",
        createChat: expect.objectContaining({
          title: "cool",
          isPublic: false,
          participants: [{ userId: 10000n }],
        }),
      }),
    )
    expect(result).toMatchObject({
      details: {
        ok: true,
        mode: "top-level",
        title: "cool",
        isPublic: false,
        spaceId: null,
        participants: ["10000"],
      },
    })
  })

  it("uses current Inline context for message pin actions", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const close = vi.fn(async () => {})
    const invokeRaw = vi.fn(async (method: number) => {
      if (method === 25) {
        return {
          oneofKind: "getChat",
          getChat: {
            chat: { id: 710n, title: "Thread" },
            dialog: { chatId: 710n },
            pinnedMessageIds: [11n, 12n],
          },
        }
      }
      if (method === 31) {
        return {
          oneofKind: "pinMessage",
          pinMessage: { updates: [] },
        }
      }
      throw new Error(`unexpected method ${String(method)}`)
    })

    vi.doMock("@inline-chat/realtime-sdk", () => ({
      Method: {
        GET_CHAT: 25,
        PIN_MESSAGE: 31,
      },
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        close = close
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

    const pinResult = await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "pin",
      cfg,
      params: { messageId: "10" },
      toolContext: {
        currentChannelId: "7",
      },
    } as any)

    const unpinResult = await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "unpin",
      cfg,
      params: {},
      toolContext: {
        currentChannelId: "7",
        currentMessageId: "11",
      },
    } as any)

    const listPinsResult = await inlineMessageActions.handleAction?.({
      channel: "inline",
      action: "list-pins",
      cfg,
      params: {},
      toolContext: {
        currentChannelId: "7",
        currentThreadTs: "710",
      },
    } as any)

    expect(pinResult).toMatchObject({
      details: {
        ok: true,
        chatId: "7",
        messageId: "10",
        unpin: false,
        usedCurrentChatDefault: true,
        usedCurrentThreadDefault: false,
      },
    })
    expect(unpinResult).toMatchObject({
      details: {
        ok: true,
        chatId: "7",
        messageId: "11",
        unpin: true,
        usedCurrentChatDefault: true,
        usedCurrentThreadDefault: false,
      },
    })
    expect(listPinsResult).toMatchObject({
      details: {
        ok: true,
        chatId: "710",
        pinnedMessageIds: ["11", "12"],
        usedCurrentChatDefault: false,
        usedCurrentThreadDefault: true,
      },
    })

    expect(invokeRaw).toHaveBeenCalledWith(
      31,
      expect.objectContaining({
        pinMessage: expect.objectContaining({
          peerId: {
            type: {
              oneofKind: "chat",
              chat: { chatId: 7n },
            },
          },
          messageId: 10n,
          unpin: false,
        }),
      }),
    )
    expect(invokeRaw).toHaveBeenCalledWith(
      31,
      expect.objectContaining({
        pinMessage: expect.objectContaining({
          peerId: {
            type: {
              oneofKind: "chat",
              chat: { chatId: 7n },
            },
          },
          messageId: 11n,
          unpin: true,
        }),
      }),
    )
    expect(invokeRaw).toHaveBeenCalledWith(
      25,
      expect.objectContaining({
        getChat: {
          peerId: {
            type: {
              oneofKind: "chat",
              chat: { chatId: 710n },
            },
          },
        },
      }),
    )
  })

  it("uses current channel for thread-create only when an anchor message is explicit", async () => {
    vi.resetModules()

    const connect = vi.fn(async () => {})
    const close = vi.fn(async () => {})
    const invokeRaw = vi.fn(async (method: number) => {
      if (method !== 42) {
        throw new Error(`unexpected method ${String(method)}`)
      }
      return {
        oneofKind: "createSubthread",
        createSubthread: {
          chat: { id: 716n, title: "Anchored follow-up", parentChatId: 7n, parentMessageId: 10n },
          dialog: { chatId: 716n },
          anchorMessage: { id: 10n, fromId: 42n, message: "anchor" },
        },
      }
    })

    vi.doMock("@inline-chat/realtime-sdk", () => ({
      Method: {
        CREATE_SUBTHREAD: 42,
      },
      InlineSdkClient: class {
        constructor(_opts: unknown) {}
        connect = connect
        close = close
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
          },
        },
      } as OpenClawConfig,
      params: {
        replyToId: "10",
        threadName: "Anchored follow-up",
      },
      toolContext: {
        currentChannelId: "7",
      },
    } as any)

    expect(invokeRaw).toHaveBeenCalledWith(
      42,
      expect.objectContaining({
        oneofKind: "createSubthread",
        createSubthread: expect.objectContaining({
          parentChatId: 7n,
          parentMessageId: 10n,
          title: "Anchored follow-up",
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
