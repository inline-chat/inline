import type { InputPeer } from "@inline-chat/protocol/core"
import { chatId, userId } from "@inline/ids"
import type { Db } from "../../database"
import { DbObjectKind, type Dialog } from "../../database/models"
import { DbQueryPlanType } from "../../database/types"

/**
 * Resolve the resident dialog that owns a protocol peer. This is intentionally
 * a cache-only lookup: transactions must not perform storage or network work
 * from their synchronous optimistic/apply recipes.
 */
export const dialogForPeer = (
  db: Db,
  peer: InputPeer,
): Dialog | undefined => {
  const peerUserId =
    peer.type.oneofKind === "user"
      ? userId(peer.type.user.userId)
      : undefined
  const peerThreadId =
    peer.type.oneofKind === "chat"
      ? chatId(peer.type.chat.chatId)
      : undefined

  return db
    .queryCollection(
      DbQueryPlanType.Objects,
      DbObjectKind.Dialog,
      (dialog) =>
        (peerUserId != null && dialog.peerUserId === peerUserId) ||
        (peerThreadId != null &&
          (dialog.peerThreadId === peerThreadId ||
            dialog.chatId === peerThreadId)),
    )
    .at(0)
}
