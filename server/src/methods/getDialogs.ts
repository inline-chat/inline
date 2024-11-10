import { db } from "@in/server/db"
import { and, eq, sql } from "drizzle-orm"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { type Static, Type } from "@sinclair/typebox"
import {
  encodeChatInfo,
  encodeDialogInfo,
  encodeMessageInfo,
  TChatInfo,
  TDialogInfo,
  TMessageInfo,
} from "@in/server/models"
import type { HandlerContext } from "@in/server/controllers/v1/helpers"
import * as schema from "@in/server/db/schema"

export const Input = Type.Object({
  spaceId: Type.Optional(Type.Integer()),
})

export const Response = Type.Object({
  dialogs: Type.Array(TDialogInfo),
  chats: Type.Array(TChatInfo),

  /** Last messages for each dialog */
  messages: Type.Array(TMessageInfo),

  /** Users that are senders of last messages */
  // users: Type.Array(TUserInfo),

  // TODO: Pagination
})

export const handler = async (
  input: Static<typeof Input>,
  context: HandlerContext,
): Promise<Static<typeof Response>> => {
  const spaceId = input?.spaceId ?? null
  const currentUserId = context.currentUserId

  const dialogs = await db.query.dialogs.findMany({
    where: and(eq(schema.dialogs.userId, currentUserId), eq(schema.dialogs.spaceId, spaceId ?? sql`null`)),
    with: { chat: { with: { lastMsg: true } } },
  })

  try {
    return {
      dialogs: dialogs.map(encodeDialogInfo),
      chats: dialogs.map((d) => encodeChatInfo(d.chat, { currentUserId })),
      messages: dialogs
        .map((d) => (d.chat?.lastMsg ? encodeMessageInfo(d.chat?.lastMsg, { currentUserId }) : null))
        .filter(Boolean) as TMessageInfo[],
      // users: [],
    }
  } catch (error) {
    Log.shared.error("Failed to get dialogs", error)
    throw new InlineError(InlineError.ApiError.INTERNAL)
  }
}
