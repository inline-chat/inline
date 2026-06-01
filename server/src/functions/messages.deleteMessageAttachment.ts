import type { DeleteMessageAttachmentInput, DeleteMessageAttachmentResult, InputPeer, MessageAttachment, Update } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { ChatModel } from "@in/server/db/models/chats"
import { UpdatesModel, type UpdateSeqAndDate } from "@in/server/db/models/updates"
import { chats, messageAttachments, messages } from "@in/server/db/schema"
import { UpdateBucket } from "@in/server/db/schema/updates"
import type { FunctionContext } from "@in/server/functions/_types"
import { getUpdateGroupFromInputPeer, type UpdateGroup } from "@in/server/modules/updates"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { encodeMessageAttachmentUpdate } from "@in/server/realtime/encoders/encodeMessageAttachment"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { Log } from "@in/server/utils/log"
import { and, eq } from "drizzle-orm"

const log = new Log("functions.deleteMessageAttachment")

export const deleteMessageAttachment = async (
  input: DeleteMessageAttachmentInput,
  context: FunctionContext,
): Promise<DeleteMessageAttachmentResult> => {
  if (!input.peerId) {
    throw RealtimeRpcError.PeerIdInvalid()
  }

  const messageId = toPositiveSafeInteger(input.messageId)
  const attachmentId = toPositiveSafeInteger(input.attachmentId)
  const chat = await ChatModel.getChatFromInputPeer(input.peerId, context)
  await AccessGuards.ensureChatAccess(chat, context.currentUserId)

  const { update } = await db.transaction(async (tx) => {
    const [lockedChat] = await tx.select().from(chats).where(eq(chats.id, chat.id)).for("update").limit(1)
    if (!lockedChat) {
      throw RealtimeRpcError.PeerIdInvalid()
    }

    const [message] = await tx
      .select()
      .from(messages)
      .where(and(eq(messages.chatId, chat.id), eq(messages.messageId, messageId)))
      .limit(1)

    if (!message) {
      throw RealtimeRpcError.MessageIdInvalid()
    }

    if (message.fromId !== context.currentUserId) {
      log.warn("deleteMessageAttachment blocked: message author mismatch", {
        chatId: chat.id,
        messageId,
        attachmentId,
        fromId: message.fromId,
        currentUserId: context.currentUserId,
      })
      throw RealtimeRpcError.BadRequest()
    }

    const [attachment] = await tx
      .select()
      .from(messageAttachments)
      .where(and(eq(messageAttachments.id, attachmentId), eq(messageAttachments.messageId, message.globalId)))
      .limit(1)

    if (!attachment || attachment.urlPreviewId == null) {
      throw RealtimeRpcError.BadRequest()
    }

    await tx
      .delete(messageAttachments)
      .where(and(eq(messageAttachments.id, attachmentId), eq(messageAttachments.messageId, message.globalId)))

    const update = await UpdatesModel.insertUpdate(tx, {
      update: {
        oneofKind: "messageAttachment",
        messageAttachment: {
          chatId: BigInt(chat.id),
          msgId: BigInt(message.messageId),
          attachmentId: BigInt(attachmentId),
        },
      },
      bucket: UpdateBucket.Chat,
      entity: lockedChat,
    })

    await tx
      .update(chats)
      .set({
        updateSeq: update.seq,
        lastUpdateDate: update.date,
      })
      .where(eq(chats.id, chat.id))

    return { update }
  })

  const deletedAttachment: MessageAttachment = {
    id: BigInt(attachmentId),
    attachment: { oneofKind: undefined },
  }

  const { selfUpdates } = await pushUpdates({
    inputPeer: input.peerId,
    messageId,
    chatId: chat.id,
    attachment: deletedAttachment,
    currentUserId: context.currentUserId,
    update,
  })

  return { updates: selfUpdates }
}

function toPositiveSafeInteger(id: bigint): number {
  const value = Number(id)
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw RealtimeRpcError.BadRequest()
  }
  return value
}

async function pushUpdates(input: {
  inputPeer: InputPeer
  messageId: number
  chatId: number
  attachment: MessageAttachment
  currentUserId: number
  update: UpdateSeqAndDate
}): Promise<{ selfUpdates: Update[]; updateGroup: UpdateGroup }> {
  const updateGroup = await getUpdateGroupFromInputPeer(input.inputPeer, { currentUserId: input.currentUserId })
  const selfUpdates: Update[] = []

  updateGroup.userIds.forEach((userId) => {
    const encodingForInputPeer: InputPeer =
      updateGroup.type === "dmUsers" && userId !== input.currentUserId
        ? { type: { oneofKind: "user", user: { userId: BigInt(input.currentUserId) } } }
        : input.inputPeer

    const update = encodeMessageAttachmentUpdate({
      messageId: BigInt(input.messageId),
      chatId: BigInt(input.chatId),
      encodingForUserId: userId,
      encodingForPeer: { inputPeer: encodingForInputPeer },
      attachment: input.attachment,
      seq: input.update.seq,
      date: input.update.date,
    })

    RealtimeUpdates.pushToUser(userId, [update])
    if (userId === input.currentUserId) {
      selfUpdates.push(update)
    }
  })

  return { selfUpdates, updateGroup }
}
