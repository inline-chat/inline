import { describe, expect, test } from "bun:test"
import { and, eq } from "drizzle-orm"
import { db } from "@in/server/db"
import * as schema from "@in/server/db/schema"
import { createChat } from "@in/server/functions/messages.createChat"
import { createSubthread } from "@in/server/functions/messages.createSubthread"
import { getChat } from "@in/server/functions/messages.getChat"
import { getMessages } from "@in/server/functions/messages.getMessages"
import { setupTestLifecycle, testUtils } from "../setup"
import { DialogFollowMode } from "@inline-chat/protocol/core"

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

    expect(result.chat.title).toBe("Re: anchor")
    expect(result.chat.untitled).toBe(true)
    expect(result.chat.number).toBeUndefined()
    expect(childChat?.title).toBe("Re: anchor")
    expect(childChat?.isUntitled).toBe(true)
    expect(childChat?.threadNumber).toBeNull()

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

    expect(parentMessages.messages[0]?.replies?.chatId).toBe(BigInt(childChatId))
    expect(parentMessages.messages[0]?.replies?.replyCount).toBe(0)
    expect(parentMessages.messages[0]?.replies?.recentReplierUserIds).toEqual([])
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

    expect(result.chat.title).toBe("Re: Message")
    expect(result.chat.untitled).toBe(true)
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
