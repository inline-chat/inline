import { encodeMessage } from "@in/server/realtime/encoders/encodeMessage"
import { encodePhoto } from "@in/server/realtime/encoders/encodePhoto"
import { encodePeer, encodePeerFromInputPeer } from "@in/server/realtime/encoders/encodePeer"
import { encodeUser } from "@in/server/realtime/encoders/encodeUser"
export const Encoders = {
  photo: encodePhoto,
  message: encodeMessage,
  peer: encodePeer,
  peerFromInputPeer: encodePeerFromInputPeer,
  user: encodeUser,
}
