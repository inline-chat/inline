import { type Static, Type } from "@sinclair/typebox"
import type { HandlerContext } from "@in/server/controllers/helpers"
import { SessionsModel } from "@in/server/db/models/sessions"

export const Input = Type.Object({
  applePushToken: Type.String(),
})

export const Response = Type.Undefined()

export const handler = async (
  input: Static<typeof Input>,
  context: HandlerContext,
): Promise<Static<typeof Response>> => {
  await SessionsModel.updateApplePushToken(context.currentSessionId, input.applePushToken)
  return undefined
}
