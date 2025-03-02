import { db } from "@in/server/db"
import { eq } from "drizzle-orm"
import { sessions } from "@in/server/db/schema"
import { InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { type Static, Type } from "@sinclair/typebox"
import type { HandlerContext } from "@in/server/controllers/helpers"
import { connectionManager } from "../ws/connections"

export const Input = Type.Object({})

export const Response = Type.Undefined()

export const handler = async (
  input: Static<typeof Input>,
  context: HandlerContext,
): Promise<Static<typeof Response>> => {
  try {
    await db.delete(sessions).where(eq(sessions.id, context.currentSessionId))

    setTimeout(() => {
      connectionManager.sessionLoggedOut(context.currentUserId, context.currentSessionId)
    }, 50)

    return undefined
  } catch (error) {
    Log.shared.error("Failed to logout", error)
    throw new InlineError(InlineError.ApiError.INTERNAL)
  }
}
