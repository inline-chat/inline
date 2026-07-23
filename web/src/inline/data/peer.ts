import type { Dialog } from "@inline/client"
import type { MessageDraftPeer } from "@inline/client"
import type { InputPeer } from "@inline-chat/protocol/core"
import {
  parseInlineId,
  protocolId,
  type ChatID,
  type UserID,
} from "@inline/ids"

export type InlinePeerKind = "chat" | "user"

export type InlinePeerRoute =
  | { peerKind: "chat"; peerId: ChatID }
  | { peerKind: "user"; peerId: UserID }

export const inputPeer = ({ peerKind, peerId }: InlinePeerRoute): InputPeer =>
  peerKind === "user"
    ? {
        type: {
          oneofKind: "user",
          user: { userId: protocolId(peerId) },
        },
      }
    : {
        type: {
          oneofKind: "chat",
          chat: { chatId: protocolId(peerId) },
        },
      }

export const messageDraftPeer = (
  peer: InlinePeerRoute,
): MessageDraftPeer =>
  peer.peerKind === "user"
    ? { peerKind: "user", peerUserId: peer.peerId }
    : { peerKind: "chat", peerThreadId: peer.peerId }

export const dialogPeerRoute = (dialog: Dialog): InlinePeerRoute =>
  dialog.peerUserId != null
    ? { peerKind: "user", peerId: dialog.peerUserId }
    : { peerKind: "chat", peerId: dialog.peerThreadId ?? dialog.chatId }

export const dialogMatchesPeer = (
  dialog: Dialog,
  peer: InlinePeerRoute,
) =>
  peer.peerKind === "user"
    ? dialog.peerUserId === peer.peerId
    : dialog.peerThreadId === peer.peerId || dialog.chatId === peer.peerId

export const parsePeerRoute = (peerKind: string, peerId: string): InlinePeerRoute | undefined => {
  if (peerKind === "chat") {
    const id = parseInlineId<"chat">(peerId, { positive: true })
    return id ? { peerKind, peerId: id } : undefined
  }
  if (peerKind === "user") {
    const id = parseInlineId<"user">(peerId, { positive: true })
    return id ? { peerKind, peerId: id } : undefined
  }
  return undefined
}
