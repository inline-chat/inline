import {
  BlockContent,
  InputPeer,
  MessageEntities,
  MessageEntity_Type,
  Update,
  type ForwardMessageReceipt,
  type ForwardMessageSubmission,
  type Block,
  type BlockImage,
  type Photo,
  type Message,
} from "@inline-chat/protocol/core"
import { ChatModel } from "@in/server/db/models/chats"
import { FileModel } from "@in/server/db/models/files"
import { MessageModel } from "@in/server/db/models/messages"
import { db } from "@in/server/db"
import { urlPreview } from "@in/server/db/schema/attachments"
import { chats, messages, messageSubmissions, messageAttachments, externalTasks, blockContents } from "@in/server/db/schema"
import type { Transaction } from "@in/server/db/types"
import { createHash, randomBytes } from "node:crypto"
import { Encryption2 } from "@in/server/modules/encryption/encryption2"
import type { FunctionContext } from "@in/server/functions/_types"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { collectReadyBlockPhotoIds, projectReadyBlockPhotos } from "@in/server/modules/message/blockContent"
import { encodePhoto } from "@in/server/realtime/encoders/encodePhoto"
import { encodeFullMessage } from "@in/server/realtime/encoders/encodeMessage"
import { getMessageThreadProjectionsMap } from "@in/server/modules/subthreads"
import { and, asc, eq, inArray, sql } from "drizzle-orm"

type Input = {
  fromPeerId: InputPeer
  toPeerId: InputPeer
  messageIds: bigint[]
  shareForwardHeader?: boolean
  submissions?: ForwardMessageSubmission[]
}

