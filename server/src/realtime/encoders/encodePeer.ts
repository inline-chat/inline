import type { TPeerInfo } from "@in/server/api-types"
import type { Peer } from "@in/protocol/core"

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
