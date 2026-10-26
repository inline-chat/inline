import type { Peer, Update } from "@inline-chat/protocol/core"
import type { ServerUpdate } from "@in/server/protocol/server"
import { UpdatesModel, type UpdateSeqAndDate } from "@in/server/db/models/updates"
import { UsersModel } from "@in/server/db/models/users"
import { chats, type DbChat } from "@in/server/db/schema"
import { UpdateBucket } from "@in/server/db/schema/updates"
import type { Transaction } from "@in/server/db/types"
import { getEffectiveAccessUserIds } from "@in/server/modules/authorization/threadAccess"
import { encodeOutputPeerFromChat } from "@in/server/realtime/encoders/encodePeer"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { eq } from "drizzle-orm"

/** Appends one durable update to a chat's bucket; the chat row stays locked until commit. */
export async function insertChatUpdate(
  tx: Transaction,
  chatId: number,
  update: ServerUpdate["update"],
): Promise<{ chat: DbChat; durable: UpdateSeqAndDate }> {
  const [lockedChat] = await tx.select().from(chats).where(eq(chats.id, chatId)).for("update").limit(1)
  if (!lockedChat) throw RealtimeRpcError.ChatIdInvalid()
  const durable = await UpdatesModel.insertUpdate(tx, { update, bucket: UpdateBucket.Chat, entity: lockedChat })
  await tx.update(chats).set({ updateSeq: durable.seq, lastUpdateDate: durable.date }).where(eq(chats.id, chatId))
  return { chat: lockedChat, durable }
}

export async function chatRecipientUserIds(chat: DbChat): Promise<number[]> {
  if (chat.type === "private") {
    const ids = [chat.minUserId, chat.maxUserId].filter((id): id is number => id !== null)
    return UsersModel.getActiveUserIds([...new Set(ids)])
  }
  return getEffectiveAccessUserIds(chat)
}

/** Live delivery after commit, with the chat peer encoded for each recipient. */
export async function pushChatUpdate(
  chat: DbChat,
  durable: UpdateSeqAndDate,
  build: (peer: Peer) => Update["update"],
): Promise<void> {
  for (const userId of await chatRecipientUserIds(chat)) {
    RealtimeUpdates.pushToUser(userId, [{
      seq: durable.seq,
      date: encodeDateStrict(durable.date),
      update: build(encodeOutputPeerFromChat(chat, { currentUserId: userId })),
    }])
  }
}
