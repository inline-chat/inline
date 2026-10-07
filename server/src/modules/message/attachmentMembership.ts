import {
  chats,
  messages,
  messageAttachments,
  threadGraphLinks,
  type DbMessage,
  type DbChat,
} from "@in/server/db/schema"
import { UpdatesModel, type UpdateSeqAndDate } from "@in/server/db/models/updates"
import { UpdateBucket } from "@in/server/db/schema/updates"
import type { Transaction } from "@in/server/db/types"
import { registerPostCommitHook } from "@in/server/db/commitHooks"
import { queueMessageThreadLinkMaterialization } from "@in/server/modules/threadGraph"
import { MessageEntity_Type, MessageEntities } from "@inline-chat/protocol/core"
import { decryptBinary } from "@in/server/modules/encryption/encryption"
import { detectHasLink } from "@in/server/modules/message/linkDetection"
import { and, eq, isNull, sql } from "drizzle-orm"

/** Caller holds the chat lock. Attachment mutations share message revision and link classification. */
export async function refreshAttachmentMembership(tx: Transaction, message: DbMessage): Promise<void> {
  const entities =
    message.entitiesEncrypted && message.entitiesIv && message.entitiesTag
      ? MessageEntities.fromBinary(
          decryptBinary({
            encrypted: message.entitiesEncrypted,
            iv: message.entitiesIv,
            authTag: message.entitiesTag,
          }),
        )
      : undefined
  const [preview] = await tx
    .select({ id: messageAttachments.id })
    .from(messageAttachments)
    .where(and(eq(messageAttachments.messageId, message.globalId), sql`${messageAttachments.urlPreviewId} IS NOT NULL`))
    .limit(1)
  const [updated] = await tx
    .update(messages)
    .set({
      hasLink: detectHasLink({ entities }) || preview !== undefined,
      rev: sql`${messages.rev} + 1`,
    })
    .where(eq(messages.globalId, message.globalId))
    .returning({ rev: messages.rev })
  if (!updated) throw new Error("Attachment parent disappeared")
  await preserveMessageGraphRevision(tx, message, updated.rev, entities)
}

/** Preserve unchanged text-backed links when a presentation-only revision advances. */
export async function preserveMessageGraphRevision(
  tx: Transaction,
  message: DbMessage,
  nextRevision: number,
  entities?: MessageEntities,
): Promise<void> {
  await tx
    .update(threadGraphLinks)
    .set({ fromMessageRevision: nextRevision, updatedAt: new Date() })
    .where(
      and(
        eq(threadGraphLinks.kind, "thread_link"),
        eq(threadGraphLinks.fromMessageGlobalId, message.globalId),
        eq(threadGraphLinks.fromMessageRevision, nextRevision - 1),
        isNull(threadGraphLinks.deletedAt),
      ),
    )
  const resolvedEntities =
    entities ??
    (message.entitiesEncrypted && message.entitiesIv && message.entitiesTag
      ? MessageEntities.fromBinary(
          decryptBinary({
            encrypted: message.entitiesEncrypted,
            iv: message.entitiesIv,
            authTag: message.entitiesTag,
          }),
        )
      : undefined)
  if (!resolvedEntities?.entities.some((entity) => entity.type === MessageEntity_Type.THREAD)) return
  // The initial materializer may not have inserted a row yet. Requeue only after
  // commit so its revision fence sees the current presentation snapshot.
  registerPostCommitHook(tx, Symbol("message-graph-revision"), {
    run: async () => {
      queueMessageThreadLinkMaterialization({
        sourceChatId: message.chatId,
        sourceMessageGlobalId: message.globalId,
        sourceMessageId: message.messageId,
        sourceMessageFromId: message.fromId,
        sourceMessageRevision: nextRevision,
        entities: resolvedEntities,
      })
    },
  })
}

/** Lock before inserting/deleting the attachment to preserve chat -> message lock order. */
export async function lockAttachmentChat(tx: Transaction, chatId: number) {
  const [chat] = await tx.select().from(chats).where(eq(chats.id, chatId)).for("update").limit(1)
  if (!chat) throw new Error("Attachment chat disappeared")
  return chat
}

export async function persistAttachmentMutation(
  tx: Transaction,
  chat: DbChat,
  messageGlobalId: bigint,
  attachmentId: number,
): Promise<UpdateSeqAndDate> {
  const [message] = await tx
    .select()
    .from(messages)
    .where(and(eq(messages.globalId, messageGlobalId), eq(messages.chatId, chat.id)))
    .limit(1)
  if (!message) throw new Error("Attachment parent disappeared")
  await refreshAttachmentMembership(tx, message)
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
    entity: chat,
  })
  await tx.update(chats).set({ updateSeq: update.seq, lastUpdateDate: update.date }).where(eq(chats.id, chat.id))
  return update
}
