import { encodeFullMessage, encodeMessage } from "@in/server/realtime/encoders/encodeMessage"
import { encodePhotoLegacy } from "@in/server/realtime/encoders/encodePhoto"
import { encodePeer, encodePeerFromInputPeer } from "@in/server/realtime/encoders/encodePeer"
import { encodeUser } from "@in/server/realtime/encoders/encodeUser"
import { encodeChat } from "@in/server/realtime/encoders/encodeChat"

export const Encoders = {
  photoLegacy: encodePhotoLegacy,
  message: encodeMessage,
  fullMessage: encodeFullMessage,
  peer: encodePeer,
  peerFromInputPeer: encodePeerFromInputPeer,
  user: encodeUser,
  chat: encodeChat,
}
