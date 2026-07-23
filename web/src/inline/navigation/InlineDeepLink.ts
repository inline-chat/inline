import type { ChatID, MessageID } from "@inline/ids"
import type { InlinePeerRoute } from "~/inline/data/peer"

export const inlinePeerDeepLink = (peer: InlinePeerRoute) =>
  peer.peerKind === "user" ? `in://user/${peer.peerId}` : `in://chat/${peer.peerId}`

export const inlineMessageDeepLink = (chatId: ChatID, messageId: MessageID) =>
  `in://chat/${chatId}/message/${messageId}`
