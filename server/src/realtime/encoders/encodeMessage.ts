import type { TPeerInfo } from "@in/server/api-types"
import type { DbFile, DbMessage } from "@in/server/db/schema"
import { decryptMessage } from "@in/server/modules/encryption/encryptMessage"
import type { InputPeer, Message, MessageMedia, MessageAttachment, MessageAttachments, Peer } from "@in/protocol/core"
import { encodePeer, encodePeerFromInputPeer } from "@in/server/realtime/encoders/encodePeer"
import { encodePhoto, encodePhotoLegacy } from "@in/server/realtime/encoders/encodePhoto"
import type { DbFullDocument, DbFullPhoto, DbFullVideo } from "@in/server/db/models/files"
import { encodeVideo } from "@in/server/realtime/encoders/encodeVideo"
import { encodeDocument } from "@in/server/realtime/encoders/encodeDocument"
import type { DbFullMessage } from "@in/server/db/models/messages"
import { encodeDate, encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { encodeReaction } from "@in/server/realtime/encoders/encodeReaction"

export const encodeMessage = ({
  message,
  file,
  photo,
  video,
  document,
  encodingForUserId,
  encodingForPeer,
}: {
  message: DbMessage
  encodingForUserId: number
  encodingForPeer: { legacyPeer: TPeerInfo } | { peer: Peer } | { inputPeer: InputPeer }
  file?: DbFile | undefined
  photo?: DbFullPhoto | undefined
  video?: DbFullVideo | undefined
  document?: DbFullDocument | undefined
}): Message => {
  // Decrypt
  let text = message.text ? message.text : undefined
  if (message.textEncrypted && message.textIv && message.textTag) {
    const decryptedText = decryptMessage({
      encrypted: message.textEncrypted,
      iv: message.textIv,
      authTag: message.textTag,
    })
    text = decryptedText
  }

  let peerId: Peer

  if ("legacyPeer" in encodingForPeer) {
    peerId = encodePeer(encodingForPeer.legacyPeer)
  } else if ("peer" in encodingForPeer) {
    peerId = encodingForPeer.peer
  } else {
    peerId = encodePeerFromInputPeer({
      inputPeer: encodingForPeer.inputPeer,
      currentUserId: encodingForUserId,
    })
  }

  let media: MessageMedia | undefined = undefined

  if (file) {
    media = {
      media: {
        oneofKind: "photo",
        photo: {
          photo: encodePhotoLegacy({ file }),
        },
      },
    }
  } else if (photo) {
    media = {
      media: {
        oneofKind: "photo",
        photo: { photo: encodePhoto({ photo }) },
      },
    }
  } else if (video) {
    media = {
      media: {
        oneofKind: "video",
        video: { video: encodeVideo({ video }) },
      },
    }
  } else if (document) {
    media = {
      media: {
        oneofKind: "document",
        document: { document: encodeDocument({ document }) },
      },
    }
  }
  let messageProto: Message = {
    id: BigInt(message.messageId),
    fromId: BigInt(message.fromId),
    peerId: peerId,
    chatId: BigInt(message.chatId),
    message: text,
    out: encodingForUserId === message.fromId,
    date: encodeDateStrict(message.date),
    mentioned: false,
    replyToMsgId: message.replyToMsgId ? BigInt(message.replyToMsgId) : undefined,
    media: media,
    isSticker: message.isSticker ?? false,
  }

  return messageProto
}

export const encodeFullMessage = ({
  message,
  encodingForUserId,
  encodingForPeer,
}: {
  message: DbFullMessage
  encodingForUserId: number
  encodingForPeer: { peer: Peer } | { inputPeer: InputPeer }
}): Message => {
  let peerId: Peer

  if ("peer" in encodingForPeer) {
    peerId = encodingForPeer.peer
  } else {
    peerId = encodePeerFromInputPeer({
      inputPeer: encodingForPeer.inputPeer,
      currentUserId: encodingForUserId,
    })
  }

  let media: MessageMedia | undefined = undefined

  if (message.photo) {
    media = {
      media: {
        oneofKind: "photo",
        photo: {
          photo: encodePhoto({ photo: message.photo }),
        },
      },
    }
  } else if (message.video) {
    media = {
      media: {
        oneofKind: "video",
        video: { video: encodeVideo({ video: message.video }) },
      },
    }
  } else if (message.document) {
    media = {
      media: {
        oneofKind: "document",
        document: { document: encodeDocument({ document: message.document }) },
      },
    }
  }

  // Process attachments if they exist
  let attachments: MessageAttachments | undefined = undefined
  if (message.messageAttachments && message.messageAttachments.length > 0) {
    const statusMap: Record<string, number> = {
      backlog: 1,
      todo: 2,
      in_progress: 3,
      done: 4,
      cancelled: 5,
    }
    const encodedAttachments = message.messageAttachments.map((attachment) => {
      let messageAttachment: MessageAttachment = {
        id: BigInt(attachment.id ?? 0),
        attachment: { oneofKind: undefined },
      }

      // Handle external task attachment
      if (attachment.externalTask) {
        messageAttachment.attachment = {
          oneofKind: "externalTask",
          externalTask: {
            id: BigInt(attachment.externalTask.id),
            taskId: attachment.externalTask.taskId ?? "",
            application: attachment.externalTask.application ?? "",
            title: attachment.externalTask.title ?? "",
            status: statusMap[attachment.externalTask.status ?? ""] ?? 0,
            assignedUserId: BigInt(attachment.externalTask.assignedUserId ?? 0),
            url: attachment.externalTask.url ?? "",
            number: attachment.externalTask.number ?? "",
            date: encodeDateStrict(attachment.externalTask.date),
          },
        }
      }
      // Handle URL preview attachment
      else if (attachment.linkEmbed) {
        messageAttachment.attachment = {
          oneofKind: "urlPreview",
          urlPreview: {
            id: BigInt(attachment.linkEmbed.id),
            url: attachment.linkEmbed.url ?? undefined,
            siteName: attachment.linkEmbed.siteName ?? undefined,
            title: attachment.linkEmbed.title ?? undefined,
            description: attachment.linkEmbed.description ?? undefined,
            photo: attachment.linkEmbed.photo ? encodePhoto({ photo: attachment.linkEmbed.photo }) : undefined,
            duration: encodeDateStrict(attachment.linkEmbed.date),
          },
        }
      }

      return messageAttachment
    })

    attachments = {
      attachments: encodedAttachments.filter((a) => a.attachment && a.attachment.oneofKind !== undefined),
    }
  }

  const hasReactions = message.reactions.length > 0

  let messageProto: Message = {
    id: BigInt(message.messageId),
    fromId: BigInt(message.fromId),
    peerId: peerId,
    chatId: BigInt(message.chatId),
    message: message.text ?? undefined,
    out: encodingForUserId === message.fromId,
    date: encodeDateStrict(message.date),
    mentioned: false,
    replyToMsgId: message.replyToMsgId ? BigInt(message.replyToMsgId) : undefined,
    media: media,
    isSticker: message.isSticker ?? false,
    attachments: attachments,
    reactions: hasReactions
      ? {
          reactions: message.reactions.map((reaction) => encodeReaction({ reaction })),
        }
      : undefined,
  }

  return messageProto
}
