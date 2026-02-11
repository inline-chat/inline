import { db } from "@in/server/db"
import { chats, chatParticipants } from "@in/server/db/schema/chats"
import { Log } from "@in/server/utils/log"
import { and, eq, sql } from "drizzle-orm"
import type { HandlerContext } from "@in/server/controllers/helpers"
import { Chat, Dialog } from "@inline-chat/protocol/core"
import { encodeChat } from "@in/server/realtime/encoders/encodeChat"
import type { FunctionContext } from "@in/server/functions/_types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { dialogs } from "@in/server/db/schema"
import { Update } from "@inline-chat/protocol/core"
import { getUpdateGroup } from "@in/server/modules/updates"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import type { UpdateGroup } from "@in/server/modules/updates"
import type { DbChat, DbDialog } from "@in/server/db/schema"
import { encodeDialog } from "@in/server/realtime/encoders/encodeDialog"
import { AccessGuardsCache } from "@in/server/modules/authorization/accessGuardsCache"
import { UpdatesModel, type UpdateSeqAndDate } from "@in/server/db/models/updates"
import { UpdateBucket } from "@in/server/db/schema/updates"
import type { ServerUpdate } from "@inline-chat/protocol/server"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"

export async function createChat(
  input: {
    title: string
    spaceId?: bigint
    emoji?: string
    description?: string
    isPublic?: boolean
    participants?: { userId: bigint }[]
  },
  context: FunctionContext,
): Promise<{ chat: Chat; dialog: Dialog }> {
  const hasSpaceId = input.spaceId !== undefined && input.spaceId !== null
  const spaceId = hasSpaceId ? Number(input.spaceId) : undefined
  if (hasSpaceId && (spaceId === undefined || Number.isNaN(spaceId))) {
    throw new RealtimeRpcError(RealtimeRpcError.Code.BAD_REQUEST, "Space ID is invalid", 400)
  }
  const resolvedSpaceId = spaceId as number

  const isPublic = input.isPublic ?? (hasSpaceId ? true : false)

  if (!hasSpaceId) {
    if (isPublic) {
      throw new RealtimeRpcError(
        RealtimeRpcError.Code.BAD_REQUEST,
        "Public home threads are not supported",
        400,
      )
    }
    if (!input.participants || input.participants.length === 0) {
      throw new RealtimeRpcError(
        RealtimeRpcError.Code.BAD_REQUEST,
        "Participants are required for home threads",
        400,
      )
    }
  }

  // For space threads, if it's private, participants are required
  if (hasSpaceId && isPublic === false && (!input.participants || input.participants.length === 0)) {
    throw new RealtimeRpcError(
      RealtimeRpcError.Code.BAD_REQUEST,
      "Participants are required for private space threads",
      400,
    )
  }

  // For space threads, if it's public, participants should be empty
  if (hasSpaceId && isPublic === true && input.participants && input.participants.length > 0) {
    throw new RealtimeRpcError(
      RealtimeRpcError.Code.BAD_REQUEST,
      "Participants should be empty for public space threads",
      400,
    )
  }

  // For private chats, ensure the current user is included in participants
  if (isPublic === false && input.participants) {
    const currentUserIncluded = input.participants.some((p) => p.userId === BigInt(context.currentUserId))
    if (!currentUserIncluded) {
      input.participants.push({ userId: BigInt(context.currentUserId) })
    }
  }

  const trimmedTitle = input.title?.trim()
  // Only enforce title uniqueness within a space.
  // Home threads are intentionally NOT unique.
  if (trimmedTitle && hasSpaceId) {
    const titleLower = trimmedTitle.toLowerCase()
    const duplicate = await db
      .select({ id: chats.id })
      .from(chats)
      .where(
        and(
          eq(chats.type, "thread"),
          eq(chats.spaceId, resolvedSpaceId),
          sql`lower(trim(${chats.title})) = ${titleLower}`,
        ),
      )
      .limit(1)

    if (duplicate.length > 0) {
      throw new RealtimeRpcError(
        RealtimeRpcError.Code.BAD_REQUEST,
        "A thread with that name already exists",
        400,
      )
    }
  }

  let threadNumber: number | null = null
  if (hasSpaceId) {
    const maxThreadNumber: number = await db
      .select({ maxThreadNumber: sql<number>`MAX(${chats.threadNumber})` })
      .from(chats)
      .where(eq(chats.spaceId, resolvedSpaceId))
      .then((result) => result[0]?.maxThreadNumber ?? 0)

    threadNumber = maxThreadNumber + 1
  }

  const chat = await db
    .insert(chats)
    .values({
      type: "thread",
      spaceId: hasSpaceId ? resolvedSpaceId : null,
      title: input.title,
      publicThread: isPublic,
      date: new Date(),
      threadNumber: threadNumber,
      emoji: input.emoji ?? null,
      description: input.description ?? null,
      createdBy: context.currentUserId,
    })
    .returning()

  if (!chat[0]) {
    throw new RealtimeRpcError(RealtimeRpcError.Code.INTERNAL_ERROR, "Failed to create chat", 500)
  }

  // If it's a private space thread, add participants
  if (isPublic === false && input.participants) {
    const participants = input.participants.map((p) => ({
      chatId: chat[0]!.id,
      userId: Number(p.userId),
      date: new Date(),
    }))

    await db.insert(chatParticipants).values(participants)
    participants.forEach((p) => AccessGuardsCache.setChatParticipant(p.chatId, p.userId))
  }

  let dialog: DbDialog | undefined
  try {
    // Create a dialog for the chat
    ;[dialog] = await db
      .insert(dialogs)
      .values({
        chatId: chat[0].id,
        userId: context.currentUserId,
        spaceId: hasSpaceId ? resolvedSpaceId : null,
        date: new Date(),
      })
      .returning()

    if (!dialog) {
      throw new RealtimeRpcError(RealtimeRpcError.Code.INTERNAL_ERROR, "Failed to create dialog", 500)
    }
  } catch (error) {
    Log.shared.error(`Failed to create dialog for chat ${chat[0].id}: ${error}`)
    throw new RealtimeRpcError(RealtimeRpcError.Code.INTERNAL_ERROR, "Failed to create dialog", 500)
  }

  let encodedDialog: Dialog = Encoders.dialog(dialog, { unreadCount: 0 })

  const persisted = await persistNewChatUpdate(chat[0].id)

  // Broadcast the new chat update
  await pushUpdates({ chat: chat[0], currentUserId: context.currentUserId, update: persisted })

  return {
    chat: encodeChat(chat[0], { encodingForUserId: context.currentUserId }),
    dialog: encodedDialog,
  }
}

