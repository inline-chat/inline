import { Type, type Static } from "@sinclair/typebox"
import type { HandlerContext } from "@in/server/controllers/helpers"
import { Authorize } from "@in/server/utils/authorize"
import { disconnectSpaceConnectorCredentials } from "@in/server/functions/connectors"
import { InlineError } from "@in/server/types/errors"

export const Input = Type.Object({
  spaceId: Type.Number(),
  provider: Type.Union([Type.Literal("notion"), Type.Literal("linear")]),
})

export const Response = Type.Object({
  ok: Type.Boolean(),
})

export const handler = async (
  input: Static<typeof Input>,
  context: HandlerContext,
): Promise<Static<typeof Response>> => {
  const spaceId = Number(input.spaceId)
  await Authorize.spaceAdmin(spaceId, context.currentUserId)
  try {
    await disconnectSpaceConnectorCredentials(input.provider, {
      userId: context.currentUserId,
      spaceId,
    })
  } catch (cause) {
    throw new InlineError(InlineError.ApiError.INTERNAL, { cause })
  }

  return { ok: true }
}
