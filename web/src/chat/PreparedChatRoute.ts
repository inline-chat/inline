import type { UserID } from "@inline/ids"
import type { InlinePeerRoute } from "~/inline/data/peer"
import type { PreparedChatPayload } from "./ChatOpenPreloader"

export const preparedChatMatchesRoute = (
  prepared: PreparedChatPayload | undefined,
  accountId: UserID,
  peer: InlinePeerRoute,
) =>
  prepared?.accountId === accountId &&
  prepared.peer.peerKind === peer.peerKind &&
  prepared.peer.peerId === peer.peerId