// ------------------------------------------------------------
// Updates
// ------------------------------------------------------------

/** Push updates for new chat creation */
const pushUpdates = async ({
  chat,
  currentUserId,
  update,
}: {
  chat: DbChat
  currentUserId: number
  update: UpdateSeqAndDate
}): Promise<{ selfUpdates: Update[]; updateGroup: UpdateGroup }> => {
  // Use getUpdateGroup with the new chat info
  const updateGroup = await getUpdateGroup({ threadId: chat.id }, { currentUserId })

  let selfUpdates: Update[] = []

  // Broadcast to all users in the update group
  updateGroup.userIds.forEach((userId) => {
    // Prepare the update
    const newChatUpdate: Update = {
      seq: update.seq,
      date: encodeDateStrict(update.date),
      update: {
        oneofKind: "newChat",
        newChat: {
          chat: Encoders.chat(chat, { encodingForUserId: userId }),
        },
      },
    }

    RealtimeUpdates.pushToUser(userId, [newChatUpdate])

    if (userId === currentUserId) {
      selfUpdates = [newChatUpdate]
    }
  })

  return { selfUpdates, updateGroup }
}

const persistNewChatUpdate = async (chatId: number): Promise<UpdateSeqAndDate> => {
  const chatUpdatePayload: ServerUpdate["update"] = {
    oneofKind: "newChat",
    newChat: {
      chatId: BigInt(chatId),
    },
  }

  const persisted = await db.transaction(async (tx): Promise<UpdateSeqAndDate> => {
    const [chat] = await tx.select().from(chats).where(eq(chats.id, chatId)).for("update").limit(1)

    if (!chat) {
      throw new RealtimeRpcError(RealtimeRpcError.Code.BAD_REQUEST, "Chat not found", 404)
    }

    const update = await UpdatesModel.insertUpdate(tx, {
      update: chatUpdatePayload,
      bucket: UpdateBucket.Chat,
      entity: chat,
    })

    await tx
      .update(chats)
      .set({
        updateSeq: update.seq,
        lastUpdateDate: update.date,
      })
      .where(eq(chats.id, chatId))

    return update
  })

  return persisted
}
