import { describe, expect, test } from "bun:test"
import type { InputPeer, Peer } from "@inline-chat/protocol/core"
import { deleteMessageAttachment } from "@in/server/functions/messages.deleteMessageAttachment"
import { db } from "@in/server/db"
import { messageAttachments, urlPreview } from "@in/server/db/schema"
import { UpdateBucket } from "@in/server/db/schema/updates"
import { Sync } from "@in/server/modules/updates/sync"
import { encryptMessage } from "@in/server/modules/encryption/encryptMessage"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { setupTestLifecycle, testUtils } from "../setup"
import { eq } from "drizzle-orm"

const makeUserPeer = (userId: number): InputPeer => ({
  type: {
    oneofKind: "user",
    user: { userId: BigInt(userId) },
  },
})

const makeCorePeer = (userId: number): Peer => ({
  type: {
    oneofKind: "user",
    user: { userId: BigInt(userId) },
  },
})

const createUrlPreviewAttachment = async (messageGlobalId: bigint) => {
  const encryptedUrl = encryptMessage("https://example.com")
  const encryptedTitle = encryptMessage("Example")
  const [preview] = await db
    .insert(urlPreview)
    .values({
      url: encryptedUrl.encrypted,
      urlIv: encryptedUrl.iv,
      urlTag: encryptedUrl.authTag,
      title: encryptedTitle.encrypted,
      titleIv: encryptedTitle.iv,
      titleTag: encryptedTitle.authTag,
      date: new Date(),
    })
    .returning()

  if (!preview) {
    throw new Error("Failed to create URL preview")
  }

  const [attachment] = await db
    .insert(messageAttachments)
    .values({
      messageId: messageGlobalId,
      urlPreviewId: BigInt(preview.id),
    })
    .returning()

  if (!attachment) {
    throw new Error("Failed to create message attachment")
  }

  return attachment
}

describe("deleteMessageAttachment", () => {
  setupTestLifecycle()

  test("removes an authored URL preview attachment through realtime updates", async () => {
    const userA = await testUtils.createUser("delete-preview-a@example.com")
    const userB = await testUtils.createUser("delete-preview-b@example.com")
    const chat = await testUtils.createPrivateChat(userA, userB)
    if (!chat) {
      throw new Error("Failed to create private chat")
    }

    const message = await testUtils.createTestMessage({
      messageId: 1,
      chatId: chat.id,
      fromId: userA.id,
      text: "https://example.com",
    })
    const attachment = await createUrlPreviewAttachment(message.globalId)

    const result = await deleteMessageAttachment(
      {
        peerId: makeUserPeer(userB.id),
        messageId: 1n,
        attachmentId: BigInt(attachment.id),
      },
      testUtils.functionContext({ userId: userA.id }),
    )

    expect(result.updates).toHaveLength(1)
    const [liveUpdate] = result.updates
    expect(liveUpdate?.update.oneofKind).toBe("messageAttachment")
    if (!liveUpdate || liveUpdate.update.oneofKind !== "messageAttachment") {
      throw new Error("Expected messageAttachment update")
    }
    expect(liveUpdate.update.messageAttachment.attachment?.id).toBe(BigInt(attachment.id))
    expect(liveUpdate.update.messageAttachment.attachment?.attachment.oneofKind).toBeUndefined()

    const rows = await db.select().from(messageAttachments).where(eq(messageAttachments.id, attachment.id))
    expect(rows).toHaveLength(0)

    const { updates: dbUpdates } = await Sync.getUpdates({
      bucket: { type: UpdateBucket.Chat, chatId: chat.id },
      seqStart: 0,
      limit: 10,
    })
    const { updates: inflated } = await Sync.processChatUpdates({
      chatId: chat.id,
      peerId: makeCorePeer(userB.id),
      updates: dbUpdates,
      userId: userA.id,
    })

    expect(inflated).toHaveLength(1)
    const [persistedUpdate] = inflated
    expect(persistedUpdate?.update.oneofKind).toBe("messageAttachment")
    if (!persistedUpdate || persistedUpdate.update.oneofKind !== "messageAttachment") {
      throw new Error("Expected persisted messageAttachment update")
    }
    expect(persistedUpdate.update.messageAttachment.attachment?.id).toBe(BigInt(attachment.id))
    expect(persistedUpdate.update.messageAttachment.attachment?.attachment.oneofKind).toBeUndefined()
  })

  test("rejects removal by a non-author", async () => {
    const userA = await testUtils.createUser("delete-preview-non-author-a@example.com")
    const userB = await testUtils.createUser("delete-preview-non-author-b@example.com")
    const chat = await testUtils.createPrivateChat(userA, userB)
    if (!chat) {
      throw new Error("Failed to create private chat")
    }

    const message = await testUtils.createTestMessage({
      messageId: 1,
      chatId: chat.id,
      fromId: userB.id,
      text: "https://example.com",
    })
    const attachment = await createUrlPreviewAttachment(message.globalId)

    await expect(
      deleteMessageAttachment(
        {
          peerId: makeUserPeer(userB.id),
          messageId: 1n,
          attachmentId: BigInt(attachment.id),
        },
        testUtils.functionContext({ userId: userA.id }),
      ),
    ).rejects.toMatchObject({
      code: RealtimeRpcError.Code.BAD_REQUEST,
    })

    const rows = await db.select().from(messageAttachments).where(eq(messageAttachments.id, attachment.id))
    expect(rows).toHaveLength(1)
  })

  test("rejects non URL-preview attachments", async () => {
    const userA = await testUtils.createUser("delete-preview-non-url-a@example.com")
    const userB = await testUtils.createUser("delete-preview-non-url-b@example.com")
    const chat = await testUtils.createPrivateChat(userA, userB)
    if (!chat) {
      throw new Error("Failed to create private chat")
    }

    const message = await testUtils.createTestMessage({
      messageId: 1,
      chatId: chat.id,
      fromId: userA.id,
      text: "plain message",
    })
    const [attachment] = await db
      .insert(messageAttachments)
      .values({ messageId: message.globalId })
      .returning()
    if (!attachment) {
      throw new Error("Failed to create attachment")
    }

    await expect(
      deleteMessageAttachment(
        {
          peerId: makeUserPeer(userB.id),
          messageId: 1n,
          attachmentId: BigInt(attachment.id),
        },
        testUtils.functionContext({ userId: userA.id }),
      ),
    ).rejects.toMatchObject({
      code: RealtimeRpcError.Code.BAD_REQUEST,
    })

    const rows = await db.select().from(messageAttachments).where(eq(messageAttachments.id, attachment.id))
    expect(rows).toHaveLength(1)
  })
})
