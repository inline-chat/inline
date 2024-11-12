import { db } from "@in/server/db"
import { chats, dialogs, users } from "@in/server/db/schema"
import { encodeChatInfo, encodeDialogInfo, TChatInfo, TDialogInfo } from "@in/server/models"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import type { Static } from "elysia"
import { Type } from "@sinclair/typebox"
import type { HandlerContext } from "@in/server/controllers/v1/helpers"
import { and, eq } from "drizzle-orm"
import { TInputId } from "../types/methods"

export const Input = Type.Object({
  userId: TInputId,
  // TODO: Require access_hash to avoid spam
})

export const Response = Type.Object({
  chat: TChatInfo,
  dialog: TDialogInfo,
})

export const handler = async (
  input: Static<typeof Input>,
  context: HandlerContext,
): Promise<Static<typeof Response>> => {
  try {
    const peerId = Number(input.userId)
    if (isNaN(peerId)) {
      throw new InlineError(InlineError.ApiError.PEER_INVALID)
    }

    // For self-chat, both minUserId and maxUserId will be currentUserId
    const isSelfChat = peerId === context.currentUserId
    let minUserId, maxUserId

    if (isSelfChat) {
      minUserId = maxUserId = context.currentUserId
    } else {
      minUserId = context.currentUserId < peerId ? context.currentUserId : peerId
      maxUserId = context.currentUserId > peerId ? context.currentUserId : peerId
    }

    const currentUserName = await db
      .select({ name: users.firstName })
      .from(users)
      .where(eq(users.id, context.currentUserId))
      .then((result) => result[0]?.name)

    const title = isSelfChat ? `${currentUserName} (You)` : null

    const [chat] = await db
      .insert(chats)
      .values({
        title,
        type: "private",
        date: new Date(),
        minUserId,
        maxUserId,
      })
      .onConflictDoUpdate({
        target: [chats.minUserId, chats.maxUserId],
        set: { title },
      })
      .returning()

    if (!chat) {
      Log.shared.error("Failed to create private chat")
      throw new InlineError(InlineError.ApiError.INTERNAL)
    }

    // Create dialog entries for both users
    await db.insert(dialogs).values([
      {
        chatId: chat.id,
        userId: minUserId,
        peerUserId: maxUserId,
        date: new Date(),
      },
      {
        chatId: chat.id,
        userId: maxUserId,
        peerUserId: minUserId,
        date: new Date(),
      },
    ])

    // After creating the dialogs, get the current user's dialog
    const currentUserDialog = await db.query.dialogs.findFirst({
      where: and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, context.currentUserId)),
    })

    if (!currentUserDialog) {
      Log.shared.error("Failed to find created dialog")
      throw new InlineError(InlineError.ApiError.INTERNAL)
    }

    return {
      chat: encodeChatInfo(chat, { currentUserId: context.currentUserId }),
      dialog: encodeDialogInfo(currentUserDialog),
    }
  } catch (error) {
    Log.shared.error("Failed to create private chat", error)
    throw new InlineError(InlineError.ApiError.INTERNAL)
  }
}
