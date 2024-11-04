import { db } from "@in/server/db"
import { chats, dialogs, users } from "@in/server/db/schema"
import { encodeChatInfo, TChatInfo } from "@in/server/models"
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

    const peerName = await db.select({ name: users.firstName }).from(users).where(eq(users.id, peerId))
    const currentUserName = await db
      .select({ name: users.firstName })
      .from(users)
      .where(eq(users.id, context.currentUserId))

    const firstUserName = currentUserName[0]?.name
    const secondUserName = peerName[0]?.name
    const minUserId = context.currentUserId < peerId ? context.currentUserId : peerId
    const maxUserId = context.currentUserId > peerId ? context.currentUserId : peerId
    const title = firstUserName && secondUserName ? `${firstUserName}, ${secondUserName}` : null
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

    let peerExistingDialog = await db
      .select()
      .from(dialogs)
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, peerId)))
      .then((result) => result[0])

    let currentUserExistingDialog = await db
      .select()
      .from(dialogs)
      .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, context.currentUserId)))
      .then((result) => result[0])

    if (peerExistingDialog == null) {
      await db.insert(dialogs).values([
        {
          chatId: chat.id,
          userId: peerId,
          date: new Date(),
        },
      ])
    }
    if (currentUserExistingDialog == null) {
      await db.insert(dialogs).values([
        {
          chatId: chat.id,
          userId: context.currentUserId,
          date: new Date(),
        },
      ])
    }
    return { chat: encodeChatInfo(chat, { currentUserId: context.currentUserId }) }
  } catch (error) {
    Log.shared.error("Failed to create private chat", error)
    throw new InlineError(InlineError.ApiError.INTERNAL)
  }
}
