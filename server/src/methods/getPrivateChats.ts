import { db } from "@in/server/db"
import { and, eq, inArray, not, or } from "drizzle-orm"
import { chats, dialogs, spaces, users } from "@in/server/db/schema"
import { InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { type Static, Type } from "@sinclair/typebox"
import type { HandlerContext } from "@in/server/controllers/v1/helpers"
import { Authorize } from "@in/server/utils/authorize"
import { encodeChatInfo, encodeDialogInfo, encodeUserInfo, TChatInfo, TDialogInfo, TUserInfo } from "../models"

export const Input = Type.Object({})

export const Response = Type.Object({
  chats: Type.Array(TChatInfo),
  dialogs: Type.Array(TDialogInfo),
  peerUsers: Type.Array(TUserInfo),
})

export const handler = async (_: Static<typeof Input>, context: HandlerContext): Promise<Static<typeof Response>> => {
  const currentUserId = context.currentUserId

  const selfChatInfo = await db
    .select()
    .from(chats)
    .where(and(eq(chats.type, "private"), eq(chats.minUserId, currentUserId), eq(chats.maxUserId, currentUserId)))
    .leftJoin(dialogs, eq(chats.id, dialogs.chatId))
  let selfChat = selfChatInfo[0]?.chats
  let selfChatDialog = selfChatInfo[0]?.dialogs

  // -------------------------------------------------------------------------------------------------------------------
  // Recover from issues with self chat
  if (!selfChat) {
    const [newSelfChat] = await db
      .insert(chats)
      .values({
        type: "private",
        date: new Date(),
        minUserId: currentUserId,
        maxUserId: currentUserId,
        title: "Saved Messages",
      })
      .returning()
    selfChat = newSelfChat
  }
  if (!selfChatDialog && selfChat) {
    const [newSelfChatDialog] = await db
      .insert(dialogs)
      .values({
        chatId: selfChat.id,
        userId: currentUserId,
      })
      .returning()
    selfChatDialog = newSelfChatDialog
  }

  // -------------------------------------------------------------------------------------------------------------------
  // Get all private chats
  const result = await db.query.chats.findMany({
    where: and(eq(chats.type, "private"), or(eq(chats.minUserId, currentUserId), eq(chats.maxUserId, currentUserId))),
    with: {
      dialogs: true,
    },
  })
  const peerUsers = await db
    .select()
    .from(users)
    .where(
      inArray(
        users.id,
        [...new Set([...result.map((c) => c.minUserId), ...result.map((c) => c.maxUserId)])].filter(
          (id): id is number => id != null,
        ),
      ),
    )

  const chatsEncoded = [selfChat ?? null, ...result]
    .filter((c) => c != null)
    .map((c) => encodeChatInfo(c, { currentUserId }))
  const dialogsEncoded = result.flatMap((c) =>
    [selfChatDialog ?? null, ...c.dialogs].filter((d) => d != null).map((d) => encodeDialogInfo(d)),
  )
  const peerUsersEncoded = peerUsers.map((u) => encodeUserInfo(u))

  return {
    chats: chatsEncoded,
    dialogs: dialogsEncoded,
    peerUsers: peerUsersEncoded,
  }
}
