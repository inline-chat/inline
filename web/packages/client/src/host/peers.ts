import type { InputPeer } from "@inline-chat/protocol/core"
import type { ChatID, UserID } from "@inline/ids"
import type { Db } from "../database"
import { DbObjectKind, type Dialog } from "../database/models"
import { DbQueryPlanType } from "../database/types"

export const dialogForChat = (db: Db, chatId: ChatID): Dialog | undefined =>
  db
    .queryCollection<DbObjectKind.Dialog, Dialog, DbQueryPlanType.Objects>(
      DbQueryPlanType.Objects,
      DbObjectKind.Dialog,
      (dialog) => dialog.chatId === chatId,
    )
    .at(0)

/** The peer user of a direct message chat, from the chat or its dialog. */
export const peerUserForChat = (db: Db, chatId: ChatID): UserID | undefined =>
  db.get(db.ref(DbObjectKind.Chat, chatId))?.peerUserId ?? dialogForChat(db, chatId)?.peerUserId

/** The protocol peer the server expects for a chat: the user for a DM, else the chat. */
export const inputPeerForChat = (db: Db, chatId: ChatID): InputPeer => {
  const peerUserId = peerUserForChat(db, chatId)
  return peerUserId
    ? { type: { oneofKind: "user", user: { userId: BigInt(peerUserId) } } }
    : { type: { oneofKind: "chat", chat: { chatId: BigInt(chatId) } } }
}
