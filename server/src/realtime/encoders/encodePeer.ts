import type { TPeerInfo } from "@in/server/api-types"
import type { InputPeer, Peer } from "@in/protocol/core"

export const encodePeer = (peer: TPeerInfo): Peer => {
  if ("userId" in peer) {
    return {
      type: { oneofKind: "user", user: { userId: BigInt(peer.userId) } },
    }
  }

  return {
    type: { oneofKind: "chat", chat: { chatId: BigInt(peer.threadId) } },
  }
}

export const encodePeerFromInputPeer = ({
  inputPeer,
  currentUserId,
}: {
  inputPeer: InputPeer
  currentUserId: number
}): Peer => {
  if (inputPeer.type.oneofKind === "user") {
    return { type: { oneofKind: "user", user: { userId: BigInt(inputPeer.type.user.userId) } } }
  }

  if (inputPeer.type.oneofKind === "chat") {
    return { type: { oneofKind: "chat", chat: { chatId: BigInt(inputPeer.type.chat.chatId) } } }
  }

  if (inputPeer.type.oneofKind === "self") {
    return { type: { oneofKind: "user", user: { userId: BigInt(currentUserId) } } }
  }

  throw new Error("Unsupported input peer")
}
