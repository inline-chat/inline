import { type Static, Type } from "@sinclair/typebox"
import type { HandlerContext } from "@in/server/controllers/helpers"
import { updatePushNotificationDetails } from "@in/server/functions/user.updatePushNotificationDetails"

export const Input = Type.Object({
  applePushToken: Type.String(),
})

export const Response = Type.Undefined()

export const handler = async (
  input: Static<typeof Input>,
  context: HandlerContext,
): Promise<Static<typeof Response>> => {
  await updatePushNotificationDetails(
    {
      applePushToken: input.applePushToken,
    },
    {
      currentSessionId: context.currentSessionId,
      currentUserId: context.currentUserId,
    },
  )
  return undefined
}
