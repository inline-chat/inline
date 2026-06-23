import { describe, expect, test } from "bun:test"
import { RpcError_Code, type InputPeer, type RichMessage, type SendMessageResult } from "@inline-chat/protocol/core"
import { editMessage } from "@in/server/realtime/handlers/messages.editMessage"
import { sendMessage } from "@in/server/realtime/handlers/messages.sendMessage"
import type { HandlerContext } from "@in/server/realtime/types"
import { setupTestLifecycle, testUtils, defaultTestContext } from "../setup"

describe("rich text Realtime message handlers", () => {
  setupTestLifecycle()

  test("maps invalid rich media on send to a bad request rpc error", async () => {
    const { ctx, peerId } = await createChatContext("rich-realtime-send")

    await expect(
      sendMessage(
        {
          peerId,
          message: "invalid rich media",
          richText: richPhotoMessage(9_999_999),
        },
        ctx,
      ),
    ).rejects.toMatchObject({
      code: RpcError_Code.BAD_REQUEST,
      codeNumber: 400,
    })
  })

  test("maps invalid rich media on edit to a bad request rpc error", async () => {
    const { ctx, peerId } = await createChatContext("rich-realtime-edit")
    const sent = await sendMessage(
      {
        peerId,
        message: "before invalid rich edit",
      },
      ctx,
    )

    await expect(
      editMessage(
        {
          peerId,
          messageId: messageIdFromSend(sent),
          text: "invalid rich edit",
          richText: richPhotoMessage(9_999_999),
        },
        ctx,
      ),
    ).rejects.toMatchObject({
      code: RpcError_Code.BAD_REQUEST,
      codeNumber: 400,
    })
  })
})

async function createChatContext(label: string): Promise<{ ctx: HandlerContext; peerId: InputPeer }> {
  const user = await testUtils.createUser(`${label}-${Date.now()}@example.com`)
  const chat = await testUtils.createChat(null, label, "thread", false, user.id)
  if (!chat) {
    throw new Error("Failed to create test chat")
  }
  await testUtils.addParticipant(chat.id, user.id)

  return {
    ctx: handlerContext(user.id, label),
    peerId: { type: { oneofKind: "chat", chat: { chatId: BigInt(chat.id) } } },
  }
}

function handlerContext(userId: number, connectionId: string): HandlerContext {
  return {
    userId,
    sessionId: defaultTestContext.sessionId,
    connectionId,
    sendRaw: () => {},
    sendRpcReply: () => {},
  }
}

function messageIdFromSend(result: SendMessageResult): bigint {
  const update = result.updates.find((item) => item.update.oneofKind === "updateMessageId")
  if (update?.update.oneofKind !== "updateMessageId" || !update.update.updateMessageId?.messageId) {
    throw new Error("Send result did not include a message id update")
  }
  return update.update.updateMessageId.messageId
}

function richPhotoMessage(photoId: number): RichMessage {
  return {
    version: 1,
    fallbackText: "Embedded rich photo",
    blocks: [
      {
        blockId: "invalid-rich-photo",
        block: {
          oneofKind: "photo",
          photo: {
            media: {
              alt: "Invalid embedded photo",
              width: 320,
              height: 180,
              media: { oneofKind: "photoId", photoId: BigInt(photoId) },
            },
            caption: [
              {
                text: "Invalid rich photo caption",
                children: [],
                styles: [],
              },
            ],
          },
        },
      },
    ],
  }
}
