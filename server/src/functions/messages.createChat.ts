import { db } from "@in/server/db"
import { chats, chatParticipants } from "@in/server/db/schema/chats"
import { Log } from "@in/server/utils/log"
import { eq, sql } from "drizzle-orm"
import type { HandlerContext } from "@in/server/controllers/helpers"
import { Chat, Dialog } from "@in/protocol/core"
import { encodeChat } from "@in/server/realtime/encoders/encodeChat"
import type { FunctionContext } from "@in/server/functions/_types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { dialogs } from "@in/server/db/schema"
import { Update } from "@in/protocol/core"
import { getUpdateGroup } from "@in/server/modules/updates"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import type { UpdateGroup } from "@in/server/modules/updates"
import type { DbChat } from "@in/server/db/schema"

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
  const spaceId = Number(input.spaceId)
  if (isNaN(spaceId)) {
    throw new RealtimeRpcError(RealtimeRpcError.Code.BAD_REQUEST, "Space ID is invalid", 400)
  }

  // For space threads, if it's private, participants are required
  if (input.isPublic === false && (!input.participants || input.participants.length === 0)) {
    throw new RealtimeRpcError(
      RealtimeRpcError.Code.BAD_REQUEST,
      "Participants are required for private space threads",
      400,
    )
  }

  // For space threads, if it's public, participants should be empty
  if (input.isPublic === true && input.participants && input.participants.length > 0) {
    throw new RealtimeRpcError(
      RealtimeRpcError.Code.BAD_REQUEST,
      "Participants should be empty for public space threads",
      400,
    )
  }

  // For private chats, ensure the current user is included in participants
  if (input.isPublic === false && input.participants) {
    const currentUserIncluded = input.participants.some((p) => p.userId === BigInt(context.currentUserId))
    if (!currentUserIncluded) {
      input.participants.push({ userId: BigInt(context.currentUserId) })
    }
  }

  var maxThreadNumber: number = await db
    .select({ maxThreadNumber: sql<number>`MAX(${chats.threadNumber})` })
    .from(chats)
    .where(eq(chats.spaceId, spaceId))
    .then((result) => result[0]?.maxThreadNumber ?? 0)

  var threadNumber = maxThreadNumber + 1

  const chat = await db
    .insert(chats)
    .values({
      type: "thread",
      spaceId: spaceId,
      title: input.title,
      publicThread: input.isPublic ?? true,
      date: new Date(),
      threadNumber: threadNumber,
      emoji: input.emoji ?? null,
      description: input.description ?? null,
    })
    .returning()

  if (!chat[0]) {
    throw new RealtimeRpcError(RealtimeRpcError.Code.INTERNAL_ERROR, "Failed to create chat", 500)
  }

  // If it's a private space thread, add participants
  if (input.isPublic === false && input.participants) {
    await db.insert(chatParticipants).values(
      input.participants.map((p) => ({
        chatId: chat[0]!.id,
        userId: Number(p.userId),
        date: new Date(),
      })),
    )
  }

  try {
    // Create a dialog for the chat
    await db.insert(dialogs).values({
      chatId: chat[0].id,
      userId: context.currentUserId,
      spaceId: spaceId,
      date: new Date(),
    })
  } catch (error) {
    Log.shared.error(`Failed to create dialog for chat ${chat[0].id}: ${error}`)
    throw new RealtimeRpcError(RealtimeRpcError.Code.INTERNAL_ERROR, "Failed to create dialog", 500)
  }

  const dialog: Dialog = {
    archived: false,
    pinned: false,
    spaceId: BigInt(spaceId),
    peer: {
      type: {
        oneofKind: "chat",
        chat: {
          chatId: BigInt(chat[0].id),
        },
      },
    },
  }

  // Broadcast the new chat update
  await pushUpdates({ chat: chat[0], currentUserId: context.currentUserId })

  return {
    chat: encodeChat(chat[0], { encodingForUserId: context.currentUserId }),
    dialog,
  }
}

// ------------------------------------------------------------
// Updates
// ------------------------------------------------------------

/** Push updates for new chat creation */
const pushUpdates = async ({
  chat,
  currentUserId,
}: {
  chat: DbChat
  currentUserId: number
}): Promise<{ selfUpdates: Update[]; updateGroup: UpdateGroup }> => {
  // Use getUpdateGroup with the new chat info
  const updateGroup = await getUpdateGroup({ threadId: chat.id }, { currentUserId })

  let selfUpdates: Update[] = []

  // Broadcast to all users in the update group
  updateGroup.userIds.forEach((userId) => {
    // Prepare the update
    const newChatUpdate: Update = {
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
