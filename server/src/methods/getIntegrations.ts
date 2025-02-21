import { db } from "@in/server/db"
import { eq } from "drizzle-orm"
import { integrations } from "@in/server/db/schema"
import { type Static, Type } from "@sinclair/typebox"
import { TInputId } from "@in/server/types/methods"
import { InlineError } from "../types/errors"

export const Input = Type.Object({
  userId: TInputId,
})

type Input = Static<typeof Input>

type Context = {
  currentUserId: number
}

export const Response = Type.Object({
  hasLinearConnected: Type.Boolean(),
})

type Response = Static<typeof Response>

export const handler = async (input: Input, context: Context): Promise<Response> => {
  let userId = Number(input.userId)
  if (isNaN(userId)) {
    throw new InlineError(InlineError.ApiError.BAD_REQUEST)
  }

  const integrationsList = await db.select().from(integrations).where(eq(integrations.userId, userId))

  return {
    hasLinearConnected: integrationsList.some((integration) => integration.provider === "linear"),
  }
}
