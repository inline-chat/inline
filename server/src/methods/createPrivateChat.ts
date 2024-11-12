import { db } from "@in/server/db"
import { chats, dialogs, users } from "@in/server/db/schema"
import { encodeChatInfo, encodeDialogInfo, TChatInfo, TDialogInfo, TUserInfo, encodeUserInfo } from "@in/server/models"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import type { Static } from "elysia"
import { Type } from "@sinclair/typebox"
import type { HandlerContext } from "@in/server/controllers/v1/helpers"
import { and, eq, or } from "drizzle-orm"
import { TInputId } from "../types/methods"

export const Input = Type.Object({
  userId: Type.String(),
  // TODO: Require access_hash to avoid spam
})

export const Response = Type.Object({
  chat: TChatInfo,
  dialog: TDialogInfo,
  peerUsers: Type.Array(TUserInfo),
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
    const minUserId = isSelfChat ? context.currentUserId : Math.min(context.currentUserId, peerId)
    const maxUserId = isSelfChat ? context.currentUserId : Math.max(context.currentUserId, peerId)

    const currentUserName = await db
      .select({ name: users.firstName })
      .from(users)
      .where(eq(users.id, context.currentUserId))
      .then((result) => result[0]?.name)

    const title = isSelfChat ? `${currentUserName} (You)` : null

    // Create or get existing chat
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

    // Create or update dialog for current user only
    const [dialog] = await db
      .insert(dialogs)
      .values({
        chatId: chat.id,
        userId: context.currentUserId,
        peerUserId: isSelfChat ? context.currentUserId : peerId,
        date: new Date(),
      })
      .onConflictDoUpdate({
        target: [dialogs.chatId, dialogs.userId],
        set: { date: new Date() },
      })
      .returning()

    if (!dialog) {
      Log.shared.error("Failed to create dialog")
      throw new InlineError(InlineError.ApiError.INTERNAL)
    }

    // Fetch peer users (both current user and the peer)
    const peerUsers = await db
      .select()
      .from(users)
      .where(or(eq(users.id, context.currentUserId), eq(users.id, peerId)))

    return {
      chat: encodeChatInfo(chat, { currentUserId: context.currentUserId }),
      dialog: encodeDialogInfo(dialog),
      peerUsers: peerUsers.map((user) => encodeUserInfo(user)),
    }
  } catch (error) {
    Log.shared.error("Failed to create private chat", error)
    throw new InlineError(InlineError.ApiError.INTERNAL)
  }
}
