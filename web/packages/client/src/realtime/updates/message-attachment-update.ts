import {
  Update,
  type MessageAttachment,
} from "@inline-chat/protocol/core"
import {
  parseInlineId,
  type ChatID,
  type MessageID,
} from "@inline/ids"
import type { Db } from "../../database"
import {
  DbObjectKind,
  messageKey,
} from "../../database/models"

export type ResidentMessageAttachmentUpdateDisposition =
  | "applied"
  | "missingMessage"
  | "invalid"
  | "unsupported"

const exactAttachmentTarget = (update: Update) => {
  if (update.update.oneofKind !== "messageAttachment") return undefined
  const payload = update.update.messageAttachment
  const chatId = parseInlineId<"chat">(payload.chatId, {
    positive: true,
  })
  const messageId = parseInlineId<"message">(payload.messageId, {
    positive: true,
  })
  return chatId && messageId
    ? {
        chatId: chatId as ChatID,
        messageId: messageId as MessageID,
      }
    : undefined
}

export const messageAttachmentUpdateTargetKey = (
  update: Update,
): string | undefined => {
  const target = exactAttachmentTarget(update)
  return target
    ? messageKey(target.chatId, target.messageId)
    : undefined
}

const validAttachmentId = (value: bigint) => value > 0n

const innerIdentity = (attachment: MessageAttachment) => {
  switch (attachment.attachment.oneofKind) {
    case "externalTask":
      return attachment.attachment.externalTask.id > 0n
        ? `externalTask:${attachment.attachment.externalTask.id}`
        : undefined
    case "urlPreview":
      return attachment.attachment.urlPreview.id > 0n
        ? `urlPreview:${attachment.attachment.urlPreview.id}`
        : undefined
    case undefined:
      return undefined
  }
}

const matchesAttachment = (
  existing: MessageAttachment,
  incoming: MessageAttachment,
) => {
  if (existing.id === incoming.id) return true
  const incomingInnerIdentity = innerIdentity(incoming)
  return (
    incomingInnerIdentity != null &&
    innerIdentity(existing) === incomingInnerIdentity
  )
}

/**
 * Apple stores attachments as related rows. The lean web cache keeps the same
 * protocol objects inside its Message aggregate, so this recipe mirrors
 * save/delete/dedupe semantics while replacing only that aggregate field.
 */
export const applyResidentMessageAttachmentUpdate = (
  db: Db,
  update: Update,
): ResidentMessageAttachmentUpdateDisposition => {
  if (update.update.oneofKind !== "messageAttachment") {
    return "unsupported"
  }
  const target = exactAttachmentTarget(update)
  const incoming = update.update.messageAttachment.attachment
  if (!target || !incoming || !validAttachmentId(incoming.id)) {
    return "invalid"
  }
  const ref = db.ref(
    DbObjectKind.Message,
    messageKey(target.chatId, target.messageId),
  )
  const message = db.get(ref)
  if (!message) return "missingMessage"

  const attachments = message.attachments?.attachments ?? []
  if (incoming.attachment.oneofKind === undefined) {
    const hasStableId = attachments.some(
      (existing) => existing.id === incoming.id,
    )
    const remaining = attachments.filter((existing) =>
      hasStableId
        ? existing.id !== incoming.id
        : !(
            // InlineKit uses this repair path only when no stable attachment
            // ID matches the deletion update.
            existing.attachment.oneofKind === "externalTask" &&
            existing.attachment.externalTask.id === incoming.id
          ),
    )
    if (remaining.length === attachments.length) return "applied"
    db.replace({
      ...message,
      attachments:
        remaining.length > 0
          ? { attachments: remaining }
          : undefined,
    })
    return "applied"
  }

  const firstMatch = attachments.findIndex((existing) =>
    matchesAttachment(existing, incoming),
  )
  if (firstMatch < 0) {
    db.replace({
      ...message,
      attachments: {
        attachments: [...attachments, incoming],
      },
    })
    return "applied"
  }
  db.replace({
    ...message,
    attachments: {
      attachments: attachments.flatMap((existing, index) => {
        if (index === firstMatch) return [incoming]
        return matchesAttachment(existing, incoming) ? [] : [existing]
      }),
    },
  })
  return "applied"
}
