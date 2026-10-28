import type { InputPeer, Update } from "@inline-chat/protocol/core"
import type { ServerUpdate } from "@in/server/protocol/server"
import { db } from "@in/server/db"
import { ChatModel } from "@in/server/db/models/chats"
import { UpdatesModel } from "@in/server/db/models/updates"
import { chats, messages } from "@in/server/db/schema"
import { UpdateBucket } from "@in/server/db/schema/updates"
import { pushPinnedMessagesUpdates } from "@in/server/functions/messages.pinMessage"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { FunctionContext } from "@in/server/functions/_types"
import { and, eq, isNotNull } from "drizzle-orm"

type Input = {
  peer: InputPeer
}

type Output = {
  updates: Update[]
}

/** Unpins every message in a chat with one update, so clients go straight to an empty pin list. */
export const unpinAllMessages = async (input: Input, context: FunctionContext): Promise<Output> => {
  const chat = await ChatModel.getAuthorizedChatFromInputPeer(input.peer, context)

  const update = await db.transaction(async (tx) => {
    const [lockedChat] = await tx.select().from(chats).where(eq(chats.id, chat.id)).for("update").limit(1)
    if (!lockedChat) {
      throw RealtimeRpcError.ChatIdInvalid()
    }

    const unpinned = await tx
      .update(messages)
      .set({ pinnedAt: null })
      .where(and(eq(messages.chatId, chat.id), isNotNull(messages.pinnedAt)))
      .returning({ messageId: messages.messageId })

    // Nothing was pinned, so there is no change to sequence or push.
    if (unpinned.length === 0) {
      return null
    }

    const updatePayload: ServerUpdate["update"] = {
      oneofKind: "pinnedMessages",
      pinnedMessages: {
        chatId: BigInt(chat.id),
        messageIds: [],
      },
    }

    const update = await UpdatesModel.insertUpdate(tx, {
      update: updatePayload,
      bucket: UpdateBucket.Chat,
      entity: lockedChat,
    })

    const [updatedChat] = await tx
      .update(chats)
      .set({
        updateSeq: update.seq,
        lastUpdateDate: update.date,
      })
      .where(eq(chats.id, chat.id))
      .returning()

    if (!updatedChat) {
      throw RealtimeRpcError.InternalError()
    }

    return update
  })

  if (!update) {
    return { updates: [] }
  }

  const { selfUpdates } = await pushPinnedMessagesUpdates({
    inputPeer: input.peer,
    currentUserId: context.currentUserId,
    update,
    pinnedMessageIds: [],
  })

  return { updates: selfUpdates }
}
