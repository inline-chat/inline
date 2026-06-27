import { describe, expect, test } from "bun:test"
import { db, schema } from "@in/server/db"
import { DialogsModel } from "@in/server/db/models/dialogs"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { getChatHistory } from "@in/server/functions/messages.getChatHistory"
import { pinMessage } from "@in/server/functions/messages.pinMessage"
import { decryptMessage } from "@in/server/modules/encryption/encryptMessage"
import { decryptSystemMessagePayload } from "@in/server/modules/systemMessages"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { and, eq, isNull, not } from "drizzle-orm"

setupTestLifecycle()

describe("messages.pinMessage", () => {
  test("inserts one silent pinned system message on first pin", async () => {
    const owner = await testUtils.createUser("pin-owner@example.com")
    const viewer = await testUtils.createUser("pin-viewer@example.com")
    const chat = await testUtils.createChat(null, "Pinned Thread", "thread", false, owner.id)
    if (!chat) {
      throw new Error("Failed to create pin test chat")
    }

    await testUtils.addParticipant(chat.id, owner.id)
    await testUtils.addParticipant(chat.id, viewer.id)

    const peer = { type: { oneofKind: "chat" as const, chat: { chatId: BigInt(chat.id) } } }
    const sent = await sendMessage(
      {
        peerId: peer,
        message: "pin this",
      },
      testUtils.functionContext({ userId: owner.id, sessionId: 1 }),
    )
    const messageId = sent.updates[0]?.update.oneofKind === "updateMessageId"
      ? sent.updates[0].update.updateMessageId.messageId
      : undefined
    expect(messageId).toBeTruthy()

    await db.insert(schema.dialogs).values({
      chatId: chat.id,
      userId: viewer.id,
      readInboxMaxId: Number(messageId),
    })

    await pinMessage(
      {
        peer,
        messageId: messageId!,
        unpin: false,
      },
      testUtils.functionContext({ userId: owner.id, sessionId: 1 }),
    )
    await pinMessage(
      {
        peer,
        messageId: messageId!,
        unpin: false,
      },
      testUtils.functionContext({ userId: owner.id, sessionId: 1 }),
    )

    const [pinnedMessage] = await db
      .select({ globalId: schema.messages.globalId })
      .from(schema.messages)
      .where(and(eq(schema.messages.chatId, chat.id), eq(schema.messages.messageId, Number(messageId))))
      .limit(1)

    const systemRows = await db
      .select()
      .from(schema.messages)
      .where(
        and(
          eq(schema.messages.chatId, chat.id),
          not(isNull(schema.messages.systemMessageEncrypted)),
          isNull(schema.messages.entitiesEncrypted),
          isNull(schema.messages.actionsEncrypted),
        ),
      )

    expect(systemRows).toHaveLength(1)
    const systemRow = systemRows[0]!
    expect(systemRow.systemMessageEncrypted).toBeTruthy()
    expect(systemRow.systemMessageIv).toBeTruthy()
    expect(systemRow.systemMessageTag).toBeTruthy()
    expect(systemRow.textEncrypted).toBeTruthy()
    expect(systemRow.textIv).toBeTruthy()
    expect(systemRow.textTag).toBeTruthy()
    expect(
      decryptMessage({
        encrypted: systemRow.textEncrypted!,
        iv: systemRow.textIv!,
        authTag: systemRow.textTag!,
      }),
    ).toBe("Pinned a message")
    expect(
      decryptSystemMessagePayload({
        encrypted: systemRow.systemMessageEncrypted!,
        iv: systemRow.systemMessageIv!,
        authTag: systemRow.systemMessageTag!,
      }),
    ).toEqual({
      event: {
        oneofKind: "pinnedMessage",
        pinnedMessage: {
          pinnedMessageGlobalId: pinnedMessage!.globalId,
          pinnedMessageId: messageId,
        },
      },
    })

    const history = await getChatHistory(
      { peerId: peer, limit: 1 },
      testUtils.functionContext({ userId: viewer.id, sessionId: 2 }),
    )
    expect(history.messages).toHaveLength(1)
    expect(history.messages[0]?.message).toBe("Pinned a message")

    await expect(DialogsModel.getUnreadCount(chat.id, viewer.id)).resolves.toBe(0)
  })
})
