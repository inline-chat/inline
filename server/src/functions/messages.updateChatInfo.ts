import { db } from "@in/server/db"
import { chats, chatParticipants, type DbChat } from "@in/server/db/schema"
import { UpdatesModel } from "@in/server/db/models/updates"
import { UpdateBucket } from "@in/server/db/schema/updates"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { getUpdateGroup, type UpdateGroup } from "@in/server/modules/updates"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { Log } from "@in/server/utils/log"
import { and, eq } from "drizzle-orm"
import type { Update } from "@in/protocol/core"
import type { ServerUpdate } from "@in/protocol/server"
import type { FunctionContext } from "@in/server/functions/_types"

const log = new Log("functions.updateChatInfo")

type UpdateChatInfoInput = {
  chatId: number
  title?: string | null
  emoji?: string | null
}

type UpdateChatInfoOutput = {
  chat: DbChat
  didUpdate: boolean
  updatePayload?: ServerUpdate["update"]
}

export async function updateChatInfo(
  input: UpdateChatInfoInput,
  context: FunctionContext,
): Promise<{ chat: DbChat }> {
  const chatId = Number(input.chatId)
  if (!Number.isSafeInteger(chatId) || chatId <= 0) {
    throw RealtimeRpcError.ChatIdInvalid()
  }

  const titleProvided = input.title !== undefined
  const emojiProvided = input.emoji !== undefined
  if (!titleProvided && !emojiProvided) {
    throw RealtimeRpcError.BadRequest()
  }

  let nextTitle: string | undefined
  if (titleProvided) {
    nextTitle = (input.title ?? "").trim()
    if (nextTitle.length === 0) {
      throw new RealtimeRpcError(RealtimeRpcError.Code.BAD_REQUEST, "Title cannot be empty", 400)
    }
  }

  const nextEmoji = emojiProvided ? (input.emoji ?? "").trim() : undefined

  let result: UpdateChatInfoOutput | undefined

  try {
    result = await db.transaction(async (tx): Promise<UpdateChatInfoOutput> => {
      const [chat] = await tx.select().from(chats).where(eq(chats.id, chatId)).for("update").limit(1)

      if (!chat) {
        throw RealtimeRpcError.ChatIdInvalid()
      }

      if (chat.type !== "thread") {
        throw new RealtimeRpcError(RealtimeRpcError.Code.BAD_REQUEST, "Chat is not a thread", 400)
      }

      await AccessGuards.ensureChatAccess(chat, context.currentUserId)
      if (chat.publicThread !== true) {
        const participant = await tx
          .select({ id: chatParticipants.id })
          .from(chatParticipants)
          .where(and(eq(chatParticipants.chatId, chat.id), eq(chatParticipants.userId, context.currentUserId)))
          .limit(1)

        if (participant.length === 0) {
          throw RealtimeRpcError.PeerIdInvalid()
        }
      }

      const normalizedEmoji = emojiProvided ? (nextEmoji && nextEmoji.length > 0 ? nextEmoji : null) : undefined

      const shouldUpdateTitle = titleProvided && chat.title !== nextTitle
      const shouldUpdateEmoji = emojiProvided && chat.emoji !== normalizedEmoji

      if (!shouldUpdateTitle && !shouldUpdateEmoji) {
        return { chat, didUpdate: false }
      }

      const updatePayload: ServerUpdate["update"] = {
        oneofKind: "chatInfo",
        chatInfo: {
          chatId: BigInt(chat.id),
          ...(shouldUpdateTitle ? { title: nextTitle } : {}),
          ...(emojiProvided ? { emoji: normalizedEmoji ?? "" } : {}),
        },
      }

      const update = await UpdatesModel.insertUpdate(tx, {
        update: updatePayload,
        bucket: UpdateBucket.Chat,
        entity: chat,
      })

      const updateFields: Partial<DbChat> = {
        updateSeq: update.seq,
        lastUpdateDate: update.date,
      }

      if (shouldUpdateTitle) {
        updateFields.title = nextTitle
      }

      if (shouldUpdateEmoji) {
        updateFields.emoji = normalizedEmoji
      }

      const [updatedChat] = await tx
        .update(chats)
        .set(updateFields)
        .where(eq(chats.id, chat.id))
        .returning()

      if (!updatedChat) {
        throw RealtimeRpcError.InternalError()
      }

      return {
        chat: updatedChat,
        didUpdate: true,
        updatePayload,
      }
    })
  } catch (error) {
    log.error("Failed to update chat info", { chatId, error })
    if (error instanceof RealtimeRpcError) {
      throw error
    }
    throw new RealtimeRpcError(RealtimeRpcError.Code.INTERNAL_ERROR, "Failed to update chat info", 500)
  }

  if (!result) {
    throw RealtimeRpcError.InternalError()
  }

  if (result.didUpdate && result.updatePayload) {
    await pushUpdates({
      chat: result.chat,
      updatePayload: result.updatePayload,
      currentUserId: context.currentUserId,
    })
  }

  return { chat: result.chat }
}

// ------------------------------------------------------------
// Updates
// ------------------------------------------------------------

const pushUpdates = async ({
  chat,
  updatePayload,
  currentUserId,
}: {
  chat: DbChat
  updatePayload: ServerUpdate["update"]
  currentUserId: number
}): Promise<{ updateGroup: UpdateGroup }> => {
  const updateGroup = await getUpdateGroup({ threadId: chat.id }, { currentUserId })

  if (updatePayload.oneofKind !== "chatInfo") {
    return { updateGroup }
  }

  const chatInfoUpdate: Update = {
    update: {
      oneofKind: "chatInfo",
      chatInfo: updatePayload.chatInfo,
    },
  }

  updateGroup.userIds.forEach((userId) => {
    RealtimeUpdates.pushToUser(userId, [chatInfoUpdate])
  })

  return { updateGroup }
}
