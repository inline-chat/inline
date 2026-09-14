import type { InputPeer, Peer, UpdateBucket } from "@inline-chat/protocol/core"
import { protocolId, type SpaceID } from "@inline/ids"

export type SyncState = {
  lastSyncDate: number
}

export type SyncBucketCursor = {
  date: number
  seq: number
}

export type SyncBucketKey =
  | { kind: "user" }
  | { kind: "space"; spaceId: SpaceID }
  | { kind: "chat"; peer: Peer }

const peerIdentity = (peer: Peer) => {
  if (peer.type.oneofKind === "user") return `user:${peer.type.user.userId}`
  if (peer.type.oneofKind === "chat") return `chat:${peer.type.chat.chatId}`
  return "invalid"
}

export const syncBucketId = (key: SyncBucketKey) => {
  if (key.kind === "user") return "user"
  if (key.kind === "space") return `space:${key.spaceId}`
  return `chat:${peerIdentity(key.peer)}`
}

export const protocolInputPeer = (peer: Peer): InputPeer | undefined => {
  if (peer.type.oneofKind === "user") {
    return {
      type: {
        oneofKind: "user",
        user: { userId: peer.type.user.userId },
      },
    }
  }
  if (peer.type.oneofKind === "chat") {
    return {
      type: {
        oneofKind: "chat",
        chat: { chatId: peer.type.chat.chatId },
      },
    }
  }
  return undefined
}

export const protocolUpdateBucket = (key: SyncBucketKey): UpdateBucket => {
  if (key.kind === "user") {
    return { type: { oneofKind: "user", user: {} } }
  }
  if (key.kind === "space") {
    return {
      type: {
        oneofKind: "space",
        space: { spaceId: protocolId(key.spaceId) },
      },
    }
  }
  return {
    type: {
      oneofKind: "chat",
      chat: { peerId: protocolInputPeer(key.peer) },
    },
  }
}
