import { db } from "@in/server/db"
import { and, eq, not } from "drizzle-orm"
import { spaces, users } from "@in/server/db/schema"
import { InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { type Static, Type } from "@sinclair/typebox"
import type { HandlerContext } from "@in/server/controllers/helpers"
import { normalizeId, TInputId } from "@in/server/types/methods"
import { Authorize } from "@in/server/utils/authorize"

export const Input = Type.Object({
  spaceId: TInputId,
})

export const Response = Type.Undefined()

export const handler = async (
  input: Static<typeof Input>,
  context: HandlerContext,
): Promise<Static<typeof Response>> => {
  const spaceId = normalizeId(input.spaceId)

  // Authorize if user is creator of space
  await Authorize.spaceCreator(spaceId, context.currentUserId)

  // Delete space
  await deleteSpace(spaceId)

  // no payload on success
  return undefined
}

/// HELPER FUNCTIONS ///
const deleteSpace = async (spaceId: number) => {
  await db
    .update(spaces)
    .set({
      deleted: new Date(),
      // NOTE(@mo): clear name too?
    })
    .where(eq(spaces.id, spaceId))
}
