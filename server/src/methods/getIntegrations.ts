import { eq } from "drizzle-orm"
import { db } from "@in/server/db"
import { integrations } from "@in/server/db/schema/integrations"
import { type Static, Type } from "@sinclair/typebox"
import { TInputId } from "@in/server/types/methods"

export const Input = Type.Object({
  userId: TInputId,
})

export const Response = Type.Object({
  hasLinearConnected: Type.Boolean(),
  hasNotionConnected: Type.Boolean(),
})

type Input = Static<typeof Input>
type Response = Static<typeof Response>

export const handler = async (input: Input): Promise<Response> => {
  let userId = Number(input.userId)
  if (isNaN(userId)) {
    throw new Error("Invalid userId")
  }

  const integrationsList = await db.select().from(integrations).where(eq(integrations.userId, userId))

  return {
    hasLinearConnected: integrationsList.some((integration) => integration.provider === "linear"),
    hasNotionConnected: integrationsList.some((integration) => integration.provider === "notion"),
  }
}
