import { db } from "@in/server/db"
import { chats, dialogs, users, type DbDialog } from "@in/server/db/schema"
import {
  encodeChatInfo,
  encodeDialogInfo,
  TChatInfo,
  TDialogInfo,
  TUserInfo,
  encodeUserInfo,
  encodeMinUserInfo,
  TMinUserInfo,
} from "@in/server/api-types"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import type { Static } from "elysia"
import { Type } from "@sinclair/typebox"
import type { HandlerContext } from "@in/server/controllers/helpers"
import { and, eq, inArray, not, or } from "drizzle-orm"
import { TInputId } from "../types/methods"

export const Input = Type.Object({
  userId: Type.String(),
  // TODO: Require access_hash to avoid spam
})

export const Response = Type.Object({
  chat: TChatInfo,
  dialog: TDialogInfo,
  user: TMinUserInfo,
})

export const handler = async (
  input: Static<typeof Input>,
  context: HandlerContext,
): Promise<Static<typeof Response>> => {
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

  let d: DbDialog[] = []
  // Create or update dialog for current user only
  if (minUserId === maxUserId) {
    let [dialog] = await db
      .insert(dialogs)
      .values({
        chatId: chat.id,
        userId: context.currentUserId,
        peerUserId: context.currentUserId,
        date: new Date(),
      })
      .onConflictDoNothing()
      .returning()

    if (!dialog) {
      dialog = await db.query.dialogs.findFirst({
        where: and(
          eq(dialogs.userId, context.currentUserId),
          eq(dialogs.peerUserId, context.currentUserId),
          eq(dialogs.chatId, chat.id),
        ),
      })
    }

    if (!dialog) {
      Log.shared.error("Failed to create dialog")
      throw new InlineError(InlineError.ApiError.INTERNAL)
    }
    d = [dialog]
  } else {
    const result = await db
      .insert(dialogs)
      .values([
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
      .onConflictDoUpdate({
        target: [dialogs.chatId, dialogs.userId],
        set: { date: new Date() },
      })
      .returning()

    if (!result) {
      Log.shared.error("Failed to create dialog")
      throw new InlineError(InlineError.ApiError.INTERNAL)
    }
    d = result
  }

  // Fetch peer users (both current user and the peer)
  const [user] = await db.select().from(users).where(eq(users.id, peerId))

  if (!user) {
    Log.shared.error("Failed to get user")
    throw new InlineError(InlineError.ApiError.INTERNAL)
  }

  const [returningDialog] = d.filter((d) => d.userId === context.currentUserId)

  if (!returningDialog) {
    Log.shared.error("Failed to get dialog")
    throw new InlineError(InlineError.ApiError.INTERNAL)
  }

  return {
    chat: encodeChatInfo(chat, { currentUserId: context.currentUserId }),
    dialog: encodeDialogInfo({
      ...returningDialog,
      unreadCount: 0,
    }),

    // Deprecated
    user: encodeMinUserInfo(user),
  }
}
