import { chatTitleFields } from "@in/server/modules/encryption/chatTitleStorage"
import { db } from "@in/server/db"
import { chats, type DbChat } from "@in/server/db/schema"
import { UpdatesModel } from "@in/server/db/models/updates"
import { UpdateBucket } from "@in/server/db/schema/updates"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { getUpdateGroup, type UpdateGroup } from "@in/server/modules/updates"
import { invalidateChatInfoCache } from "@in/server/modules/cache/chatInfo"
import { publishCacheInvalidation } from "@in/server/modules/cache/cluster"
import { publishDurableReference } from "@in/server/modules/internalMessaging/durable"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { Log } from "@in/server/utils/log"
import { eq } from "drizzle-orm"
import type { AgentThreadContext, Update } from "@inline-chat/protocol/core"
import type { ServerUpdate } from "@in/server/protocol/server"
import type { FunctionContext } from "@in/server/functions/_types"
import { emitMessageSubthreadUpdateIfNeeded } from "@in/server/modules/subthreads"
import {
  chatAgentContext,
  encodeAgentThreadContext,
  hasProviderSession,
  validateAgentThreadContext,
} from "@in/server/modules/agentConfiguration"
import { requireManageableBot } from "@in/server/functions/bot.avatarHelpers"

const log = new Log("functions.updateChatInfo")

type UpdateChatInfoInput = {
  chatId: number
  title?: string | null
  emoji?: string | null
  agentContext?: AgentThreadContext
}

type UpdateChatInfoOutput = {
  chat: DbChat
  didUpdate: boolean
  updatePayload?: ServerUpdate["update"]
}

