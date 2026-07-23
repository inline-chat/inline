import type { UserID } from "@inline/ids"
import type { InlinePeerRoute } from "~/inline/data/peer"
import type { ChatMessageForwardHeader } from "./ChatRowListModel"

export const forwardTargetPeer = (
  forward: ChatMessageForwardHeader,
  currentPeer: InlinePeerRoute,
  currentUserId: UserID,
): InlinePeerRoute => {
  const target = forward.fromPeer ?? currentPeer
  if (target.peerKind !== "user") return target
  return {
    peerKind: "user",
    peerId:
      forward.fromId && forward.fromId !== currentUserId
        ? forward.fromId
        : target.peerId,
  }
}
