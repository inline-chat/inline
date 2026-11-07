import { describe, expect, test } from "bun:test"
import { MessageEntity_Type, type InputPeer } from "@inline-chat/protocol/core"
import { and, eq } from "drizzle-orm"
import { db } from "@in/server/db"
import { chats, dialogs, users, UpdateBucket } from "@in/server/db/schema"
import { UpdatesModel } from "@in/server/db/models/updates"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { updateDialogOpen } from "@in/server/functions/messages.updateDialogOpen"
import { setupTestLifecycle, testUtils } from "../setup"

describe("scheduled bot mentions", () => {
  setupTestLifecycle()

  for (const linked of [false, true]) {
    test(`a Markdown mention reopens an explicitly closed ${linked ? "linked " : ""}thread`, async () => {
      const recipient = await testUtils.createUser("scheduled-recipient@example.test")
      const bot = await testUtils.createUser("scheduled-bot@example.test")
      await db.update(users).set({ bot: true, botCreatorId: recipient.id }).where(eq(users.id, bot.id))

      const parent = linked
        ? await testUtils.createChat(null, "Scheduled tasks", "thread", false, recipient.id)
        : undefined
      if (linked && !parent) throw new Error("Expected parent chat")
      if (parent) {
        await testUtils.addParticipant(parent.id, recipient.id)
        await testUtils.addParticipant(parent.id, bot.id)
      }
      const [thread] = await db.insert(chats).values({
        type: "thread", title: "Scheduled brief", publicThread: false, createdBy: recipient.id,
        parentChatId: parent?.id,
      }).returning()
      if (!thread) throw new Error("Expected scheduled thread")
      await testUtils.addParticipant(thread.id, recipient.id)
      await testUtils.addParticipant(thread.id, bot.id)

      const peerId: InputPeer = {
        type: { oneofKind: "chat", chat: { chatId: BigInt(thread.id) } },
      }
      const recipientContext = testUtils.functionContext({ userId: recipient.id })
      const botContext = { ...testUtils.functionContext({ userId: bot.id }), isBot: true }
      await updateDialogOpen({ peerId, open: false }, recipientContext)
      await db.update(dialogs).set({ followMode: "unfollowed" }).where(and(
        eq(dialogs.chatId, thread.id), eq(dialogs.userId, recipient.id),
      ))
      const readDialog = () => db.query.dialogs.findFirst({
        where: { chatId: thread.id, userId: recipient.id },
      })

      // An unaddressed scheduled post reproduces the closed-thread failure.
      await sendMessage({ peerId, message: "Morning brief", parseMarkdown: true }, botContext)
      expect((await readDialog())?.open).toBe(false)

      const prefixed = `[@Recipient](inline://user?id=${recipient.id})\n\nMorning brief`
      await sendMessage({ peerId, message: prefixed, parseMarkdown: false }, botContext)
      expect((await readDialog())?.open).toBe(false)

      const result = await sendMessage({ peerId, message: prefixed, parseMarkdown: true }, botContext)
      const messageUpdate = result.updates.find((update) => update.update.oneofKind === "newMessage")?.update
      if (messageUpdate?.oneofKind !== "newMessage") throw new Error("Expected sent message")
      const message = messageUpdate.newMessage.message
      expect(message?.message).toBe("@Recipient\n\nMorning brief")
      expect(message?.entities?.entities).toEqual(expect.arrayContaining([
        expect.objectContaining({
          type: MessageEntity_Type.MENTION,
          entity: { oneofKind: "mention", mention: { userId: BigInt(recipient.id) } },
        }),
      ]))

      const reopened = await readDialog()
      expect(reopened?.open).toBe(true)
      expect(reopened?.order).toBeTruthy()
      expect(reopened?.followMode).toBe("unfollowed")
      const updates = await db.query.updates.findMany({
        where: { bucket: UpdateBucket.User, entityId: recipient.id },
      })
      expect(updates.map((update) => UpdatesModel.decrypt(update)).some((update) =>
        update.payload.update.oneofKind === "userChatOpen"
        && update.payload.update.userChatOpen.dialog?.open === true,
      )).toBe(true)
    })
  }
})