type UpdateThreadInfoInput = {
  chatId: number
  title?: string | null
  emoji?: string | null
  agentContext?: AgentThreadContext
  currentUserId: number
  requireAccess?: boolean
  titleGuard?:
    | { kind: "empty" }
    | { kind: "untitledExact"; currentTitle: string | null }
  isUntitled?: boolean
  autoTitleGenerated?: boolean
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
  const agentContextProvided = input.agentContext !== undefined
  if (!titleProvided && !emojiProvided && !agentContextProvided) {
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
  const nextAgentContext = input.agentContext
    ? await validateAgentThreadContext(input.agentContext, { operation: "update_chat_info" })
    : undefined
  if (nextAgentContext) {
    const bot = await requireManageableBot(Number(nextAgentContext.botUserId), context)
    if (bot.botCreatorId !== context.currentUserId) throw RealtimeRpcError.UserIdInvalid()
  }

  let result: UpdateChatInfoOutput | undefined

  try {
    result = await updateThreadInfo({
      chatId,
      title: titleProvided ? nextTitle : undefined,
      emoji: emojiProvided ? nextEmoji : undefined,
      agentContext: nextAgentContext,
      currentUserId: context.currentUserId,
      requireAccess: true,
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

  return { chat: result.chat }
}

export async function updateThreadInfo(input: UpdateThreadInfoInput): Promise<UpdateChatInfoOutput> {
  const titleProvided = input.title !== undefined
  const emojiProvided = input.emoji !== undefined
  const agentContextProvided = input.agentContext !== undefined
  if (!titleProvided && !emojiProvided && !agentContextProvided) {
    throw RealtimeRpcError.BadRequest()
  }

  const nextTitle = titleProvided ? (input.title ?? "").trim() : undefined
  const nextEmoji = emojiProvided ? (input.emoji ?? "").trim() : undefined

  const result = await db.transaction(async (tx): Promise<UpdateChatInfoOutput> => {
    const [chat] = await tx.select().from(chats).where(eq(chats.id, input.chatId)).for("update").limit(1)

    if (!chat) {
      throw RealtimeRpcError.ChatIdInvalid()
    }

    if (chat.type !== "thread") {
      throw new RealtimeRpcError(RealtimeRpcError.Code.BAD_REQUEST, "Chat is not a thread", 400)
    }

    if (input.requireAccess === true) {
      if (titleProvided || emojiProvided) {
        await AccessGuards.ensureChatInfoEditAccess(chat, input.currentUserId, tx)
      } else {
        await AccessGuards.ensureChatAccess(chat, input.currentUserId, tx)
      }
    }

    if (input.autoTitleGenerated === true) {
      await AccessGuards.ensureChatAccess(chat, input.currentUserId, tx)
    }

    const currentAgentContext = chatAgentContext(chat)
    if (agentContextProvided) {
      if (
        !currentAgentContext ||
        !input.agentContext ||
        currentAgentContext.botUserId !== input.agentContext.botUserId ||
        currentAgentContext.agentId !== input.agentContext.agentId
      ) {
        throw RealtimeRpcError.BadRequest()
      }
      const currentProjectId = currentAgentContext.configuration?.projectId
      const nextProjectId = input.agentContext.configuration?.projectId
      if (
        currentProjectId !== nextProjectId &&
        await hasProviderSession(chat.id, tx)
      ) {
        throw RealtimeRpcError.BadRequest()
      }
    }

    if (input.titleGuard) {
      const titleGuardMatches = input.titleGuard.kind === "empty"
        ? !isNonEmpty(chat.title)
        : chat.isUntitled === true && chat.title === input.titleGuard.currentTitle

      if (!titleGuardMatches || (input.autoTitleGenerated === true && chat.autoTitleGenerated === true)) {
        return { chat, didUpdate: false }
      }
    }

    const normalizedEmoji = emojiProvided ? (nextEmoji && nextEmoji.length > 0 ? nextEmoji : null) : undefined

    // Saving the same text manually still claims title ownership. Likewise,
    // matching a placeholder counts as a completed automatic generation.
    const shouldUpdateTitle = titleProvided && (
      chat.title !== nextTitle ||
      chat.isUntitled !== (input.isUntitled === true ? true : null) ||
      (input.autoTitleGenerated === true && chat.autoTitleGenerated !== true)
    )
    const shouldUpdateEmoji = emojiProvided && chat.emoji !== normalizedEmoji
    const encodedAgentContext = input.agentContext ? encodeAgentThreadContext(input.agentContext) : undefined
    const shouldUpdateAgentContext = agentContextProvided && encodedAgentContext !== undefined &&
      !Buffer.from(chat.agentContext ?? []).equals(encodedAgentContext)

    if (!shouldUpdateTitle && !shouldUpdateEmoji && !shouldUpdateAgentContext) {
      return { chat, didUpdate: false }
    }

    const updatePayload: ServerUpdate["update"] = {
      oneofKind: "chatInfo",
      chatInfo: {
        chatId: BigInt(chat.id),
        ...(shouldUpdateTitle ? { title: nextTitle } : {}),
        ...(shouldUpdateTitle && input.isUntitled === true ? { untitled: true } : {}),
        ...(emojiProvided ? { emoji: normalizedEmoji ?? "" } : {}),
        ...(shouldUpdateAgentContext ? { agentContext: input.agentContext } : {}),
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
      Object.assign(updateFields, chatTitleFields(nextTitle ?? null, chat))
      updateFields.isUntitled = input.isUntitled === true ? true : null
      if (input.autoTitleGenerated === true) updateFields.autoTitleGenerated = true
    }

    if (shouldUpdateEmoji) {
      updateFields.emoji = normalizedEmoji
    }
    if (shouldUpdateAgentContext) {
      updateFields.agentContext = encodedAgentContext
    }

    // The row is locked above; the decrypted title guard remains valid until commit.
    const where = eq(chats.id, chat.id)

    const [updatedChat] = await tx
      .update(chats)
      .set(updateFields)
      .where(where)
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

  if (result.didUpdate && result.updatePayload) {
    invalidateChatInfoCache(result.chat.id)
    publishCacheInvalidation({ kind: "chatMetadata", chatId: result.chat.id })
    publishDurableReference({ bucket: { kind: "chat", chatId: result.chat.id }, frontier: result.chat.updateSeq ?? 0,
      senderUserId: input.currentUserId })
    await pushUpdates({
      chat: result.chat,
      updatePayload: result.updatePayload,
      currentUserId: input.currentUserId,
    })
    if (result.chat.parentChatId != null) {
      await emitMessageSubthreadUpdateIfNeeded({
        chatId: result.chat.id,
        currentUserId: input.currentUserId,
      }).catch((error) => {
        log.warn("Failed to refresh parent thread card after title update", {
          chatId: result.chat.id,
          error,
        })
      })
    }
  }

  return result
}

const isNonEmpty = (value: string | null): boolean => value != null && value.trim().length > 0

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
