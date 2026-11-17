import {
  BlockContent,
  BlockDecisionState,
  InputPeer,
  Update,
  type Block,
  type BlockImage,
  type Photo,
} from "@inline-chat/protocol/core"
import { ChatModel } from "@in/server/db/models/chats"
import { FileModel } from "@in/server/db/models/files"
import { MessageModel } from "@in/server/db/models/messages"
import { db } from "@in/server/db"
import { urlPreview } from "@in/server/db/schema/attachments"
import { messages } from "@in/server/db/schema"
import type { FunctionContext } from "@in/server/functions/_types"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { Log } from "@in/server/utils/log"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { collectReadyBlockPhotoIds, projectReadyBlockPhotos } from "@in/server/modules/message/blockContent"
import { encodePhoto } from "@in/server/realtime/encoders/encodePhoto"
import { and, eq, inArray, isNotNull } from "drizzle-orm"
import { isSubthreadParentMessage } from "@in/server/modules/subthreads"

const log = new Log("functions.forwardMessages")

type Input = {
  fromPeerId: InputPeer
  toPeerId: InputPeer
  messageIds: bigint[]
  shareForwardHeader?: boolean
}

type Output = {
  updates: Update[]
  messageIds: number[]
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
      provider: existing.provider,
      mediaType: existing.mediaType,
      title: existing.title,
      titleIv: existing.titleIv,
      titleTag: existing.titleTag,
      description: existing.description,
      descriptionIv: existing.descriptionIv,
      descriptionTag: existing.descriptionTag,
      author: existing.author,
      authorIv: existing.authorIv,
      authorTag: existing.authorTag,
      mediaKind: existing.mediaKind,
      photoId: existing.photoId,
      authorPhotoId: existing.authorPhotoId,
      videoId: existing.videoId,
      documentId: existing.documentId,
      externalUrl: existing.externalUrl,
      externalUrlIv: existing.externalUrlIv,
      externalUrlTag: existing.externalUrlTag,
      externalMimeType: existing.externalMimeType,
      externalWidth: existing.externalWidth,
      externalHeight: existing.externalHeight,
      externalDuration: existing.externalDuration,
      embedUrl: existing.embedUrl,
      embedUrlIv: existing.embedUrlIv,
      embedUrlTag: existing.embedUrlTag,
      embedType: existing.embedType,
      embedWidth: existing.embedWidth,
      embedHeight: existing.embedHeight,
      embedDuration: existing.embedDuration,
      hasLargeMedia: existing.hasLargeMedia,
      showLargeMedia: existing.showLargeMedia,
      cacheId: existing.cacheId,
      duration: existing.duration,
      date: new Date(),
    })
    .returning()

  return cloned?.id ?? null
}

const cloneForwardedBlockContent = async (
  blockContent: BlockContent | null | undefined,
  currentUserId: number,
  options: { keepWidgets: boolean },
): Promise<BlockContent | undefined> => {
  if (!blockContent) return undefined
  const clonedPhotos = new Map<bigint, Photo>()
  for (const sourcePhotoId of collectReadyBlockPhotoIds(blockContent)) {
    const clonedPhotoId = await FileModel.clonePhotoById(Number(sourcePhotoId), currentUserId)
    const clonedPhoto = await FileModel.getPhotoById(BigInt(clonedPhotoId))
    if (!clonedPhoto) throw RealtimeRpcError.InternalError()
    clonedPhotos.set(sourcePhotoId, encodePhoto({ photo: clonedPhoto }))
  }
  return snapshotForwardedBlockContent(
    projectReadyBlockPhotos(blockContent, clonedPhotos),
    options,
  )
}

/** Widgets are bot content: a copy that names no bot sender keeps only the title. */
export const snapshotForwardedBlockContent = (
  content: BlockContent,
  options: { keepWidgets: boolean } = { keepWidgets: true },
): BlockContent => {
  const snapshot = BlockContent.fromBinary(BlockContent.toBinary(content))
  const image = (value: BlockImage): void => {
    if (value.state.oneofKind !== "pending") return
    value.state = {
      oneofKind: "unavailable",
      unavailable: { dimensions: value.state.pending.dimensions },
    }
  }
  const blocks = (values: Block[]): void => {
    for (const [index, block] of values.entries()) {
      switch (block.kind.oneofKind) {
        case "widget":
          if (!options.keepWidgets && block.kind.widget.title) {
            values[index] = { kind: { oneofKind: "paragraph", paragraph: block.kind.widget.title } }
          }
          break
        case "image": image(block.kind.image); break
        case "album": block.kind.album.images.forEach(image); break
        case "disclosure": blocks(block.kind.disclosure.children); break
        case "quote": blocks(block.kind.quote.children); break
        case "list": block.kind.list.items.forEach((item) => blocks(item.children)); break
        case "callout": blocks(block.kind.callout.children); break
        // A copy carries no message actions, so blocks name none as their buttons, and an open
        // decision can't be made from it: it reads as expired rather than waiting.
        case "planProposal":
          block.kind.planProposal.actionIds = []
          block.kind.planProposal.state = closedDecision(block.kind.planProposal.state)
          blocks(block.kind.planProposal.children)
          break
        case "approval":
          block.kind.approval.actionIds = []
          block.kind.approval.state = closedDecision(block.kind.approval.state)
          blocks(block.kind.approval.children)
          break
        case "review": for (const finding of block.kind.review.findings) delete finding.actionId; break
        case "taskSuggestion":
          block.kind.taskSuggestion.actionIds = []
          block.kind.taskSuggestion.state = closedDecision(block.kind.taskSuggestion.state)
          // The started thread belongs to the source chat; the destination may not reach it.
          delete block.kind.taskSuggestion.startedPeer
          break
        case "nextStep":
          block.kind.nextStep.actionIds = []
          block.kind.nextStep.blocking = false
          break
      }
    }
  }
  blocks(snapshot.blocks)
  return snapshot
}

