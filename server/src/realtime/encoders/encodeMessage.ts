import type { TPeerInfo } from "@in/server/api-types"
import type { DbFile, DbMessage } from "@in/server/db/schema"
import { decryptMessage } from "@in/server/modules/encryption/encryptMessage"
import type { Message } from "@in/server/protocol/core"
import { encodePeer } from "@in/server/realtime/encoders/encodePeer"
import { encodePhoto } from "@in/server/realtime/encoders/encodePhoto"

export const encodeMessage = ({
  message,
  file,
  encodingForUserId,
  encodingForPeer,
}: {
  message: DbMessage
  file: DbFile | undefined
  encodingForUserId: number
  encodingForPeer: TPeerInfo
}) => {
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

  let messageProto: Message = {
    id: BigInt(message.messageId),
    fromId: BigInt(message.fromId),
    peerId: encodePeer(encodingForPeer),
    chatId: BigInt(message.chatId),
    message: text,
    out: encodingForUserId === message.fromId,
    date: BigInt(Math.round(message.date.getTime() / 1000)),
    mentioned: false,
    replyToMsgId: message.replyToMsgId ? BigInt(message.replyToMsgId) : undefined,
    media: file
      ? {
          media: {
            oneofKind: "photo",
            photo: {
              photo: encodePhoto({ file }),
            },
          },
        }
      : undefined,
  }

  return messageProto
}
