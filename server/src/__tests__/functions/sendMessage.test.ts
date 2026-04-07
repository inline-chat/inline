import { describe, test, expect, beforeAll, mock } from "bun:test"
import { InputPeer, Message, MessageEntity_Type, SendMessageResult } from "@inline-chat/protocol/core"
import { setupTestDatabase, testUtils } from "../setup"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import type { DbChat, DbUser } from "@in/server/db/schema"
import type { FunctionContext } from "@in/server/functions/_types"
import { db } from "@in/server/db"
import { chats, dialogs, files, messages, users, voices } from "@in/server/db/schema"
import { and, eq } from "drizzle-orm"
import { UpdateBucket } from "@in/server/db/schema/updates"
import { UpdatesModel } from "@in/server/db/models/updates"
import { desktopPushSuppressionTracker } from "@in/server/modules/notifications/desktopPushSuppression"
import { getMessages } from "@in/server/functions/messages.getMessages"
import { Notifications } from "@in/server/modules/notifications/notifications"
import { UserSettingsModel } from "@in/server/db/models/userSettings/userSettings"
import { UserSettingsNotificationsMode } from "@in/server/db/models/userSettings/types"

// Test state
let currentUser: DbUser
let privateChat: DbChat
let privateChatPeerId: InputPeer
let context: FunctionContext
let userIndex = 0

const runId = Date.now()
const nextEmail = (label: string) => `${label}-${runId}-${userIndex++}@example.com`

async function waitForTrue(check: () => boolean, timeoutMs = 1_000, intervalMs = 20): Promise<void> {
  const startedAt = Date.now()
  while (Date.now() - startedAt < timeoutMs) {
    if (check()) return
    await Bun.sleep(intervalMs)
  }
  throw new Error("Timed out waiting for async condition")
}

// Helpers
function extractMessage(result: SendMessageResult): Message | null {
  const update = result.updates[1]
  if (update?.update.oneofKind !== "newMessage") {
    return null
  }
  return update.update.newMessage?.message ?? null
}

async function createVoiceForUser(userId: number) {
  const [file] = await db
    .insert(files)
    .values({
      fileUniqueId: `INV-${runId}-${userIndex++}`,
      userId,
      fileType: "voice",
      mimeType: "audio/ogg",
      fileSize: 321,
    })
    .returning()

  if (!file) {
    throw new Error("Failed to create test voice file")
  }

  const [voice] = await db
    .insert(voices)
    .values({
      fileId: file.id,
      duration: 12,
      waveform: Buffer.from([1, 2, 3, 4]),
    })
    .returning()

  if (!voice) {
    throw new Error("Failed to create test voice")
  }

  return voice
}

