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

  const hasSelfChat = await db
    .select()
    .from(chats)
    .where(and(eq(chats.type, "private"), eq(chats.minUserId, currentUserId), eq(chats.maxUserId, currentUserId)))

  if (!hasSelfChat) {
    await db.insert(chats).values({
      type: "private",
      date: new Date(),
      minUserId: currentUserId,
      maxUserId: currentUserId,
      title: "Saved Messages",
    })
  }

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
  console.log("getPrivateChats result", result)
  const chatsEncoded = result.map((c) => encodeChatInfo(c, { currentUserId }))
  const dialogsEncoded = result.flatMap((c) => c.dialogs.map((d) => encodeDialogInfo(d)))
  const peerUsersEncoded = peerUsers.map((u) => encodeUserInfo(u))

  console.log("getPrivateChats chatsEncoded", chatsEncoded)
  console.log("getPrivateChats dialogsEncoded", dialogsEncoded)
  console.log("getPrivateChats peerUsersEncoded", peerUsersEncoded)

  return {
    chats: chatsEncoded,
    dialogs: dialogsEncoded,
    peerUsers: peerUsersEncoded,
  }
}