function closedDecision(state: BlockDecisionState): BlockDecisionState {
  return state === BlockDecisionState.PENDING || state === BlockDecisionState.UNSPECIFIED
    ? BlockDecisionState.EXPIRED
    : state
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

  const sourceChat = await ChatModel.getChatFromInputPeerUnchecked(input.fromPeerId, context)
  const destinationChat = await ChatModel.getChatFromInputPeerUnchecked(input.toPeerId, context)

  await AccessGuards.ensureChatAccess(sourceChat, currentUserId)
  await AccessGuards.ensureChatAccess(destinationChat, currentUserId)

  const normalizedFromPeer = normalizeForwardPeer(input.fromPeerId, currentUserId)
  const updates: Update[] = []
  const messageIds: number[] = []

  log.debug("forwardMessages start", {
    fromPeerId: input.fromPeerId.type.oneofKind,
    toPeerId: input.toPeerId.type.oneofKind,
    messageCount: input.messageIds.length,
    currentUserId,
  })

  // Album members forwarded together stay one album in the destination, under a new id.
  const forwardedGroupedIds = forwardedAlbumIds(
    await db
      .select({ messageId: messages.messageId, fromId: messages.fromId, groupedId: messages.groupedId })
      .from(messages)
      .where(
        and(
          eq(messages.chatId, sourceChat.id),
          inArray(
            messages.messageId,
            input.messageIds.map((id) => Number(id)),
          ),
          isNotNull(messages.groupedId),
        ),
      ),
  )

  for (const messageId of input.messageIds) {
    let sourceMessage: Awaited<ReturnType<typeof MessageModel.getMessage>>
    try {
      sourceMessage = await MessageModel.getMessage(Number(messageId), sourceChat.id)
    } catch (error) {
      log.error("forwardMessages failed to fetch source message", { messageId, sourceChatId: sourceChat.id, error })
      throw RealtimeRpcError.MessageIdInvalid()
    }

    if (await isSubthreadParentMessage(sourceMessage.globalId)) {
      throw RealtimeRpcError.BadRequest()
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

      const isSelfDmMessage =
        sourceChat.type === "private" &&
        sourceChat.minUserId != null &&
        sourceChat.maxUserId != null &&
        sourceChat.minUserId !== sourceChat.maxUserId &&
        sourceMessage.fromId === currentUserId

      if (!forwardHeader && !isSelfDmMessage) {
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
    let voiceId: bigint | undefined

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

    if (sourceMessage.voiceId) {
      const clonedVoiceId = await FileModel.cloneVoiceById(sourceMessage.voiceId, currentUserId)
      voiceId = BigInt(clonedVoiceId)
    }

    const blockContent = await cloneForwardedBlockContent(
      sourceMessage.blockContent,
      currentUserId,
      { keepWidgets: forwardHeader !== undefined || (context.isBot === true && sourceMessage.fromId === currentUserId) },
    )

    const result = await sendMessage(
      {
        peerId: input.toPeerId,
        message: sourceMessage.text ?? undefined,
        entities: sourceMessage.entities ?? undefined,
        photoId: photoId,
        videoId: videoId,
        documentId: documentId,
        voiceId: voiceId,
        isSticker: sourceMessage.isSticker ?? false,
        forwardHeader: forwardHeader,
        messageAttachments: attachments,
        blockContent,
        skipLinkProcessing: true,
        groupedId: forwardedGroupedIds.get(sourceMessage.messageId),
      },
      context,
    )

    updates.push(...result.updates)
    const sentMessageId = result.updates.find(
      (candidate) => candidate.update.oneofKind === "updateMessageId",
    )?.update
    if (sentMessageId?.oneofKind !== "updateMessageId") {
      throw RealtimeRpcError.InternalError()
    }
    messageIds.push(Number(sentMessageId.updateMessageId.messageId))
  }

  log.debug("forwardMessages complete", { updateCount: updates.length, currentUserId })

  return { updates, messageIds }
}

/**
 * New album ids for forwarded album members: messages of one source album
 * (same sender, same grouped id) get one fresh id when at least two of them
 * are forwarded; a lone member is forwarded as a plain message. Keyed by the
 * source message id.
 */
export function forwardedAlbumIds(
  sourceMessages: readonly { messageId: number; fromId: number; groupedId: bigint | null }[],
  newId: () => bigint = randomAlbumId,
): Map<number, bigint> {
  const groups = new Map<string, number[]>()
  for (const message of sourceMessages) {
    if (!message.groupedId) continue
    const key = `${message.fromId}:${message.groupedId}`
    groups.set(key, [...(groups.get(key) ?? []), message.messageId])
  }
  const ids = new Map<number, bigint>()
  for (const members of groups.values()) {
    if (members.length < 2) continue
    const id = newId()
    for (const messageId of members) ids.set(messageId, id)
  }
  return ids
}

/** A random positive int64. */
export function randomAlbumId(): bigint {
  const bytes = crypto.getRandomValues(new Uint8Array(8))
  bytes[0]! &= 0x7f
  const id = new DataView(bytes.buffer).getBigUint64(0)
  return id === 0n ? 1n : id
}
