import { getSignedUrl } from "@in/server/modules/files/path"
import { Document, InputPeer, MessageAttachment, Peer, Update, UpdateMessageAttachment } from "@in/protocol/core"
import type { DbFullDocument } from "@in/server/db/models/files"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { TPeerInfo } from "@in/server/api-types"
import { encodePeerFromInputPeer } from "./encodePeer"
import type { DbMessageAttachment } from "@in/server/db/schema"

export const encodeMessageAttachmentUpdate = ({
  messageId,
  chatId,
  encodingForUserId,
  encodingForPeer,
  attachment,
}: {
  messageId: bigint
  chatId: bigint
  encodingForUserId: number
  encodingForPeer: { inputPeer: InputPeer }
  attachment: MessageAttachment
}): Update => {
  let update: Update = {
    update: {
      oneofKind: "messageAttachment",
      messageAttachment: {
        messageId,
        chatId,
        peerId: encodePeerFromInputPeer({
          inputPeer: encodingForPeer.inputPeer,
          currentUserId: encodingForUserId,
        }),
        attachment,
      },
    },
  }

  return update
}
