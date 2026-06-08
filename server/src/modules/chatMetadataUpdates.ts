import { UpdatesModel, type UpdateSeqAndDate } from "@in/server/db/models/updates"
import { chats, type DbChat } from "@in/server/db/schema"
import { UpdateBucket } from "@in/server/db/schema/updates"
import type { Transaction } from "@in/server/db/types"
import { eq } from "drizzle-orm"

export type ChatMetadataUpdate = {
  chat: DbChat
  update: UpdateSeqAndDate
}

export async function persistChatMetadataUpdates(tx: Transaction, chatIds: number[]): Promise<ChatMetadataUpdate[]> {
  const updates: ChatMetadataUpdate[] = []

  for (const chatId of Array.from(new Set(chatIds))) {
    const [chat] = await tx.select().from(chats).where(eq(chats.id, chatId)).for("update").limit(1)
    if (!chat) {
      continue
    }

    const update = await UpdatesModel.insertUpdate(tx, {
      update: {
        oneofKind: "newChat",
        newChat: {
          chatId: BigInt(chat.id),
        },
      },
      bucket: UpdateBucket.Chat,
      entity: chat,
    })

    const [updatedChat] = await tx
      .update(chats)
      .set({
        updateSeq: update.seq,
        lastUpdateDate: update.date,
      })
      .where(eq(chats.id, chat.id))
      .returning()

    updates.push({
      chat: updatedChat ?? {
        ...chat,
        updateSeq: update.seq,
        lastUpdateDate: update.date,
      },
      update,
    })
  }

  return updates
}
