import { db } from "@in/server/db"
import { chats, dialogs, users } from "@in/server/db/schema"
import { encodeChatInfo, TChatInfo } from "@in/server/models"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import type { Static } from "elysia"
import { Type } from "@sinclair/typebox"
import type { HandlerContext } from "@in/server/controllers/v1/helpers"
import { and, eq, or, sql } from "drizzle-orm"

export const Input = Type.Object({
  peerId: Type.String(),
})

export const Response = Type.Object({
  chat: TChatInfo,
})

export const handler = async (
  input: Static<typeof Input>,
  context: HandlerContext,
): Promise<Static<typeof Response>> => {
  try {
    const peerId = parseInt(input.peerId, 10)
    if (isNaN(peerId)) {
      throw new InlineError(ErrorCodes.SERVER_ERROR, "Invalid peerId")
    }

    const peerName = await db.select({ name: users.firstName }).from(users).where(eq(users.id, peerId))
    const currentUserName = await db
      .select({ name: users.firstName })
      .from(users)
      .where(eq(users.id, context.currentUserId))

    const minUserId = context.currentUserId < peerId ? context.currentUserId : peerId
    const maxUserId = context.currentUserId > peerId ? context.currentUserId : peerId
    const title = `${currentUserName[0].name}, ${peerName[0].name}`
    const [chat] = await db
      .insert(chats)
      .values({
        spaceId: null,
        type: "private",
        // for debug
        title,
        spacePublic: false,
        date: new Date(),
        threadNumber: null,
        minUserId,
        maxUserId,
      })
      .onConflictDoUpdate({
        target: [chats.minUserId, chats.maxUserId],
        set: { title },
      })
      .returning()

    if (chat == undefined) {
      throw new InlineError(ErrorCodes.SERVER_ERROR, "Failed to create private chat")
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
    return { chat: encodeChatInfo(chat) }
  } catch (error) {
    Log.shared.error("Failed to create private chat", error)
    throw new InlineError(ErrorCodes.SERVER_ERROR, "Failed to create private chat")
  }
}
