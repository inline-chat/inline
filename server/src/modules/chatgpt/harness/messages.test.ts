import { describe, expect, test } from "bun:test"
import { type InputPeer, type RichMessage } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { users } from "@in/server/db/schema"
import { RichTextValidationError } from "@in/server/modules/message/richText"
import { editInternalBotMessage, sendInternalBotMessage } from "@in/server/modules/chatgpt/harness/messages"
import { eq } from "drizzle-orm"
import { setupTestLifecycle, testUtils } from "../../../__tests__/setup"

setupTestLifecycle()

describe("ChatGPT harness messages", () => {
  test("rejects invalid internal rich media refs during internal bot edits", async () => {
    const actor = await testUtils.createUser("chatgpt-edit-actor@example.com")
    const bot = await testUtils.createUser("chatgpt-edit-bot@example.com")
    await db.update(users).set({ bot: true }).where(eq(users.id, bot.id))

    const chat = await testUtils.createPrivateChat(actor, actor)
    if (!chat) {
      throw new Error("Failed to create chat")
    }

    const inputPeer: InputPeer = {
      type: { oneofKind: "chat", chat: { chatId: BigInt(chat.id) } },
    }

    const message = await sendInternalBotMessage({
      inputPeer,
      actorUserId: actor.id,
      botUserId: bot.id,
      text: "initial",
      resolveRichMedia: false,
    })

    await expect(
      editInternalBotMessage({
        inputPeer,
        actorUserId: actor.id,
        botUserId: bot.id,
        outputMsgGlobalId: message.globalId,
        text: "invalid rich media",
        richText: richPhotoMessage(9_999_999),
        resolveRichMedia: false,
      }),
    ).rejects.toBeInstanceOf(RichTextValidationError)
  })
})

function richPhotoMessage(photoId: number): RichMessage {
  return {
    version: 1,
    fallbackText: "Invalid rich photo",
    blocks: [
      {
        blockId: "invalid-rich-photo",
        block: {
          oneofKind: "photo",
          photo: {
            media: {
              alt: "Invalid rich photo",
              width: 320,
              height: 180,
              media: { oneofKind: "photoId", photoId: BigInt(photoId) },
            },
            caption: [],
          },
        },
      },
    ],
  }
}
