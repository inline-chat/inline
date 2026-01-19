import { InputPeer, Update } from "@in/protocol/core"
import { ChatModel } from "@in/server/db/models/chats"
import { FileModel } from "@in/server/db/models/files"
import { MessageModel } from "@in/server/db/models/messages"
import { db } from "@in/server/db"
import { urlPreview } from "@in/server/db/schema/attachments"
import type { FunctionContext } from "@in/server/functions/_types"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { Log } from "@in/server/utils/log"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { eq } from "drizzle-orm"

const log = new Log("functions.forwardMessages")

type Input = {
  fromPeerId: InputPeer
  toPeerId: InputPeer
  messageIds: bigint[]
  shareForwardHeader?: boolean
}

type Output = {
  updates: Update[]
}

const normalizeForwardPeer = (peer: InputPeer, currentUserId: number): InputPeer => {
  switch (peer.type.oneofKind) {
    case "self":
      return { type: { oneofKind: "user", user: { userId: BigInt(currentUserId) } } }
    default:
      return peer
  }
}

const buildForwardPeerFromMessage = (message: {
  fwdFromPeerChatId?: number | null
  fwdFromPeerUserId?: number | null
}): InputPeer | null => {
  if (message.fwdFromPeerChatId) {
    return { type: { oneofKind: "chat", chat: { chatId: BigInt(message.fwdFromPeerChatId) } } }
  }

  if (message.fwdFromPeerUserId) {
    return { type: { oneofKind: "user", user: { userId: BigInt(message.fwdFromPeerUserId) } } }
  }

  return null
}

const cloneUrlPreviewById = async (previewId: bigint): Promise<number | null> => {
  const previewIdNumber = Number(previewId)
  const [existing] = await db.select().from(urlPreview).where(eq(urlPreview.id, previewIdNumber)).limit(1)

  if (!existing) {
    return null
  }

  const [cloned] = await db
    .insert(urlPreview)
    .values({
      url: existing.url,
      urlIv: existing.urlIv,
      urlTag: existing.urlTag,
      siteName: existing.siteName,
      title: existing.title,
      titleIv: existing.titleIv,
      titleTag: existing.titleTag,
      description: existing.description,
      descriptionIv: existing.descriptionIv,
      descriptionTag: existing.descriptionTag,
      photoId: existing.photoId,
      duration: existing.duration,
      date: new Date(),
    })
    .returning()

  return cloned?.id ?? null
}

export const forwardMessages = async (input: Input, context: FunctionContext): Promise<Output> => {
  if (!input.fromPeerId || !input.toPeerId) {
    throw RealtimeRpcError.PeerIdInvalid()
  }

  if (input.messageIds.length === 0) {
    throw RealtimeRpcError.BadRequest()
  }

  const currentUserId = context.currentUserId
  const shareForwardHeader = input.shareForwardHeader !== false

  const sourceChat = await ChatModel.getChatFromInputPeer(input.fromPeerId, context)
  const destinationChat = await ChatModel.getChatFromInputPeer(input.toPeerId, context)

  try {
    await AccessGuards.ensureChatAccess(sourceChat, currentUserId)
    await AccessGuards.ensureChatAccess(destinationChat, currentUserId)
  } catch (error) {
    log.error("forwardMessages blocked: chat access denied", {
      sourceChatId: sourceChat.id,
      destinationChatId: destinationChat.id,
      currentUserId,
      error,
    })
    throw error
  }

  const normalizedFromPeer = normalizeForwardPeer(input.fromPeerId, currentUserId)
  const updates: Update[] = []

  log.debug("forwardMessages start", {
    fromPeerId: input.fromPeerId.type.oneofKind,
    toPeerId: input.toPeerId.type.oneofKind,
    messageCount: input.messageIds.length,
    currentUserId,
  })

  for (const messageId of input.messageIds) {
    let sourceMessage: Awaited<ReturnType<typeof MessageModel.getMessage>>
    try {
      sourceMessage = await MessageModel.getMessage(Number(messageId), sourceChat.id)
    } catch (error) {
      log.error("forwardMessages failed to fetch source message", { messageId, sourceChatId: sourceChat.id, error })
      throw RealtimeRpcError.MessageIdInvalid()
    }

    let forwardHeader: { fromPeerId: InputPeer; fromId: number; fromMessageId: number } | undefined
    if (shareForwardHeader) {
      if (sourceMessage.fwdFromMessageId && sourceMessage.fwdFromSenderId) {
        const forwardedPeer = buildForwardPeerFromMessage(sourceMessage)
        if (forwardedPeer) {
          forwardHeader = {
            fromPeerId: forwardedPeer,
            fromId: sourceMessage.fwdFromSenderId,
            fromMessageId: sourceMessage.fwdFromMessageId,
          }
        }
      }

      if (!forwardHeader) {
        forwardHeader = {
          fromPeerId: normalizedFromPeer,
          fromId: sourceMessage.fromId,
          fromMessageId: sourceMessage.messageId,
        }
      }
    }

    let attachments: { urlPreviewId: bigint }[] | undefined
    if (sourceMessage.messageAttachments && sourceMessage.messageAttachments.length > 0) {
      const clonedPreviews: { urlPreviewId: bigint }[] = []
      for (const attachment of sourceMessage.messageAttachments) {
        if (!attachment.urlPreviewId) {
          continue
        }

        const clonedPreviewId = await cloneUrlPreviewById(attachment.urlPreviewId)
        if (clonedPreviewId) {
          clonedPreviews.push({ urlPreviewId: BigInt(clonedPreviewId) })
        } else {
          log.warn("forwardMessages failed to clone url preview", {
            messageId,
            sourceChatId: sourceChat.id,
            urlPreviewId: attachment.urlPreviewId,
          })
        }
      }

      attachments = clonedPreviews.length > 0 ? clonedPreviews : undefined
    }

    let photoId: bigint | undefined
    let videoId: bigint | undefined
    let documentId: bigint | undefined

    if (sourceMessage.photoId) {
      const clonedPhotoId = await FileModel.clonePhotoById(sourceMessage.photoId, currentUserId)
      photoId = BigInt(clonedPhotoId)
    }

    if (sourceMessage.videoId) {
      const clonedVideoId = await FileModel.cloneVideoById(sourceMessage.videoId, currentUserId)
      videoId = BigInt(clonedVideoId)
    }

    if (sourceMessage.documentId) {
      const clonedDocumentId = await FileModel.cloneDocumentById(sourceMessage.documentId, currentUserId)
      documentId = BigInt(clonedDocumentId)
    }

    const result = await sendMessage(
      {
        peerId: input.toPeerId,
        message: sourceMessage.text ?? undefined,
        entities: sourceMessage.entities ?? undefined,
        photoId: photoId,
        videoId: videoId,
        documentId: documentId,
        isSticker: sourceMessage.isSticker ?? false,
        forwardHeader: forwardHeader,
        messageAttachments: attachments,
        skipLinkProcessing: true,
      },
      context,
    )

    updates.push(...result.updates)
  }

  log.debug("forwardMessages complete", { updateCount: updates.length, currentUserId })

  return { updates }
}