type Output = {
  updates: Update[]
  messageIds: number[]
  receipts: ForwardMessageReceipt[]
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

const cloneUrlPreviewById = async (previewId: bigint, currentUserId: number, tx: Transaction): Promise<number | null> => {
  const previewIdNumber = Number(previewId)
  const [existing] = await tx.select().from(urlPreview).where(eq(urlPreview.id, previewIdNumber)).limit(1)

  if (!existing) {
    return null
  }

  const [cloned] = await tx
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
      photoId: existing.photoId ? await FileModel.clonePhotoById(existing.photoId, currentUserId, tx) : null,
      authorPhotoId: existing.authorPhotoId ? await FileModel.clonePhotoById(existing.authorPhotoId, currentUserId, tx) : null,
      videoId: existing.videoId ? await FileModel.cloneVideoById(existing.videoId, currentUserId, tx) : null,
      documentId: existing.documentId ? await FileModel.cloneDocumentById(existing.documentId, currentUserId, tx) : null,
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
  tx: Transaction,
): Promise<BlockContent | undefined> => {
  if (!blockContent) return undefined
  const clonedPhotos = new Map<bigint, Photo>()
  for (const sourcePhotoId of collectReadyBlockPhotoIds(blockContent)) {
    const clonedPhotoId = await FileModel.clonePhotoById(Number(sourcePhotoId), currentUserId, tx)
    const clonedPhoto = await FileModel.getPhotoById(BigInt(clonedPhotoId), tx)
    if (!clonedPhoto) throw RealtimeRpcError.InternalError()
    clonedPhotos.set(sourcePhotoId, encodePhoto({ photo: clonedPhoto }))
  }
  return snapshotForwardedBlockContent(
    projectReadyBlockPhotos(blockContent, clonedPhotos),
  )
}

export const snapshotForwardedBlockContent = (content: BlockContent): BlockContent => {
  const snapshot = BlockContent.fromBinary(BlockContent.toBinary(content))
  const image = (value: BlockImage): void => {
    if (value.state.oneofKind !== "pending") return
    value.state = {
      oneofKind: "unavailable",
      unavailable: { dimensions: value.state.pending.dimensions },
    }
  }
  const blocks = (values: Block[]): void => {
    for (const block of values) {
      switch (block.kind.oneofKind) {
        case "image": image(block.kind.image); break
        case "album": block.kind.album.images.forEach(image); break
        case "disclosure": blocks(block.kind.disclosure.children); break
        case "quote": blocks(block.kind.quote.children); break
        case "list": block.kind.list.items.forEach((item) => blocks(item.children)); break
      }
    }
  }
  blocks(snapshot.blocks)
  return snapshot
}

const newRandomId = (): bigint => {
  let value = 0n
  while (value === 0n) value = randomBytes(8).readBigInt64LE()
  return value
}

const intentHash = (input: {
  sourceChatId: number
  destinationChatId: number
  shareForwardHeader: boolean
  messageIds: bigint[]
  submissions: ForwardMessageSubmission[]
  index: number
}): Buffer => createHash("sha256").update(JSON.stringify({
  version: 1,
  sourceChatId: input.sourceChatId,
  destinationChatId: input.destinationChatId,
  shareForwardHeader: input.shareForwardHeader,
  items: input.messageIds.map((messageId, index) => ({
    messageId: messageId.toString(),
    randomId: input.submissions[index]!.randomId.toString(),
    sourceRevision: input.submissions[index]!.expectedSourceRevision.toString(),
    sourceSnapshot: input.submissions[index]!.expectedSourceSnapshot ?? null,
  })),
  index: input.index,
})).digest()

/** Cards become ordinary historical text/links. Source callbacks, provider
 * actions, structural child relations and source/child permissions stay put. */
export const projectForwardedVisibleContext = (
  source: Message,
  blockContent: BlockContent | undefined,
  includeSourceLink = false,
): { text: string | undefined; entities: MessageEntities | undefined; blockContent: BlockContent | undefined } => {
  let text = source.message ?? ""
  const projectedEntities = MessageEntities.create(source.entities ?? {})
  const append = (value: string, entity?: MessageEntities["entities"][number]): void => {
    if (!value) return
    if (text) text += "\n\n"
    const offset = BigInt(text.length)
    const length = BigInt(value.length)
    text += value
    if (entity) projectedEntities.entities.push({ ...entity, offset, length })
    blockContent?.blocks.push({ kind: { oneofKind: "paragraph", paragraph: { offset, length } } })
  }
  if (source.media?.media.oneofKind === "nudge") append("👋 Nudge")
  for (const attachment of source.attachments?.attachments ?? []) {
    if (attachment.attachment.oneofKind !== "externalTask") continue
    const task = attachment.attachment.externalTask
    const status = ["", "Backlog", "To do", "In progress", "Done", "Cancelled"][task.status] ?? ""
    append([task.application, task.number, task.title || task.taskId].filter(Boolean).join(" · "))
    if (status) append(`Status: ${status}`)
    if (task.assignedUserId > 0n) append(`Assignee: inline://user/${task.assignedUserId}`)
    if (task.url) append(task.url, {
      type: MessageEntity_Type.URL, offset: 0n, length: 0n, entity: { oneofKind: undefined },
    })
  }
  for (const row of source.actions?.rows ?? []) append(row.actions.map((action) => action.text).filter(Boolean).join(" · "))
  if (source.replyToMsgId !== undefined) append(`Reply: inline://chat/${source.chatId}?message_id=${source.replyToMsgId}`, {
    type: MessageEntity_Type.TEXT_URL, offset: 0n, length: 0n,
    entity: { oneofKind: "textUrl", textUrl: { url: `inline://chat/${source.chatId}?message_id=${source.replyToMsgId}` } },
  })
  const childChatId = source.subthread?.chatId ?? source.replies?.chatId
  if (childChatId !== undefined) {
    if (source.subthread?.title) append(source.subthread.title)
    append(`inline://chat/${childChatId}`, {
      type: MessageEntity_Type.THREAD, offset: 0n, length: 0n,
      entity: { oneofKind: "thread", thread: { chatId: childChatId } },
    })
  }
  if (includeSourceLink) append(`Source: inline://chat/${source.chatId}?message_id=${source.id}`, {
    type: MessageEntity_Type.TEXT_URL, offset: 0n, length: 0n,
    entity: { oneofKind: "textUrl", textUrl: { url: `inline://chat/${source.chatId}?message_id=${source.id}` } },
  })
  return { text: text || undefined, entities: projectedEntities.entities.length ? projectedEntities : undefined, blockContent }
}

export const forwardMessages = async (input: Input, context: FunctionContext): Promise<Output> => {
  if (!input.fromPeerId || !input.toPeerId) throw RealtimeRpcError.PeerIdInvalid()
  if (input.messageIds.length === 0 || input.messageIds.length > 100) throw RealtimeRpcError.BadRequest()
  if (input.messageIds.some((id) => id <= 0n || id > BigInt(Number.MAX_SAFE_INTEGER))) {
    throw RealtimeRpcError.MessageIdInvalid()
  }
  const stableSubmissions = input.submissions && input.submissions.length > 0 ? input.submissions : undefined
  if (stableSubmissions && (
    stableSubmissions.length !== input.messageIds.length ||
    new Set(stableSubmissions.map((item) => item.randomId.toString())).size !== stableSubmissions.length ||
    stableSubmissions.some((item) => item.randomId === 0n || item.randomId < -(1n << 63n) ||
      item.randomId >= (1n << 63n) || item.expectedSourceRevision < 0n || item.expectedSourceRevision > 2_147_483_647n ||
      (item.expectedSourceSnapshot !== undefined && !/^[a-f0-9]{64}$/.test(item.expectedSourceSnapshot)))
  )) throw RealtimeRpcError.BadRequest()

  const currentUserId = context.currentUserId
  const shareForwardHeader = input.shareForwardHeader !== false
  const sourceChat = await ChatModel.getChatFromInputPeer(input.fromPeerId, context)
  const destinationChat = await ChatModel.getChatFromInputPeer(input.toPeerId, context)
  await AccessGuards.ensureChatAccess(sourceChat, currentUserId)
  await AccessGuards.ensureChatAccess(destinationChat, currentUserId)

  const normalizedFromPeer = normalizeForwardPeer(input.fromPeerId, currentUserId)
  // Legacy callers still forward, but only a caller-persisted request is safe to
  // resubmit after an ambiguous response.
  const submissions: ForwardMessageSubmission[] = stableSubmissions ?? input.messageIds.map(() => ({ randomId: newRandomId(), expectedSourceRevision: 0n }))
  const updates: Update[] = []
  const messageIds: number[] = []
  const receipts: ForwardMessageReceipt[] = []

  for (const [index, messageId] of input.messageIds.entries()) {
    const submission = submissions[index]!
    const hash = intentHash({
      sourceChatId: sourceChat.id,
      destinationChatId: destinationChat.id,
      shareForwardHeader,
      messageIds: input.messageIds,
      submissions,
      index,
    })
    let deliver: (() => Promise<{ updates: Update[] }>) | undefined
    const committed = await db.transaction(async (tx) => {
      // Serialize sender-scoped identities before doing any clone work. The
      // unique random_id constraint remains the fence against ordinary sends.
      await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`${currentUserId}:${submission.randomId}`}, 0))`)
      // Existing message writers lock their chat before the message. Lock both
      // chats in one order so opposite-direction forwards cannot deadlock edits.
      const chatIds = new Set([sourceChat.id, destinationChat.id])
      let ancestors = [...chatIds]
      while (ancestors.length) {
        const rows = await tx.select({ parentId: chats.parentChatId }).from(chats).where(inArray(chats.id, ancestors))
        ancestors = rows.flatMap(({ parentId }) => parentId !== null && !chatIds.has(parentId) ? [parentId] : [])
        ancestors.forEach((id) => chatIds.add(id))
      }
      const lockedChats = await tx.select().from(chats)
        .where(inArray(chats.id, [...chatIds])).orderBy(asc(chats.id)).for("update")
      const currentSource = lockedChats.find((chat) => chat.id === sourceChat.id)
      const currentDestination = lockedChats.find((chat) => chat.id === destinationChat.id)
      if (!currentSource || !currentDestination) throw RealtimeRpcError.PeerIdInvalid()
      // Preflight may have run before removal won a chat/root lock. Both new
      // sends and receipt replay require current route access under these locks;
      // replay does not require the source message to still exist or be current.
      await AccessGuards.ensureChatAccess(currentSource, currentUserId, tx)
      await AccessGuards.ensureChatAccess(currentDestination, currentUserId, tx)
      const [receipt] = await tx.select().from(messageSubmissions).where(and(
        eq(messageSubmissions.fromId, currentUserId), eq(messageSubmissions.randomId, submission.randomId),
      )).limit(1)
      if (receipt) {
        if (receipt.chatId !== destinationChat.id || receipt.sourceRevision === null ||
          !Encryption2.decryptBinary(receipt.intentHash).equals(hash)) throw RealtimeRpcError.BadRequest()
        const [existing] = await tx.select({ hash: messages.forwardIntentHash }).from(messages).where(and(
          eq(messages.chatId, receipt.chatId), eq(messages.messageId, receipt.messageId),
          eq(messages.fromId, currentUserId), eq(messages.randomId, submission.randomId),
        )).limit(1)
        return {
          messageId: receipt.messageId, sourceRevision: BigInt(receipt.sourceRevision),
          messageDeleted: !existing?.hash || !Buffer.from(existing.hash).equals(hash),
          updates: [{ update: { oneofKind: "updateMessageId" as const, updateMessageId: {
            messageId: BigInt(receipt.messageId), randomId: submission.randomId,
          } } }],
        }
      }
      // Pre-ledger ordinary messages still reserve their random ID.
      const [collision] = await tx.select({ id: messages.globalId }).from(messages).where(and(
        eq(messages.fromId, currentUserId), eq(messages.randomId, submission.randomId),
      )).limit(1)
      if (collision) throw RealtimeRpcError.BadRequest()

      const [lockedSource] = await tx.select({ revision: messages.rev, globalId: messages.globalId, blockContentId: messages.blockContentId }).from(messages)
        .where(and(eq(messages.chatId, sourceChat.id), eq(messages.messageId, Number(messageId))))
        .for("share").limit(1)
      if (!lockedSource) throw RealtimeRpcError.MessageIdInvalid()
      if (stableSubmissions && BigInt(lockedSource.revision) !== submission.expectedSourceRevision) {
        throw RealtimeRpcError.BadRequest()
      }
      const sourceAttachments = await tx.select().from(messageAttachments)
        .where(eq(messageAttachments.messageId, lockedSource.globalId)).orderBy(asc(messageAttachments.id)).for("share")
      const previewIds = sourceAttachments.flatMap((attachment) => attachment.urlPreviewId ? [Number(attachment.urlPreviewId)] : [])
      const taskIds = sourceAttachments.flatMap((attachment) => attachment.externalTaskId ? [Number(attachment.externalTaskId)] : [])
      if (previewIds.length) await tx.select({ id: urlPreview.id }).from(urlPreview).where(inArray(urlPreview.id, previewIds)).orderBy(asc(urlPreview.id)).for("share")
      if (taskIds.length) await tx.select({ id: externalTasks.id }).from(externalTasks).where(inArray(externalTasks.id, taskIds)).orderBy(asc(externalTasks.id)).for("share")
      if (lockedSource.blockContentId) await tx.select({ id: blockContents.id }).from(blockContents)
        .where(eq(blockContents.id, lockedSource.blockContentId)).for("share")
      const sourceMessage = await MessageModel.getMessage(Number(messageId), sourceChat.id, tx)
      const threadProjection = (await getMessageThreadProjectionsMap({
        parentChatId: sourceChat.id, parentMessageIds: [Number(messageId)], userId: currentUserId, tx,
      })).get(Number(messageId))
      const sourcePayload = encodeFullMessage({ message: sourceMessage, encodingForUserId: currentUserId,
        encodingForPeer: { inputPeer: input.fromPeerId }, ...threadProjection })
      if (submission.expectedSourceSnapshot !== undefined && sourcePayload.sourceSnapshot !== submission.expectedSourceSnapshot) {
        throw RealtimeRpcError.BadRequest()
      }

      let forwardHeader: { fromPeerId: InputPeer; fromId: number; fromMessageId: number } | undefined
      if (shareForwardHeader) {
        if (sourceMessage.fwdFromMessageId && sourceMessage.fwdFromSenderId) {
          const forwardedPeer = buildForwardPeerFromMessage(sourceMessage)
          if (forwardedPeer) forwardHeader = {
            fromPeerId: forwardedPeer, fromId: sourceMessage.fwdFromSenderId, fromMessageId: sourceMessage.fwdFromMessageId,
          }
        }
        const isSelfDmMessage = sourceChat.type === "private" && sourceChat.minUserId != null &&
          sourceChat.maxUserId != null && sourceChat.minUserId !== sourceChat.maxUserId && sourceMessage.fromId === currentUserId
        if (!forwardHeader && !isSelfDmMessage) forwardHeader = {
          fromPeerId: normalizedFromPeer, fromId: sourceMessage.fromId, fromMessageId: sourceMessage.messageId,
        }
      }

      const attachments: { urlPreviewId: bigint }[] = []
      for (const attachment of sourceMessage.messageAttachments ?? []) {
        if (!attachment.urlPreviewId) continue
        const previewId = await cloneUrlPreviewById(attachment.urlPreviewId, currentUserId, tx)
        if (previewId === null) throw RealtimeRpcError.InternalError()
        attachments.push({ urlPreviewId: BigInt(previewId) })
      }
      const photoId = sourceMessage.photoId ? BigInt(await FileModel.clonePhotoById(sourceMessage.photoId, currentUserId, tx)) : undefined
      const videoId = sourceMessage.videoId ? BigInt(await FileModel.cloneVideoById(sourceMessage.videoId, currentUserId, tx)) : undefined
      const documentId = sourceMessage.documentId ? BigInt(await FileModel.cloneDocumentById(sourceMessage.documentId, currentUserId, tx)) : undefined
      const voiceId = sourceMessage.voiceId ? BigInt(await FileModel.cloneVoiceById(sourceMessage.voiceId, currentUserId, tx)) : undefined
      const blockContent = await cloneForwardedBlockContent(sourceMessage.blockContent, currentUserId, tx)
      const projection = projectForwardedVisibleContext(sourcePayload, blockContent, !shareForwardHeader)
      const result = await sendMessage({
        peerId: input.toPeerId,
        message: projection.text,
        entities: projection.entities,
        photoId, videoId, documentId, voiceId,
        isSticker: sourceMessage.isSticker ?? false,
        randomId: submission.randomId,
        forwardIntentHash: hash,
        forwardSourceRevision: sourceMessage.rev,
        forwardHeader,
        messageAttachments: attachments.length > 0 ? attachments : undefined,
        blockContent: projection.blockContent,
        skipLinkProcessing: true,
      }, context, { transaction: tx, onCommitted: (complete) => { deliver = complete } })
      const sent = result.updates.find((candidate) => candidate.update.oneofKind === "updateMessageId")?.update
      if (sent?.oneofKind !== "updateMessageId") throw RealtimeRpcError.InternalError()
      return { messageId: Number(sent.updateMessageId.messageId), sourceRevision: BigInt(sourceMessage.rev), messageDeleted: false, updates: result.updates }
    })
    const result = deliver ? await deliver() : { updates: committed.updates }
    updates.push(...result.updates)
    messageIds.push(committed.messageId)
    receipts.push({
      sourceMessageId: messageId, randomId: submission.randomId,
      messageId: BigInt(committed.messageId), sourceRevision: committed.sourceRevision, messageDeleted: committed.messageDeleted,
    })
  }
  return { updates, messageIds, receipts }
}
