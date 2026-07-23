import { describe, expect, it } from "vitest"
import { Update, UserGroup } from "@inline-chat/protocol/core"
import { chatId, dialogId, messageId, userId } from "@inline/ids"
import {
  Db,
  DbObjectKind,
  DbQueryPlanType,
  messageKey,
  UpdateApplicationError,
} from "../../index"
import { applyUpdates, applyUpdateSidecars } from "../updates"

const chatPeer = (chatId: bigint) => ({
  type: {
    oneofKind: "chat" as const,
    chat: { chatId },
  },
})

const threadChatId = chatId(801)
const threadDialogId = dialogId(-801)

describe("realtime update application", () => {
  it("uses the native thread dialog identity for inbox updates", () => {
    const db = new Db({ autoHydrate: false })
    db.insert({
      kind: DbObjectKind.Dialog,
      id: threadDialogId,
      chatId: threadChatId,
      peerThreadId: threadChatId,
      unreadMark: false,
    })

    applyUpdates(db, [
      {
        update: {
          oneofKind: "markAsUnread",
          markAsUnread: {
            peerId: chatPeer(801n),
            unreadMark: true,
          },
        },
      } as Update,
    ])

    expect(
      db.get(db.ref(DbObjectKind.Dialog, threadDialogId))?.unreadMark,
    ).toBe(true)
  })

  it("updates chat recency when a new message arrives", () => {
    const db = new Db({ autoHydrate: false })
    db.insert({
      kind: DbObjectKind.Chat,
      id: threadChatId,
      title: "Thread",
      lastMsgId: messageId(40),
      date: 100,
    })

    applyUpdates(db, [
      {
        update: {
          oneofKind: "newMessage",
          newMessage: {
            message: {
              id: 41n,
              chatId: 801n,
              fromId: 7n,
              message: "Latest",
              date: 101n,
            },
          },
        },
      } as Update,
    ])

    expect(db.get(db.ref(DbObjectKind.Chat, threadChatId))).toMatchObject({
      lastMsgId: messageId(41),
      date: 101,
    })
  })

  it("increments unread once for a new realtime message, but not for replay", () => {
    const db = new Db({ autoHydrate: false })
    db.insert({
      kind: DbObjectKind.Dialog,
      id: threadDialogId,
      chatId: threadChatId,
      peerThreadId: threadChatId,
      readMaxId: messageId(40),
      unreadCount: 2,
    })
    const update = {
      update: {
        oneofKind: "newMessage",
        newMessage: {
          message: {
            id: 41n,
            chatId: 801n,
            fromId: 7n,
            out: false,
            message: "Latest",
            date: 101n,
          },
        },
      },
    } as Update

    applyUpdates(db, [update], "realtime")
    applyUpdates(db, [update], "realtime")

    expect(
      db.get(db.ref(DbObjectKind.Dialog, threadDialogId))?.unreadCount,
    ).toBe(3)
  })

  it("does not double-count server unread totals during catch-up", () => {
    const db = new Db({ autoHydrate: false })
    db.insert({
      kind: DbObjectKind.Dialog,
      id: threadDialogId,
      chatId: threadChatId,
      peerThreadId: threadChatId,
      readMaxId: messageId(40),
      unreadCount: 8,
    })

    applyUpdates(
      db,
      [
        {
          update: {
            oneofKind: "newMessage",
            newMessage: {
              message: {
                id: 41n,
                chatId: 801n,
                fromId: 7n,
                out: false,
                message: "Missed",
                date: 101n,
              },
            },
          },
        } as Update,
      ],
      "syncCatchup",
    )

    expect(
      db.get(db.ref(DbObjectKind.Dialog, threadDialogId))?.unreadCount,
    ).toBe(8)
  })

  it("does not leave a deleted last message as the sidebar preview", () => {
    const db = new Db({ autoHydrate: false })
    db.insert({
      kind: DbObjectKind.Chat,
      id: threadChatId,
      title: "Thread",
      lastMsgId: messageId(42),
      date: 102,
    })
    db.insert({
      kind: DbObjectKind.Message,
      id: messageKey(threadChatId, messageId(41)),
      messageId: messageId(41),
      chatId: threadChatId,
      fromId: userId(7),
      message: "Previous",
      date: 101,
    })
    db.insert({
      kind: DbObjectKind.Message,
      id: messageKey(threadChatId, messageId(42)),
      messageId: messageId(42),
      chatId: threadChatId,
      fromId: userId(7),
      message: "Deleted",
      date: 102,
    })

    applyUpdates(db, [
      {
        update: {
          oneofKind: "deleteMessages",
          deleteMessages: {
            peerId: chatPeer(801n),
            messageIds: [42n],
          },
        },
      } as Update,
    ])

    expect(db.get(db.ref(DbObjectKind.Chat, threadChatId))).toMatchObject({
      lastMsgId: messageId(41),
      date: 101,
    })
  })

  it("removes the mapped thread dialog when the chat is deleted", () => {
    const db = new Db({ autoHydrate: false })
    db.insert({
      kind: DbObjectKind.Chat,
      id: threadChatId,
      title: "Thread",
    })
    db.insert({
      kind: DbObjectKind.Dialog,
      id: threadDialogId,
      chatId: threadChatId,
      peerThreadId: threadChatId,
    })

    applyUpdates(db, [
      {
        update: {
          oneofKind: "deleteChat",
          deleteChat: {
            peerId: chatPeer(801n),
          },
        },
      } as Update,
    ])

    expect(db.get(db.ref(DbObjectKind.Chat, threadChatId))).toBeUndefined()
    expect(
      db.get(db.ref(DbObjectKind.Dialog, threadDialogId)),
    ).toBeUndefined()
  })

  it("retains unsupported durable updates as lossless protobuf payloads", () => {
    const db = new Db({ autoHydrate: false })
    const update = Update.create({
      seq: 17,
      date: 1_020n,
      update: {
        oneofKind: "updateReaction",
        updateReaction: {
          reaction: {
            emoji: "👍",
            userId: 7n,
            messageId: 41n,
            chatId: 801n,
            date: 1_020n,
          },
        },
      },
    })

    expect(applyUpdates(db, [update])).toEqual({
      applied: 0,
      ephemeral: 0,
      syncHint: 0,
      deferred: 1,
      failed: 0,
    })

    const deferred = db.queryCollection(
      DbQueryPlanType.Objects,
      DbObjectKind.DeferredUpdate,
    )
    expect(deferred).toHaveLength(1)
    expect(deferred[0]).toMatchObject({
      bucketId: "chat:chat:801",
      seq: 17,
      date: 1_020,
      payloadType: "Update",
      updateType: "updateReaction",
    })
    expect(
      Update.fromBinary(deferred[0]!.payload),
    ).toEqual(update)
  })

  it("applies reaction inserts and deletes to a resident message aggregate", () => {
    const db = new Db({ autoHydrate: false })
    const key = messageKey(threadChatId, messageId(41))
    db.insert({
      kind: DbObjectKind.Message,
      id: key,
      messageId: messageId(41),
      chatId: threadChatId,
      fromId: userId(8),
      message: "React to this",
    })
    const add = Update.create({
      update: {
        oneofKind: "updateReaction",
        updateReaction: {
          reaction: {
            emoji: "👍",
            userId: 7n,
            messageId: 41n,
            chatId: 801n,
            date: 1_020n,
          },
        },
      },
    })

    expect(applyUpdates(db, [add])).toMatchObject({ applied: 1, deferred: 0 })
    expect(db.get(db.ref(DbObjectKind.Message, key))?.reactions?.reactions).toEqual([
      add.update.oneofKind === "updateReaction"
        ? add.update.updateReaction.reaction
        : undefined,
    ])

    const replace = Update.create({
      update: {
        oneofKind: "updateReaction",
        updateReaction: {
          reaction: {
            emoji: "👍",
            userId: 7n,
            messageId: 41n,
            chatId: 801n,
            date: 1_021n,
          },
        },
      },
    })
    applyUpdates(db, [replace])
    expect(db.get(db.ref(DbObjectKind.Message, key))?.reactions?.reactions).toHaveLength(1)
    expect(db.get(db.ref(DbObjectKind.Message, key))?.reactions?.reactions[0]?.date).toBe(1_021n)

    expect(applyUpdates(db, [Update.create({
      update: {
        oneofKind: "deleteReaction",
        deleteReaction: {
          emoji: "👍",
          userId: 7n,
          messageId: 41n,
          chatId: 801n,
        },
      },
    })])).toMatchObject({ applied: 1, deferred: 0 })
    expect(db.get(db.ref(DbObjectKind.Message, key))?.reactions).toBeUndefined()
  })

  it("classifies transient presence and sync hints without persisting them", () => {
    const db = new Db({ autoHydrate: false })
    const report = applyUpdates(db, [
      Update.create({
        update: {
          oneofKind: "updateComposeAction",
          updateComposeAction: {
            userId: 7n,
            peerId: chatPeer(801n),
            action: 1,
          },
        },
      }),
      Update.create({
        update: {
          oneofKind: "chatHasNewUpdates",
          chatHasNewUpdates: {
            chatId: 801n,
            peerId: chatPeer(801n),
            updateSeq: 20,
          },
        },
      }),
    ])

    expect(report).toEqual({
      applied: 0,
      ephemeral: 1,
      syncHint: 1,
      deferred: 0,
      failed: 0,
    })
    expect(
      db.queryCollection(
        DbQueryPlanType.Objects,
        DbObjectKind.DeferredUpdate,
      ),
    ).toEqual([])
  })

  it("retains user-group sidecars until the group model is implemented", () => {
    const db = new Db({ autoHydrate: false })
    const group = UserGroup.create({
      id: 12n,
      spaceId: 4n,
      name: "Design",
      memberCount: 2,
      userIds: [7n, 8n],
      currentUserIsMember: true,
      date: 1_100n,
    })

    expect(
      applyUpdateSidecars(db, {
        users: [],
        chats: [],
        dialogs: [],
        spaces: [],
        userGroups: [group],
      }),
    ).toMatchObject({
      applied: 0,
      deferred: 1,
      failed: 0,
    })

    const [deferred] = db.queryCollection(
      DbQueryPlanType.Objects,
      DbObjectKind.DeferredUpdate,
    )
    expect(deferred).toMatchObject({
      bucketId: "space:4",
      payloadType: "UserGroup",
      updateType: "sidecarUserGroup",
    })
    expect(
      UserGroup.fromBinary(deferred!.payload),
    ).toEqual(group)
  })

  it("rolls back the whole page when an update cannot be classified", () => {
    const db = new Db({ autoHydrate: false })
    db.insert({
      kind: DbObjectKind.Chat,
      id: threadChatId,
      title: "Before",
    })

    expect(() =>
      applyUpdates(db, [
        Update.create({
          update: {
            oneofKind: "chatInfo",
            chatInfo: {
              chatId: 801n,
              title: "Must roll back",
            },
          },
        }),
        Update.create(),
      ]),
    ).toThrow(UpdateApplicationError)

    expect(
      db.get(db.ref(DbObjectKind.Chat, threadChatId))?.title,
    ).toBe("Before")
  })
})
