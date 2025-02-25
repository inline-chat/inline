import { encodeMessage } from "@in/server/realtime/encoders/encodeMessage"
import { encodePhoto } from "@in/server/realtime/encoders/encodePhoto"
import { encodePeer } from "@in/server/realtime/encoders/encodePeer"
export const Encoders = {
  photo: encodePhoto,
  message: encodeMessage,
  peer: encodePeer,
}
