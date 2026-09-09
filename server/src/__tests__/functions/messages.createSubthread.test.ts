import { describe, expect, test } from "bun:test"
import { and, eq } from "drizzle-orm"
import { db } from "@in/server/db"
import * as schema from "@in/server/db/schema"
import { createChat } from "@in/server/functions/messages.createChat"
import { createSubthread } from "@in/server/functions/messages.createSubthread"
import { getChat } from "@in/server/functions/messages.getChat"
import { getChats } from "@in/server/functions/messages.getChats"
import { getMessages } from "@in/server/functions/messages.getMessages"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { deleteMessage } from "@in/server/functions/messages.deleteMessage"
import { deleteChat } from "@in/server/functions/messages.deleteChat"
import { editMessage } from "@in/server/functions/messages.editMessage"
import { updateChatInfo } from "@in/server/functions/messages.updateChatInfo"
import { UpdatesModel } from "@in/server/db/models/updates"
import { insertSystemMessage } from "@in/server/modules/systemMessages/insert"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { encryptMessage } from "@in/server/modules/encryption/encryptMessage"
import { setupTestLifecycle, testUtils } from "../setup"
import { DialogFollowMode, MessageSubthread_Kind, MessageEntity_Type } from "@inline-chat/protocol/core"

describe("messages.createSubthread", () => {
  setupTestLifecycle()

  test("creates a reply-thread subthread with anchor metadata and a hidden dialog for the opener", async () => {
    const creator = await testUtils.createUser("subthread-creator@example.com")
    const anchorAuthor = await testUtils.createUser("subthread-anchor-author@example.com")

    const parentChat = await testUtils.createChat(null, "Parent Thread", "thread", false, creator.id)
    if (!parentChat) {
      throw new Error("Parent chat not created")
    }

    await testUtils.addParticipant(parentChat.id, creator.id)
    await testUtils.addParticipant(parentChat.id, anchorAuthor.id)

    await db.insert(schema.messages).values({
      chatId: parentChat.id,
      messageId: 1,
      fromId: anchorAuthor.id,
      text: "anchor",
    })
    await db.update(schema.chats).set({ lastMsgId: 1 }).where(eq(schema.chats.id, parentChat.id))

    const result = await createSubthread(
      {
        parentChatId: BigInt(parentChat.id),
        parentMessageId: 1n,
        participants: [{ userId: BigInt(anchorAuthor.id) }],
      },
      testUtils.functionContext({ userId: creator.id }),
    )

    expect(result.chat.parentChatId).toBe(BigInt(parentChat.id))
    expect(result.chat.parentMessageId).toBe(1n)
    expect(result.anchorMessage?.id).toBe(1n)
    expect(result.dialog).toBeDefined()
    expect(result.dialog?.followMode).toBe(DialogFollowMode.FOLLOWING)

    const childChatId = Number(result.chat.id)
    const childChat = await db
      .select({ title: schema.chats.title, isUntitled: schema.chats.isUntitled, threadNumber: schema.chats.threadNumber })
      .from(schema.chats)
      .where(eq(schema.chats.id, childChatId))
      .limit(1)
      .then((rows) => rows[0])

    expect(result.chat.title).toBe("anchor")
    expect(result.chat.untitled).toBe(true)
    expect(result.chat.number).toBe(1)
    expect(childChat?.title).toBe("anchor")
    expect(childChat?.isUntitled).toBe(true)
    expect(childChat?.threadNumber).toBe(1)

    const graphLink = await waitForReplyThreadGraphLink(childChatId)
    expect(graphLink).toMatchObject({
      kind: "reply_thread",
      scopeType: "user",
      scopeId: creator.id,
      fromChatId: parentChat.id,
      fromMessageId: 1,
      toChatId: childChatId,
      backlinkMessageGlobalId: null,
      deletedAt: null,
    })

    const childDialogs = await db
      .select({
        userId: schema.dialogs.userId,
        chatListHidden: schema.dialogs.chatListHidden,
        followMode: schema.dialogs.followMode,
        open: schema.dialogs.open,
      })
      .from(schema.dialogs)
      .where(eq(schema.dialogs.chatId, childChatId))

    expect(childDialogs.sort((left, right) => left.userId - right.userId)).toEqual([
      {
        userId: Math.min(creator.id, anchorAuthor.id),
        chatListHidden: true,
        followMode: "following",
        open: null,
      },
      {
        userId: Math.max(creator.id, anchorAuthor.id),
        chatListHidden: true,
        followMode: "following",
        open: null,
      },
    ])

    const childChatUpdates = await db
      .select({ id: schema.updates.id })
      .from(schema.updates)
      .where(and(eq(schema.updates.bucket, schema.UpdateBucket.Chat), eq(schema.updates.entityId, childChatId)))

    expect(childChatUpdates).toHaveLength(0)

    const replyDiscoveryUpdates = await db
      .select()
      .from(schema.updates)
      .where(and(eq(schema.updates.bucket, schema.UpdateBucket.User), eq(schema.updates.entityId, anchorAuthor.id)))
    expect(
      replyDiscoveryUpdates
        .map((row) => UpdatesModel.decrypt(row).payload.update.oneofKind)
        .filter((kind) => kind === "userAddedToChat"),
    ).toEqual([])

    const parentMessages = await getMessages(
      {
        peerId: {
          type: {
            oneofKind: "chat",
            chat: { chatId: BigInt(parentChat.id) },
          },
        },
        messageIds: [1n],
      },
      testUtils.functionContext({ userId: creator.id }),
    )

    const legacyReplies = parentMessages.messages[0]?.replies
    const canonicalSubthread = parentMessages.messages[0]?.subthread
    expect(legacyReplies?.chatId).toBe(BigInt(childChatId))
    expect(legacyReplies?.replyCount).toBe(0)
    expect(legacyReplies?.recentReplierUserIds).toEqual([])
    expect(canonicalSubthread).toMatchObject({
      chatId: BigInt(childChatId),
      kind: MessageSubthread_Kind.REPLY,
      messageCount: 0,
      hasUnread: false,
      recentAuthorUserIds: [],
    })
    expect(canonicalSubthread?.title).toBeUndefined()
    expect(canonicalSubthread?.chatId).toBe(legacyReplies?.chatId)
    expect(canonicalSubthread?.messageCount).toBe(legacyReplies?.replyCount)
    expect(canonicalSubthread?.hasUnread).toBe(legacyReplies?.hasUnread)
    expect(canonicalSubthread?.recentAuthorUserIds).toEqual(legacyReplies?.recentReplierUserIds)

    const edited = await editMessage(
      {
        peer: {
          type: {
            oneofKind: "chat",
            chat: { chatId: BigInt(parentChat.id) },
          },
        },
        messageId: 1n,
        text: "edited anchor",
      },
      testUtils.functionContext({ userId: anchorAuthor.id }),
    )
    const editedAnchor = edited.updates.find(
      (update) => update.update.oneofKind === "editMessage",
    )?.update
    if (editedAnchor?.oneofKind !== "editMessage") {
      throw new Error("Edited anchor update missing")
    }
    expect(editedAnchor.editMessage.message?.replies?.chatId).toBe(BigInt(childChatId))
    expect(editedAnchor.editMessage.message?.subthread?.kind).toBe(MessageSubthread_Kind.REPLY)
  })

  test("projects usable reply-thread titles and hides only pending placeholders", async () => {
    const creator = await testUtils.createUser("reply-thread-card-title@example.com")
    const parentChat = await testUtils.createChat(null, "Parent Thread", "thread", false, creator.id)
    if (!parentChat) {
      throw new Error("Parent chat not created")
    }

    await testUtils.addParticipant(parentChat.id, creator.id)
    const anchorText = "Should the launch checklist include rollback ownership?"
    const encryptedAnchor = encryptMessage(anchorText)
    if (!encryptedAnchor) {
      throw new Error("Anchor encryption failed")
    }
    await db.insert(schema.messages).values({
      chatId: parentChat.id,
      messageId: 1,
      fromId: creator.id,
      textEncrypted: encryptedAnchor.encrypted,
      textIv: encryptedAnchor.iv,
      textTag: encryptedAnchor.authTag,
    })

    const replyThread = await createSubthread(
      { parentChatId: BigInt(parentChat.id), parentMessageId: 1n },
      testUtils.functionContext({ userId: creator.id }),
    )
    const replyThreadId = Number(replyThread.chat.id)
    const projectedTitle = async (): Promise<string | undefined> => {
      const result = await getMessages(
        {
          peerId: {
            type: {
              oneofKind: "chat",
              chat: { chatId: BigInt(parentChat.id) },
            },
          },
          messageIds: [1n],
        },
        testUtils.functionContext({ userId: creator.id }),
      )
      return result.messages[0]?.subthread?.title
    }

    expect(await projectedTitle()).toBeUndefined()

    await db
      .update(schema.chats)
      .set({
        autoTitleGenerated: true,
      })
      .where(eq(schema.chats.id, replyThreadId))
    expect(await projectedTitle()).toBe(anchorText)

    await db
      .update(schema.chats)
      .set({
        title: "Human-owned launch plan",
        isUntitled: null,
        autoTitleGenerated: false,
      })
      .where(eq(schema.chats.id, replyThreadId))
    expect(await projectedTitle()).toBe("Human-owned launch plan")

    await db
      .update(schema.chats)
      .set({
        title: anchorText,
        isUntitled: true,
        autoTitleGenerated: null,
      })
      .where(eq(schema.chats.id, replyThreadId))
    expect(await projectedTitle()).toBeUndefined()

    await db
      .update(schema.chats)
      .set({
        title: "Legacy generated launch plan",
      })
      .where(eq(schema.chats.id, replyThreadId))
    expect(await projectedTitle()).toBe("Legacy generated launch plan")
  })

  test("retries one anchored creation as the same reply thread", async () => {
    const creator = await testUtils.createUser("subthread-idempotent-creator@example.com")
    const parentChat = await testUtils.createChat(null, "Parent Thread", "thread", false, creator.id)
    if (!parentChat) {
      throw new Error("Parent chat not created")
    }

    await testUtils.addParticipant(parentChat.id, creator.id)
    await db.insert(schema.messages).values({
      chatId: parentChat.id,
      messageId: 1,
      fromId: creator.id,
      text: "session picker anchor",
    })

    const first = await createSubthread(
      {
        parentChatId: BigInt(parentChat.id),
        parentMessageId: 1n,
        title: "First session title",
      },
      testUtils.functionContext({ userId: creator.id }),
    )
    const retried = await createSubthread(
      {
        parentChatId: BigInt(parentChat.id),
        parentMessageId: 1n,
        title: "A retry must not create or rename",
      },
      testUtils.functionContext({ userId: creator.id }),
    )

    expect(retried.chat.id).toBe(first.chat.id)
    expect(retried.chat.title).toBe("First session title")
    const children = await db
      .select({ id: schema.chats.id })
      .from(schema.chats)
      .where(
        and(
          eq(schema.chats.parentChatId, parentChat.id),
          eq(schema.chats.parentMessageId, 1),
        ),
      )
    expect(children).toHaveLength(1)
  })

  test("does not re-follow unfollowed anchor author when reusing existing reply thread", async () => {
    const creator = await testUtils.createUser("subthread-reuse-creator@example.com")
    const anchorAuthor = await testUtils.createUser("subthread-reuse-anchor-author@example.com")

    const parentChat = await testUtils.createChat(null, "Parent Thread", "thread", false, creator.id)
    if (!parentChat) {
      throw new Error("Parent chat not created")
    }

    await testUtils.addParticipant(parentChat.id, creator.id)
    await testUtils.addParticipant(parentChat.id, anchorAuthor.id)

    await db.insert(schema.messages).values({
      chatId: parentChat.id,
      messageId: 1,
      fromId: anchorAuthor.id,
      text: "anchor",
    })

    const [childChat] = await db
      .insert(schema.chats)
      .values({
        type: "thread",
        title: "Re: anchor",
        publicThread: false,
        createdBy: creator.id,
        parentChatId: parentChat.id,
        parentMessageId: 1,
      })
      .returning()

    if (!childChat) {
      throw new Error("Child chat not created")
    }

    await db.insert(schema.dialogs).values({
      chatId: childChat.id,
      userId: anchorAuthor.id,
      followMode: "unfollowed",
      chatListHidden: true,
    })

    const result = await createSubthread(
      {
        parentChatId: BigInt(parentChat.id),
        parentMessageId: 1n,
      },
      testUtils.functionContext({ userId: creator.id }),
    )

    expect(result.chat.id).toBe(BigInt(childChat.id))

    const childDialogs = await db
      .select({
        userId: schema.dialogs.userId,
        followMode: schema.dialogs.followMode,
      })
      .from(schema.dialogs)
      .where(eq(schema.dialogs.chatId, childChat.id))

    expect(new Map(childDialogs.map((dialog) => [dialog.userId, dialog.followMode]))).toEqual(
      new Map([
        [creator.id, "following"],
        [anchorAuthor.id, "unfollowed"],
      ]),
    )
  })

  test("assigns the next space thread number to linked subthreads", async () => {
    const space = await testUtils.createSpace("Numbered Subthreads")
    if (!space) {
      throw new Error("Space not created")
    }

    const creator = await testUtils.createUser("numbered-subthread-owner@example.com")
    await db.insert(schema.members).values({ spaceId: space.id, userId: creator.id, role: "member" })

    const parent = await createChat(
      {
        title: "Parent",
        spaceId: BigInt(space.id),
        isPublic: true,
      },
      testUtils.functionContext({ userId: creator.id }),
    )

    const parentChatId = Number(parent.chat.id)
    await db.insert(schema.messages).values({
      chatId: parentChatId,
      messageId: 1,
      fromId: creator.id,
      text: "anchor",
    })

    const replyThread = await createSubthread(
      {
        parentChatId: BigInt(parentChatId),
        parentMessageId: 1n,
      },
      testUtils.functionContext({ userId: creator.id }),
    )

    const subthread = await createSubthread(
      {
        parentChatId: BigInt(parentChatId),
        title: "Nested plan",
      },
      testUtils.functionContext({ userId: creator.id }),
    )

    expect(parent.chat.number).toBe(1)
    expect(replyThread.chat.spaceId).toBe(BigInt(space.id))
    expect(replyThread.chat.number).toBe(2)
    expect(subthread.chat.spaceId).toBe(BigInt(space.id))
    expect(subthread.chat.number).toBe(3)

    const rows = await db
      .select({ id: schema.chats.id, threadNumber: schema.chats.threadNumber })
      .from(schema.chats)
      .where(eq(schema.chats.spaceId, space.id))

    expect(new Map(rows.map((row) => [row.id, row.threadNumber]))).toEqual(
      new Map([
        [parentChatId, 1],
        [Number(replyThread.chat.id), 2],
        [Number(subthread.chat.id), 3],
      ]),
    )
  })

  test("creates explicit subthread title as titled", async () => {
    const creator = await testUtils.createUser("subthread-title-owner@example.com")
    const parentChat = await testUtils.createChat(null, "Parent Thread", "thread", false, creator.id)
    if (!parentChat) {
      throw new Error("Parent chat not created")
    }

    await testUtils.addParticipant(parentChat.id, creator.id)

    const result = await createSubthread(
      {
        parentChatId: BigInt(parentChat.id),
        title: "Design notes",
      },
      testUtils.functionContext({ userId: creator.id }),
    )

    expect(result.chat.title).toBe("Design notes")
    expect(result.chat.untitled).toBeUndefined()

    const childChat = await db
      .select({ title: schema.chats.title, isUntitled: schema.chats.isUntitled })
      .from(schema.chats)
      .where(eq(schema.chats.id, Number(result.chat.id)))
      .limit(1)
      .then((rows) => rows[0])

    expect(childChat?.title).toBe("Design notes")
    expect(childChat?.isUntitled).toBeNull()
  })

  test("creates generic reply-thread title when anchor text is empty", async () => {
    const creator = await testUtils.createUser("subthread-empty-anchor@example.com")
    const parentChat = await testUtils.createChat(null, "Parent Thread", "thread", false, creator.id)
    if (!parentChat) {
      throw new Error("Parent chat not created")
    }

    await testUtils.addParticipant(parentChat.id, creator.id)
    await db.insert(schema.messages).values({
      chatId: parentChat.id,
      messageId: 1,
      fromId: creator.id,
      text: "",
    })

    const result = await createSubthread(
      {
        parentChatId: BigInt(parentChat.id),
        parentMessageId: 1n,
      },
      testUtils.functionContext({ userId: creator.id }),
    )

    expect(result.chat.title).toBe("Message")
    expect(result.chat.untitled).toBe(true)
  })

  test("creates a prefix-free 60-character reply-thread excerpt", async () => {
    const creator = await testUtils.createUser("subthread-compact-title@example.com")
    const parentChat = await testUtils.createChat(null, "Parent Thread", "thread", false, creator.id)
    if (!parentChat) throw new Error("Parent chat not created")

    const anchor = "This parent message is long enough to verify the compact reply-thread sidebar excerpt limit exactly."
    await testUtils.addParticipant(parentChat.id, creator.id)
    await db.insert(schema.messages).values({
      chatId: parentChat.id,
      messageId: 1,
      fromId: creator.id,
      text: anchor,
    })

    const result = await createSubthread(
      { parentChatId: BigInt(parentChat.id), parentMessageId: 1n },
      testUtils.functionContext({ userId: creator.id }),
    )

    expect(result.chat.title).toBe(Array.from(anchor).slice(0, 60).join(""))
    expect(result.chat.title?.startsWith("Re:")).toBe(false)
  })

  test("creates untitled non-reply subthread without generated display title", async () => {
    const creator = await testUtils.createUser("subthread-untitled-owner@example.com")
    const parentChat = await testUtils.createChat(null, "Parent Thread", "thread", false, creator.id)
    if (!parentChat) {
      throw new Error("Parent chat not created")
    }

    await testUtils.addParticipant(parentChat.id, creator.id)

    const result = await createSubthread(
      {
        parentChatId: BigInt(parentChat.id),
      },
      testUtils.functionContext({ userId: creator.id }),
    )

    expect(result.chat.title).toBe("")
    expect(result.chat.untitled).toBe(true)

    const childChat = await db
      .select({ title: schema.chats.title, isUntitled: schema.chats.isUntitled })
      .from(schema.chats)
      .where(eq(schema.chats.id, Number(result.chat.id)))
      .limit(1)
      .then((rows) => rows[0])

    expect(childChat?.title).toBeNull()
    expect(childChat?.isUntitled).toBe(true)
  })

  test("materializes one titled subthread card after the first message and preserves deletion", async () => {
    const creator = await testUtils.createUser("subthread-parent-card-owner@example.com")
    const parentChat = await testUtils.createChat(null, "Parent Thread", "thread", false, creator.id)
    if (!parentChat) throw new Error("Parent chat not created")
    await testUtils.addParticipant(parentChat.id, creator.id)

    const created = await createSubthread(
      { parentChatId: BigInt(parentChat.id) },
      testUtils.functionContext({ userId: creator.id }),
    )
    const childChatId = Number(created.chat.id)
    const childPeer = {
      type: {
        oneofKind: "chat" as const,
        chat: { chatId: BigInt(childChatId) },
      },
    }

    await sendMessage(
      {
        peerId: childPeer,
        message: "Review the launch checklist tomorrow",
      },
      testUtils.functionContext({ userId: creator.id }),
    )

    const placement = await waitForSubthreadParentMessage(childChatId)
    expect(placement).toBeDefined()

    await expect(createSubthread(
      {
        parentChatId: BigInt(parentChat.id),
        parentMessageId: BigInt(placement!.parentMessageId),
      },
      testUtils.functionContext({ userId: creator.id }),
    )).rejects.toMatchObject({ code: RealtimeRpcError.Code.BAD_REQUEST })

    const parentMessages = await getMessages(
      {
        peerId: {
          type: {
            oneofKind: "chat",
            chat: { chatId: BigInt(parentChat.id) },
          },
        },
        messageIds: [BigInt(placement!.parentMessageId)],
      },
      testUtils.functionContext({ userId: creator.id }),
    )
    const parentMessage = parentMessages.messages[0]
    expect(parentMessage?.message).toBe("Started a subthread: Review the launch checklist tomorrow")
    expect(parentMessage?.replies).toBeUndefined()
    expect(parentMessage?.subthread).toMatchObject({
      chatId: BigInt(childChatId),
      kind: MessageSubthread_Kind.SUBTHREAD,
      title: "Review the launch checklist tomorrow",
      messageCount: 1,
      recentAuthorUserIds: [BigInt(creator.id)],
    })
    expect(parentMessage?.entities?.entities[0]).toMatchObject({
      type: MessageEntity_Type.THREAD,
      entity: {
        oneofKind: "thread",
        thread: { chatId: BigInt(childChatId) },
      },
    })

    const parentSnapshot = await getChat(
      {
        peerId: {
          type: {
            oneofKind: "chat",
            chat: { chatId: BigInt(parentChat.id) },
          },
        },
        includeRecentMessages: true,
      },
      testUtils.functionContext({ userId: creator.id }),
    )
    expect(parentSnapshot.messages.find(
      (message) => message.id === BigInt(placement!.parentMessageId),
    )?.subthread?.kind).toBe(MessageSubthread_Kind.SUBTHREAD)

    const chatsSnapshot = await getChats(
      {},
      testUtils.functionContext({ userId: creator.id }),
    )
    expect(chatsSnapshot.messages.find(
      (message) => message.chatId === BigInt(parentChat.id),
    )?.subthread?.kind).toBe(MessageSubthread_Kind.SUBTHREAD)

    await sendMessage(
      { peerId: childPeer, message: "A second message" },
      testUtils.functionContext({ userId: creator.id }),
    )
    await updateChatInfo(
      { chatId: childChatId, title: "Launch checklist" },
      testUtils.functionContext({ userId: creator.id }),
    )
    const refreshedParentMessage = await getMessages(
      {
        peerId: {
          type: {
            oneofKind: "chat",
            chat: { chatId: BigInt(parentChat.id) },
          },
        },
        messageIds: [BigInt(placement!.parentMessageId)],
      },
      testUtils.functionContext({ userId: creator.id }),
    )
    expect(refreshedParentMessage.messages[0]?.subthread?.title).toBe("Launch checklist")
    expect(refreshedParentMessage.messages[0]?.subthread?.messageCount).toBe(2)

    await deleteMessage(
      {
        peer: childPeer,
        messageIds: [1n, 2n],
      },
      testUtils.functionContext({ userId: creator.id }),
    )
    const emptyParentMessage = await getMessages(
      {
        peerId: {
          type: {
            oneofKind: "chat",
            chat: { chatId: BigInt(parentChat.id) },
          },
        },
        messageIds: [BigInt(placement!.parentMessageId)],
      },
      testUtils.functionContext({ userId: creator.id }),
    )
    expect(emptyParentMessage.messages[0]?.subthread?.messageCount).toBe(0)

    await deleteMessage(
      {
        peer: {
          type: {
            oneofKind: "chat",
            chat: { chatId: BigInt(parentChat.id) },
          },
        },
        messageIds: [BigInt(placement!.parentMessageId)],
      },
      testUtils.functionContext({ userId: creator.id }),
    )

    const [tombstone] = await db
      .select()
      .from(schema.subthreadParentMessages)
      .where(eq(schema.subthreadParentMessages.childChatId, childChatId))
    expect(tombstone?.parentMessageGlobalId).toBeNull()

    await sendMessage(
      { peerId: childPeer, message: "A later message" },
      testUtils.functionContext({ userId: creator.id }),
    )
    await sleep(10)

    const placementRows = await db
      .select()
      .from(schema.subthreadParentMessages)
      .where(eq(schema.subthreadParentMessages.childChatId, childChatId))
    expect(placementRows).toHaveLength(1)
    expect(placementRows[0]?.parentMessageGlobalId).toBeNull()
  })

  test("deleting a subthread removes its live parent placement", async () => {
    const creator = await testUtils.createUser("subthread-parent-card-delete-owner@example.com")
    const parentChat = await testUtils.createChat(null, "Parent Thread", "thread", false, creator.id)
    if (!parentChat) throw new Error("Parent chat not created")
    await testUtils.addParticipant(parentChat.id, creator.id)

    const created = await createSubthread(
      { parentChatId: BigInt(parentChat.id), title: "Temporary work" },
      testUtils.functionContext({ userId: creator.id }),
    )
    const childChatId = Number(created.chat.id)
    await sendMessage(
      {
        peerId: {
          type: {
            oneofKind: "chat",
            chat: { chatId: BigInt(childChatId) },
          },
        },
        message: "First message",
      },
      testUtils.functionContext({ userId: creator.id }),
    )
    const placement = await waitForSubthreadParentMessage(childChatId)
    expect(placement).toBeDefined()

    await deleteChat(
      {
        peer: {
          type: {
            oneofKind: "chat",
            chat: { chatId: BigInt(childChatId) },
          },
        },
      },
      testUtils.functionContext({ userId: creator.id }),
    )

    const [parentMessage] = await db
      .select({ globalId: schema.messages.globalId })
      .from(schema.messages)
      .where(and(
        eq(schema.messages.chatId, parentChat.id),
        eq(schema.messages.messageId, placement!.parentMessageId),
      ))
    expect(parentMessage).toBeUndefined()
  })

  test("space admin cleanup does not require access to the parent placement", async () => {
    const creator = await testUtils.createUser("subthread-parent-card-private-owner@example.com")
    const admin = await testUtils.createUser("subthread-parent-card-private-admin@example.com")
    const space = await testUtils.createSpace("Private Subthread Parent Card")
    if (!space) throw new Error("Space not created")
    await db.insert(schema.members).values([
      { spaceId: space.id, userId: creator.id, role: "member" },
      { spaceId: space.id, userId: admin.id, role: "admin" },
    ])

    const parentChat = await testUtils.createChat(
      space.id,
      "Private Parent Thread",
      "thread",
      false,
      creator.id,
    )
    if (!parentChat) throw new Error("Parent chat not created")
    await testUtils.addParticipant(parentChat.id, creator.id)

    const created = await createSubthread(
      { parentChatId: BigInt(parentChat.id), title: "Private child" },
      testUtils.functionContext({ userId: creator.id }),
    )
    const childChatId = Number(created.chat.id)
    await sendMessage(
      {
        peerId: {
          type: {
            oneofKind: "chat",
            chat: { chatId: BigInt(childChatId) },
          },
        },
        message: "First message",
      },
      testUtils.functionContext({ userId: creator.id }),
    )
    const placement = await waitForSubthreadParentMessage(childChatId)
    expect(placement).toBeDefined()

    await deleteChat(
      {
        peer: {
          type: {
            oneofKind: "chat",
            chat: { chatId: BigInt(childChatId) },
          },
        },
      },
      testUtils.functionContext({ userId: admin.id }),
    )

    const [parentMessage] = await db
      .select({ globalId: schema.messages.globalId })
      .from(schema.messages)
      .where(and(
        eq(schema.messages.chatId, parentChat.id),
        eq(schema.messages.messageId, placement!.parentMessageId),
      ))
    expect(parentMessage).toBeUndefined()
  })

  test("the first live nudge qualifies for parent placement", async () => {
    const creator = await testUtils.createUser("subthread-parent-card-nudge-owner@example.com")
    const parentChat = await testUtils.createChat(null, "Parent Thread", "thread", false, creator.id)
    if (!parentChat) throw new Error("Parent chat not created")
    await testUtils.addParticipant(parentChat.id, creator.id)

    const created = await createSubthread(
      { parentChatId: BigInt(parentChat.id) },
      testUtils.functionContext({ userId: creator.id }),
    )
    const childChatId = Number(created.chat.id)
    await sendMessage(
      {
        peerId: {
          type: {
            oneofKind: "chat",
            chat: { chatId: BigInt(childChatId) },
          },
        },
        message: "👋",
        nudge: true,
      },
      testUtils.functionContext({ userId: creator.id }),
    )

    const placement = await waitForSubthreadParentMessage(childChatId)
    expect(placement).toBeDefined()
    const parentMessages = await getMessages(
      {
        peerId: {
          type: {
            oneofKind: "chat",
            chat: { chatId: BigInt(parentChat.id) },
          },
        },
        messageIds: [BigInt(placement!.parentMessageId)],
      },
      testUtils.functionContext({ userId: creator.id }),
    )
    expect(parentMessages.messages[0]?.subthread).toMatchObject({
      kind: MessageSubthread_Kind.SUBTHREAD,
      title: "👋",
      messageCount: 1,
    })
  })

  test("a prior service message does not consume first-message materialization", async () => {
    const creator = await testUtils.createUser("subthread-parent-card-service-owner@example.com")
    const parentChat = await testUtils.createChat(null, "Parent Thread", "thread", false, creator.id)
    if (!parentChat) throw new Error("Parent chat not created")
    await testUtils.addParticipant(parentChat.id, creator.id)

    const created = await createSubthread(
      { parentChatId: BigInt(parentChat.id) },
      testUtils.functionContext({ userId: creator.id }),
    )
    const childChatId = Number(created.chat.id)
    await insertSystemMessage({
      chatId: childChatId,
      actorUserId: creator.id,
      fallbackText: "Pinned a message",
      payload: {
        event: {
          oneofKind: "pinnedMessage",
          pinnedMessage: {
            pinnedMessageGlobalId: 1n,
            pinnedMessageId: 1n,
          },
        },
      },
      publish: false,
    })

    await sendMessage(
      {
        peerId: {
          type: {
            oneofKind: "chat",
            chat: { chatId: BigInt(childChatId) },
          },
        },
        message: "First authored message",
      },
      testUtils.functionContext({ userId: creator.id }),
    )

    const placement = await waitForSubthreadParentMessage(childChatId)
    expect(placement).toBeDefined()
    const parentMessages = await getMessages(
      {
        peerId: {
          type: {
            oneofKind: "chat",
            chat: { chatId: BigInt(parentChat.id) },
          },
        },
        messageIds: [BigInt(placement!.parentMessageId)],
      },
      testUtils.functionContext({ userId: creator.id }),
    )
    expect(parentMessages.messages[0]?.subthread).toMatchObject({
      kind: MessageSubthread_Kind.SUBTHREAD,
      title: "First authored message",
    })
  })

  test("does not enqueue durable access updates for discoverable subthreads", async () => {
    const creator = await testUtils.createUser("subthread-initial-owner@example.com")
    const bot = await testUtils.createUser("subthread-initial-bot@example.com")
    const parentChat = await testUtils.createChat(null, "Parent Thread", "thread", false, creator.id)
    if (!parentChat) {
      throw new Error("Parent chat not created")
    }

    await testUtils.addParticipant(parentChat.id, creator.id)

    const result = await createSubthread(
      {
        parentChatId: BigInt(parentChat.id),
        title: "Bot Work",
        participants: [{ userId: BigInt(bot.id) }],
      },
      testUtils.functionContext({ userId: creator.id }),
    )

    const botUpdates = await db
      .select()
      .from(schema.updates)
      .where(and(eq(schema.updates.bucket, schema.UpdateBucket.User), eq(schema.updates.entityId, bot.id)))

    expect(botUpdates).toHaveLength(0)
    expect(result.chat.parentChatId).toBe(BigInt(parentChat.id))
  })

  test("getChat creates a hidden dialog when opening a linked subthread", async () => {
    const creator = await testUtils.createUser("linked-subthread-owner@example.com")
    const participant = await testUtils.createUser("linked-subthread-participant@example.com")

    const parentChat = await testUtils.createChat(null, "Parent Thread", "thread", false, creator.id)
    if (!parentChat) {
      throw new Error("Parent chat not created")
    }

    await testUtils.addParticipant(parentChat.id, creator.id)
    await testUtils.addParticipant(parentChat.id, participant.id)

    await db.insert(schema.messages).values({
      chatId: parentChat.id,
      messageId: 1,
      fromId: creator.id,
      text: "anchor",
    })
    await db.update(schema.chats).set({ lastMsgId: 1 }).where(eq(schema.chats.id, parentChat.id))

    const [childChat] = await db
      .insert(schema.chats)
      .values({
        type: "thread",
        title: null,
        publicThread: false,
        createdBy: creator.id,
        parentChatId: parentChat.id,
        parentMessageId: 1,
      })
      .returning()

    if (!childChat) {
      throw new Error("Child chat not created")
    }

    const result = await getChat(
      {
        peerId: {
          type: {
            oneofKind: "chat",
            chat: { chatId: BigInt(childChat.id) },
          },
        },
      },
      testUtils.functionContext({ userId: participant.id }),
    )

    expect(result.dialog?.chatId).toBe(BigInt(childChat.id))
    expect(result.dialog?.chatListHidden).toBe(true)
    expect(result.anchorMessage?.id).toBe(1n)

    const existingDialog = await db
      .select()
      .from(schema.dialogs)
      .where(and(eq(schema.dialogs.chatId, childChat.id), eq(schema.dialogs.userId, participant.id)))
      .limit(1)
      .then((rows) => rows[0])

    expect(existingDialog?.chatListHidden).toBe(true)
  })
})

async function waitForSubthreadParentMessage(childChatId: number) {
  for (let attempt = 0; attempt < 40; attempt += 1) {
    const [placement] = await db
      .select({
        parentMessageGlobalId: schema.subthreadParentMessages.parentMessageGlobalId,
        parentMessageId: schema.messages.messageId,
      })
      .from(schema.subthreadParentMessages)
      .innerJoin(
        schema.messages,
        eq(schema.messages.globalId, schema.subthreadParentMessages.parentMessageGlobalId),
      )
      .where(eq(schema.subthreadParentMessages.childChatId, childChatId))
      .limit(1)
    if (placement) {
      return placement
    }
    await sleep(5)
  }
  return undefined
}

async function waitForReplyThreadGraphLink(toChatId: number) {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    const [link] = await db
      .select()
      .from(schema.threadGraphLinks)
      .where(and(eq(schema.threadGraphLinks.kind, "reply_thread"), eq(schema.threadGraphLinks.toChatId, toChatId)))
      .limit(1)

    if (link) {
      return link
    }

    await sleep(10)
  }

  throw new Error(`Reply-thread graph link not materialized for chat ${toChatId}`)
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}
