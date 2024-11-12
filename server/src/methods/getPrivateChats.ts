import { db } from "@in/server/db"
import { and, eq, not, or } from "drizzle-orm"
import { chats, dialogs, spaces, users } from "@in/server/db/schema"
import { InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { type Static, Type } from "@sinclair/typebox"
import type { HandlerContext } from "@in/server/controllers/v1/helpers"
import { normalizeId, TInputId } from "@in/server/types/methods"
import { Authorize } from "@in/server/utils/authorize"
import { encodeChatInfo, encodeDialogInfo, TChatInfo, TDialogInfo } from "../models"

export const Input = Type.Object({})

export const Response = Type.Object({
  chats: Type.Array(TChatInfo),
  dialogs: Type.Array(TDialogInfo),
})

export const handler = async (
  input: Static<typeof Input>,
  context: HandlerContext,
): Promise<Static<typeof Response>> => {
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

  const result = await db
    .select()
    .from(chats)
    .where(and(eq(chats.type, "private"), or(eq(chats.minUserId, currentUserId), eq(chats.maxUserId, currentUserId))))
    .leftJoin(dialogs, eq(chats.id, dialogs.chatId))

  const chatsEncoded = result.map((c) => encodeChatInfo(c.chats, { currentUserId }))
  const dialogsEncoded = result.flatMap((c) => (c.dialogs ? [encodeDialogInfo(c.dialogs)] : []))
  return {
    chats: chatsEncoded,
    dialogs: dialogsEncoded,
  }
}