describe("sendMessage", () => {
  beforeAll(async () => {
    await setupTestDatabase()
    currentUser = (await testUtils.createUser(nextEmail("test-user")))!
    privateChat = (await testUtils.createPrivateChat(currentUser, currentUser))!
    privateChatPeerId = {
      type: { oneofKind: "chat" as const, chat: { chatId: BigInt(privateChat.id) } },
    }
    context = testUtils.functionContext({ userId: currentUser.id, sessionId: 1 })
  })

  test("records desktop chat activity from successful sends", async () => {
    const mockRecordChatActivity = mock().mockResolvedValue(undefined)
    const originalRecordChatActivity = desktopPushSuppressionTracker.recordChatActivity
    desktopPushSuppressionTracker.recordChatActivity = mockRecordChatActivity

    try {
      await sendMessage(
        {
          peerId: privateChatPeerId,
          message: "activity ping",
        },
        context,
      )
    } finally {
      desktopPushSuppressionTracker.recordChatActivity = originalRecordChatActivity
    }

    expect(mockRecordChatActivity).toHaveBeenCalledTimes(1)
    expect(mockRecordChatActivity).toHaveBeenCalledWith({
      userId: currentUser.id,
      sessionId: context.currentSessionId,
      chatId: privateChat.id,
    })
  })

  test("treats reply-thread messages as mention-context for parent message author", async () => {
    const owner = await testUtils.createUser(nextEmail("reply-thread-owner"))
    const parentAuthor = await testUtils.createUser(nextEmail("reply-thread-parent-author"))

    const parentChat = await testUtils.createChat(null, "Parent Thread", "thread", false, owner.id)
    if (!parentChat) throw new Error("Parent chat not created")

    await testUtils.addParticipant(parentChat.id, owner.id)
    await testUtils.addParticipant(parentChat.id, parentAuthor.id)

    await UserSettingsModel.updateGeneral(parentAuthor.id, {
      notifications: {
        mode: UserSettingsNotificationsMode.Mentions,
        silent: false,
      },
    })

    await db.insert(messages).values({
      chatId: parentChat.id,
      messageId: 1,
      fromId: parentAuthor.id,
      text: "anchor",
    })

    const [childChat] = await db
      .insert(chats)
      .values({
        type: "thread",
        title: "Re: anchor",
        publicThread: false,
        createdBy: owner.id,
        parentChatId: parentChat.id,
        parentMessageId: 1,
      })
      .returning()

    if (!childChat) throw new Error("Child chat not created")

    const originalSendToUser = Notifications.sendToUser
    const mockSendToUser = mock(async () => {})
    Notifications.sendToUser = mockSendToUser

    try {
      await sendMessage(
        {
          peerId: {
            type: { oneofKind: "chat", chat: { chatId: BigInt(childChat.id) } },
          },
          message: "first message in reply thread",
        },
        testUtils.functionContext({ userId: owner.id, sessionId: 1 }),
      )

      await waitForTrue(() =>
        mockSendToUser.mock.calls.some((call: any[]) => {
          const [arg] = call
          return (
            arg?.userId === parentAuthor.id &&
            arg?.payload?.kind === "send_message" &&
            arg?.payload?.threadId === `chat_${childChat.id}`
          )
        }),
      )
    } finally {
      Notifications.sendToUser = originalSendToUser
    }
  })

  test("should create a text message", async () => {
    let result = await sendMessage(
      {
        peerId: privateChatPeerId,
        message: "test",
      },
      context,
    )

    expect(result.updates).toHaveLength(2)
    expect(result.updates[1]?.update.oneofKind).toBe("newMessage")

    const message = extractMessage(result)
    expect(message).toBeTruthy()
    expect(message?.message).toBe("test")
  })

  test("should return one update if message has duplicate random id", async () => {
    let _ = await sendMessage(
      {
        peerId: privateChatPeerId,
        message: "test",
        randomId: 1n,
      },
      context,
    )
    let result = await sendMessage(
      {
        peerId: privateChatPeerId,
        message: "test",
        randomId: 1n,
      },
      context,
    )

    expect(result.updates).toHaveLength(1)
    expect(result.updates[0]?.update.oneofKind).toBe("updateMessageId")
  })

  test("should create a text message with empty entities", async () => {
    let result = await sendMessage(
      {
        peerId: privateChatPeerId,
        message: "test",
        entities: { entities: [] },
      },
      context,
    )

    expect(result.updates).toHaveLength(2)
    const message = extractMessage(result)
    expect(message!.message).toBe("test")
  })

  test("should create a text message with entities", async () => {
    let result = await sendMessage(
      {
        peerId: privateChatPeerId,
        message: "@mo",
        entities: testUtils.mentionEntities(0, 3),
      },
      context,
    )

    expect(result.updates).toHaveLength(2)
    const message = extractMessage(result)
    expect(message!.message).toBe("@mo")
    expect(message!.entities).toBeTruthy()
    expect(message!.entities!.entities).toHaveLength(1)
    expect(message!.entities!.entities[0]!.type).toBe(MessageEntity_Type.MENTION)
    expect(message!.entities!.entities[0]!.offset).toBe(0n)
    expect(message!.entities!.entities[0]!.length).toBe(3n)
  })

  test("should create a voice message", async () => {
    const voice = await createVoiceForUser(currentUser.id)

    const result = await sendMessage(
      {
        peerId: privateChatPeerId,
        voiceId: BigInt(voice.id),
      },
      context,
    )

    expect(result.updates).toHaveLength(2)
    const message = extractMessage(result)
    expect(message).toBeTruthy()
    expect(message?.media?.media.oneofKind).toBe("voice")
    if (message?.media?.media.oneofKind !== "voice") {
      throw new Error("Expected voice media")
    }
    const encodedVoice = message.media.media.voice.voice
    expect(encodedVoice).toBeTruthy()
    expect(encodedVoice?.duration).toBe(12)
    expect(encodedVoice?.waveform).toEqual(new Uint8Array([1, 2, 3, 4]))
  })

  test("parses @username mention from text when client does not provide mention entity", async () => {
    const mentionedUser = await testUtils.createUser(nextEmail("mentioned-user"))
    await db.update(users).set({ username: "mentioneduser" }).where(eq(users.id, mentionedUser.id)).execute()

    const result = await sendMessage(
      {
        peerId: privateChatPeerId,
        message: "hello @mentioneduser",
      },
      context,
    )

    const message = extractMessage(result)
    expect(message).toBeTruthy()
    expect(message!.entities).toBeTruthy()
    expect(message!.entities!.entities).toHaveLength(1)

    const mentionEntity = message!.entities!.entities[0]!
    expect(mentionEntity.type).toBe(MessageEntity_Type.MENTION)
    expect(mentionEntity.offset).toBe(6n)
    expect(mentionEntity.length).toBe(14n)
    expect(mentionEntity.entity.oneofKind).toBe("mention")
    if (mentionEntity.entity.oneofKind !== "mention") {
      throw new Error("Expected mention entity")
    }
    expect(mentionEntity.entity.mention.userId).toBe(BigInt(mentionedUser.id))
  })

  test("does not duplicate mention node when client already provides mention entity", async () => {
    const mentionedUser = await testUtils.createUser(nextEmail("provided-mentioned-user"))
    await db.update(users).set({ username: "providedmention" }).where(eq(users.id, mentionedUser.id)).execute()

    const result = await sendMessage(
      {
        peerId: privateChatPeerId,
        message: "hello @providedmention",
        entities: {
          entities: [
            {
              type: MessageEntity_Type.MENTION,
              offset: 6n,
              length: 16n,
              entity: {
                oneofKind: "mention",
                mention: {
                  userId: BigInt(mentionedUser.id),
                },
              },
            },
          ],
        },
      },
      context,
    )

    const message = extractMessage(result)
    expect(message).toBeTruthy()
    expect(message!.entities).toBeTruthy()
    expect(message!.entities!.entities).toHaveLength(1)
    expect(message!.entities!.entities[0]!.offset).toBe(6n)
    expect(message!.entities!.entities[0]!.length).toBe(16n)
    expect(message!.entities!.entities[0]!.entity.oneofKind).toBe("mention")
    if (message!.entities!.entities[0]!.entity.oneofKind !== "mention") {
      throw new Error("Expected mention entity")
    }
    expect(message!.entities!.entities[0]!.entity.mention.userId).toBe(BigInt(mentionedUser.id))
  })

  test("parses only missing @username mentions and keeps provided mention entities", async () => {
    const providedUser = await testUtils.createUser(nextEmail("provided-user"))
    const missingUser = await testUtils.createUser(nextEmail("missing-user"))
    await db.update(users).set({ username: "providednode" }).where(eq(users.id, providedUser.id)).execute()
    await db.update(users).set({ username: "missingnode" }).where(eq(users.id, missingUser.id)).execute()

    const result = await sendMessage(
      {
        peerId: privateChatPeerId,
        message: "@providednode and @missingnode",
        entities: {
          entities: [
            {
              type: MessageEntity_Type.MENTION,
              offset: 0n,
              length: 13n,
              entity: {
                oneofKind: "mention",
                mention: {
                  userId: BigInt(providedUser.id),
                },
              },
            },
          ],
        },
      },
      context,
    )

    const message = extractMessage(result)
    expect(message).toBeTruthy()
    expect(message!.entities).toBeTruthy()
    expect(message!.entities!.entities).toHaveLength(2)

    const [providedMention, missingMention] = message!.entities!.entities
    expect(providedMention!.entity.oneofKind).toBe("mention")
    if (providedMention!.entity.oneofKind !== "mention") {
      throw new Error("Expected mention entity")
    }
    expect(providedMention!.entity.mention.userId).toBe(BigInt(providedUser.id))
    expect(providedMention!.offset).toBe(0n)
    expect(providedMention!.length).toBe(13n)

    expect(missingMention!.entity.oneofKind).toBe("mention")
    if (missingMention!.entity.oneofKind !== "mention") {
      throw new Error("Expected mention entity")
    }
    expect(missingMention!.entity.mention.userId).toBe(BigInt(missingUser.id))
    expect(missingMention!.offset).toBe(18n)
    expect(missingMention!.length).toBe(12n)
  })

  test("does not parse @username when mention range is partly covered by a client entity", async () => {
    const mentionedUser = await testUtils.createUser(nextEmail("partial-overlap-user"))
    await db.update(users).set({ username: "partialoverlap" }).where(eq(users.id, mentionedUser.id)).execute()

    const result = await sendMessage(
      {
        peerId: privateChatPeerId,
        message: "hello @partialoverlap world",
        entities: {
          entities: [
            {
              type: MessageEntity_Type.BOLD,
              offset: 9n,
              length: 4n,
              entity: {
                oneofKind: undefined,
              },
            },
          ],
        },
      },
      context,
    )

    const message = extractMessage(result)
    expect(message).toBeTruthy()
    expect(message!.entities).toBeTruthy()
    expect(message!.entities!.entities).toHaveLength(1)
    expect(message!.entities!.entities[0]!.type).toBe(MessageEntity_Type.BOLD)
    expect(message!.entities!.entities.some((entity) => entity!.type === MessageEntity_Type.MENTION)).toBe(false)
  })

  test("does not parse @username when overlap with client entity is a single character", async () => {
    const mentionedUser = await testUtils.createUser(nextEmail("single-char-overlap-user"))
    await db.update(users).set({ username: "singlecharoverlap" }).where(eq(users.id, mentionedUser.id)).execute()

    const result = await sendMessage(
      {
        peerId: privateChatPeerId,
        message: "hello @singlecharoverlap",
        entities: {
          entities: [
            {
              type: MessageEntity_Type.ITALIC,
              offset: 6n,
              length: 1n,
              entity: {
                oneofKind: undefined,
              },
            },
          ],
        },
      },
      context,
    )

    const message = extractMessage(result)
    expect(message).toBeTruthy()
    expect(message!.entities).toBeTruthy()
    expect(message!.entities!.entities).toHaveLength(1)
    expect(message!.entities!.entities[0]!.type).toBe(MessageEntity_Type.ITALIC)
    expect(message!.entities!.entities.some((entity) => entity!.type === MessageEntity_Type.MENTION)).toBe(false)
  })

  test("unarchives recipient dialog and enqueues a user update", async () => {
    const sender = (await testUtils.createUser(nextEmail("sender")))!
    const recipient = (await testUtils.createUser(nextEmail("recipient")))!
    const { chat } = await testUtils.createPrivateChatWithOptionalDialog({
      userA: sender,
      userB: recipient,
      createDialogForUserA: true,
      createDialogForUserB: true,
    })

    await db
      .update(dialogs)
      .set({ archived: true })
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, recipient.id)))
      .execute()

    const peerId: InputPeer = {
      type: { oneofKind: "chat" as const, chat: { chatId: BigInt(chat.id) } },
    }
    const senderContext = testUtils.functionContext({ userId: sender.id, sessionId: 1 })

    await sendMessage({ peerId, message: "hello" }, senderContext)

    const [updatedDialog] = await db
      .select()
      .from(dialogs)
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, recipient.id)))
      .limit(1)

    expect(updatedDialog?.archived).toBe(false)

    const userUpdates = await db.query.updates.findMany({
      where: {
        bucket: UpdateBucket.User,
        entityId: recipient.id,
      },
    })

    const hasDialogArchivedUpdate = userUpdates
      .map((update) => UpdatesModel.decrypt(update))
      .some(
        (update) =>
          update.payload.update.oneofKind === "userDialogArchived" &&
          update.payload.update.userDialogArchived.archived === false,
      )

    expect(hasDialogArchivedUpdate).toBe(true)
  })

  test("promotes mentioned users into sidebar-visible reply-thread dialogs", async () => {
    const owner = await testUtils.createUser(nextEmail("thread-owner"))
    const mentioned = await testUtils.createUser(nextEmail("thread-mentioned"))
    await db.update(users).set({ username: "replythreadmentioned" }).where(eq(users.id, mentioned.id)).execute()

    const parentChat = await testUtils.createChat(null, "Parent Thread", "thread", false, owner.id)
    if (!parentChat) throw new Error("Parent chat not created")

    await testUtils.addParticipant(parentChat.id, owner.id)
    await testUtils.addParticipant(parentChat.id, mentioned.id)

    await db.insert(messages).values({
      chatId: parentChat.id,
      messageId: 1,
      fromId: owner.id,
      text: "anchor",
    })

    const [childChat] = await db
      .insert(chats)
      .values({
        type: "thread",
        title: "Re: anchor",
        publicThread: false,
        createdBy: owner.id,
        parentChatId: parentChat.id,
        parentMessageId: 1,
      })
      .returning()

    if (!childChat) throw new Error("Child chat not created")

    await sendMessage(
      {
        peerId: {
          type: { oneofKind: "chat", chat: { chatId: BigInt(childChat.id) } },
        },
        message: "hello @replythreadmentioned",
      },
      testUtils.functionContext({ userId: owner.id, sessionId: 1 }),
    )

    const [recipientDialog] = await db
      .select()
      .from(dialogs)
      .where(and(eq(dialogs.chatId, childChat.id), eq(dialogs.userId, mentioned.id)))
      .limit(1)

    expect(recipientDialog?.sidebarVisible).toBe(true)

    const userUpdates = await db.query.updates.findMany({
      where: {
        bucket: UpdateBucket.User,
        entityId: mentioned.id,
      },
    })

    const hasChatOpenUpdate = userUpdates
      .map((update) => UpdatesModel.decrypt(update))
      .some((update) => update.payload.update.oneofKind === "userChatOpen")

    expect(hasChatOpenUpdate).toBe(true)
  })

  test("promotes replied-to authors into sidebar-visible reply-thread dialogs", async () => {
    const owner = await testUtils.createUser(nextEmail("thread-reply-owner"))
    const repliedUser = await testUtils.createUser(nextEmail("thread-replied-user"))

    const parentChat = await testUtils.createChat(null, "Parent Thread", "thread", false, owner.id)
    if (!parentChat) throw new Error("Parent chat not created")

    await testUtils.addParticipant(parentChat.id, owner.id)
    await testUtils.addParticipant(parentChat.id, repliedUser.id)

    await db.insert(messages).values({
      chatId: parentChat.id,
      messageId: 1,
      fromId: owner.id,
      text: "anchor",
    })

    const [childChat] = await db
      .insert(chats)
      .values({
        type: "thread",
        title: "Re: anchor",
        publicThread: false,
        createdBy: owner.id,
        parentChatId: parentChat.id,
        parentMessageId: 1,
      })
      .returning()

    if (!childChat) throw new Error("Child chat not created")

    await sendMessage(
      {
        peerId: {
          type: { oneofKind: "chat", chat: { chatId: BigInt(childChat.id) } },
        },
        message: "first",
      },
      testUtils.functionContext({ userId: repliedUser.id, sessionId: 1 }),
    )

    await sendMessage(
      {
        peerId: {
          type: { oneofKind: "chat", chat: { chatId: BigInt(childChat.id) } },
        },
        message: "replying",
        replyToMessageId: 1n,
      },
      testUtils.functionContext({ userId: owner.id, sessionId: 1 }),
    )

    const [recipientDialog] = await db
      .select()
      .from(dialogs)
      .where(and(eq(dialogs.chatId, childChat.id), eq(dialogs.userId, repliedUser.id)))
      .limit(1)

    expect(recipientDialog?.sidebarVisible).toBe(true)

    const parentMessages = await getMessages(
      {
        peerId: {
          type: { oneofKind: "chat", chat: { chatId: BigInt(parentChat.id) } },
        },
        messageIds: [1n],
      },
      testUtils.functionContext({ userId: owner.id, sessionId: 1 }),
    )

    expect(parentMessages.messages[0]?.replies?.replyCount).toBe(2)
    expect(parentMessages.messages[0]?.replies?.recentReplierUserIds).toEqual([
      BigInt(owner.id),
      BigInt(repliedUser.id),
    ])
  })

  test("keeps the sender's hidden reply-thread dialog hidden on outbound send", async () => {
    const owner = await testUtils.createUser(nextEmail("thread-hidden-owner"))
    const participant = await testUtils.createUser(nextEmail("thread-hidden-participant"))

    const parentChat = await testUtils.createChat(null, "Parent Thread", "thread", false, owner.id)
    if (!parentChat) throw new Error("Parent chat not created")

    await testUtils.addParticipant(parentChat.id, owner.id)
    await testUtils.addParticipant(parentChat.id, participant.id)

    await db.insert(messages).values({
      chatId: parentChat.id,
      messageId: 1,
      fromId: owner.id,
      text: "anchor",
    })

    const [childChat] = await db
      .insert(chats)
      .values({
        type: "thread",
        title: "Re: anchor",
        publicThread: false,
        createdBy: owner.id,
        parentChatId: parentChat.id,
        parentMessageId: 1,
      })
      .returning()

    if (!childChat) throw new Error("Child chat not created")

    await db.insert(dialogs).values({
      chatId: childChat.id,
      userId: owner.id,
      sidebarVisible: false,
    })

    await sendMessage(
      {
        peerId: {
          type: { oneofKind: "chat", chat: { chatId: BigInt(childChat.id) } },
        },
        message: "still hidden",
      },
      testUtils.functionContext({ userId: owner.id, sessionId: 1 }),
    )

    const [senderDialog] = await db
      .select()
      .from(dialogs)
      .where(and(eq(dialogs.chatId, childChat.id), eq(dialogs.userId, owner.id)))
      .limit(1)

    expect(senderDialog?.sidebarVisible).toBe(false)
  })
})
