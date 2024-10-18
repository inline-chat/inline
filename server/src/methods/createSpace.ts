import { db } from "@in/server/db"
import { spaces } from "@in/server/db/schema"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { type Static, t } from "elysia"

export const CreateSpaceInput = t.Object({
  name: t.String(),
  handle: t.Optional(t.String()),
})

type Input = Static<typeof CreateSpaceInput>

export const createSpace = async (input: Input) => {
  try {
    let space = await db
      .insert(spaces)
      .values({
        name: input.name,
        handle: input.handle ?? null,
      })
      .returning()

    return space[0]
  } catch (error) {
    Log.shared.error("Failed to create space", error)
    throw new InlineError(ErrorCodes.SERVER_ERROR, "Failed to create space")
  }
}
