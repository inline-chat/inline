import { encodeFullMessage, encodeMessage } from "@in/server/realtime/encoders/encodeMessage"
import { encodePhoto, encodePhotoLegacy } from "@in/server/realtime/encoders/encodePhoto"
import { encodePeer, encodePeerFromInputPeer } from "@in/server/realtime/encoders/encodePeer"
import { encodeUser } from "@in/server/realtime/encoders/encodeUser"
import { encodeChat } from "@in/server/realtime/encoders/encodeChat"
import { encodeMember } from "@in/server/realtime/encoders/encodeMember"
import { encodeSpace } from "@in/server/realtime/encoders/encodeSpace"
import { encodeDialog } from "@in/server/realtime/encoders/encodeDialog"
import { encodeTranslation, encodeUnencryptedTranslation } from "@in/server/realtime/encoders/encodeTranslation"
export const Encoders = {
  photoLegacy: encodePhotoLegacy,
  message: encodeMessage,
  fullMessage: encodeFullMessage,
  peer: encodePeer,
  peerFromInputPeer: encodePeerFromInputPeer,
  user: encodeUser,
  chat: encodeChat,
  photo: encodePhoto,
  member: encodeMember,
  space: encodeSpace,
  dialog: encodeDialog,
  translation: encodeTranslation,
  unencryptedTranslation: encodeUnencryptedTranslation,
}
