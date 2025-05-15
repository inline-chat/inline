import type { TPeerInfo } from "@in/server/api-types"
import type { InputPeer, Peer } from "@in/protocol/core"
import type { DbChat } from "@in/server/db/schema"

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

export const encodePeerFromChat = (chat: DbChat, { currentUserId }: { currentUserId: number }): InputPeer => {
  if (chat.type == "thread") {
    return {
      type: { oneofKind: "chat", chat: { chatId: BigInt(chat.id) } },
    }
  }

  if (chat.type == "private") {
    let peerUserId = chat.minUserId === currentUserId ? chat.maxUserId : chat.minUserId
    if (!peerUserId) {
      throw new Error("Peer user ID is null")
    }
    return {
      type: { oneofKind: "user", user: { userId: BigInt(peerUserId) } },
    }
  }

  throw new Error("Unsupported chat type")
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
