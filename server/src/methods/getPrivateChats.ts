import { db } from "@in/server/db"
import { and, eq, not, or } from "drizzle-orm"
import { chats, spaces, users } from "@in/server/db/schema"
import { InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { type Static, Type } from "@sinclair/typebox"
import type { HandlerContext } from "@in/server/controllers/v1/helpers"
import { normalizeId, TInputId } from "@in/server/types/methods"
import { Authorize } from "@in/server/utils/authorize"
import { encodeChatInfo, TChatInfo } from "../models"

export const Input = Type.Object({})

export const Response = Type.Object({
  chats: Type.Array(TChatInfo),
})

export const handler = async (
  input: Static<typeof Input>,
  context: HandlerContext,
): Promise<Static<typeof Response>> => {
  const hasSelfChat = await db
    .select()
    .from(chats)
    .where(
      and(
        eq(chats.type, "private"),
        eq(chats.minUserId, context.currentUserId),
        eq(chats.maxUserId, context.currentUserId),
      ),
    )

  if (!hasSelfChat) {
    await db.insert(chats).values({
      type: "private",
      date: new Date(),
      minUserId: context.currentUserId,
      maxUserId: context.currentUserId,
      title: "Saved Messages",
    })
  }

  const result = await db
    .select()
    .from(chats)
    .where(
      and(
        eq(chats.type, "private"),
        or(eq(chats.minUserId, context.currentUserId), eq(chats.maxUserId, context.currentUserId)),
      ),
    )

  const encoded = result.map((r) => encodeChatInfo(r, { currentUserId: context.currentUserId }))

  return { chats: encoded }
}
