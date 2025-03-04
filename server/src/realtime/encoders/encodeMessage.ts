import type { TPeerInfo } from "@in/server/api-types"
import type { DbFile, DbMessage } from "@in/server/db/schema"
import { decryptMessage } from "@in/server/modules/encryption/encryptMessage"
import type { InputPeer, Message, MessageMedia, Peer } from "@in/protocol/core"
import { encodePeer, encodePeerFromInputPeer } from "@in/server/realtime/encoders/encodePeer"
import { encodePhoto, encodePhotoLegacy } from "@in/server/realtime/encoders/encodePhoto"
import type { DbFullDocument, DbFullPhoto, DbFullVideo } from "@in/server/db/models/files"
import { encodeVideo } from "@in/server/realtime/encoders/encodeVideo"
import { encodeDocument } from "@in/server/realtime/encoders/encodeDocument"
import type { DbFullMessage } from "@in/server/db/models/messages"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"

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
  }

  return messageProto
}
