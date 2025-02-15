import { db } from "@in/server/db"
import { and, eq, or } from "drizzle-orm"
import { dialogs, users } from "@in/server/db/schema"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { Optional, type Static, Type } from "@sinclair/typebox"
import type { HandlerContext } from "@in/server/controllers/helpers"
import { encodeUserInfo, TUserInfo } from "../api-types"
import { TInputId } from "@in/server/types/methods"

export const Input = Type.Object({
  peerUserId: Optional(TInputId),
})

export const Response = Type.Object({
  draft: Type.String(),
})

export const handler = async (
  input: Static<typeof Input>,
  context: HandlerContext,
): Promise<Static<typeof Response>> => {
  try {
    const peerUserId = input.peerUserId ? Number(input.peerUserId) : undefined
    if (peerUserId === undefined) {
      throw new InlineError(InlineError.ApiError.PEER_INVALID)
    }
    const result = await db
      .select()
      .from(dialogs)
      .where(and(eq(dialogs.peerUserId, peerUserId), eq(dialogs.userId, context.currentUserId)))

    return { draft: result[0]?.draft ?? "" }
  } catch (error) {
    Log.shared.error("Failed to get draft", error)
    throw new InlineError(InlineError.ApiError.INTERNAL)
  }
}
