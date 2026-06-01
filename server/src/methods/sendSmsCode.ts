import { InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { Type } from "@sinclair/typebox"
import type { Static } from "elysia"
import type { UnauthenticatedHandlerContext } from "@in/server/controllers/helpers"
import { db } from "@in/server/db"
import { eq } from "drizzle-orm"
import { users } from "@in/server/db/schema"
import { prelude } from "@in/server/libs/prelude"
import parsePhoneNumber from "libphonenumber-js"
import { isInviteCodeRequired } from "@in/server/modules/auth/signupInvites"
import { BotAlerts } from "@in/server/modules/bot-events/alerts"

export const Input = Type.Object({
  phoneNumber: Type.String(),
  deviceId: Type.Optional(Type.String()),
  clientType: Type.Optional(
    Type.Union([Type.Literal("ios"), Type.Literal("macos"), Type.Literal("web"), Type.Literal("cli")]),
  ),
  clientVersion: Type.Optional(Type.String()),
  osVersion: Type.Optional(Type.String()),
  deviceName: Type.Optional(Type.String()),
})

export const Response = Type.Object({
  existingUser: Type.Boolean(),
  needsInviteCode: Type.Boolean(),
  phoneNumber: Type.String(),
  formattedPhoneNumber: Type.String(),
})

export const handler = async (
  input: Static<typeof Input>,
  context: UnauthenticatedHandlerContext,
): Promise<Static<typeof Response>> => {
  try {
    // verify formatting
    // if (isValidPhoneNumber(input.phoneNumber) === false) {
    //   throw new InlineError(InlineError.ApiError.PHONE_INVALID)
    // }

    // parse phone number
    const phoneNumber = parsePhoneNumber(input.phoneNumber)
    if (!phoneNumber?.isValid()) {
      throw new InlineError(InlineError.ApiError.PHONE_INVALID)
    }

    let formattedPhoneNumber = phoneNumber.number

    // send sms code
    await prelude.sendCode(formattedPhoneNumber)

    Log.shared.debug("sending sms code to", { phoneNumber: formattedPhoneNumber })

    let existingUser = (await db.select().from(users).where(eq(users.phoneNumber, formattedPhoneNumber)).limit(1))[0]
    if (existingUser?.deleted === true) {
      throw new InlineError(InlineError.ApiError.USER_DEACTIVATED)
    }

    const needsInviteCode = await isInviteCodeRequired(existingUser)
    const isLogin = existingUser ? existingUser.pendingSetup !== true : false

    BotAlerts.authAttempt({
      kind: isLogin ? "login" : "signup",
      contact: { type: "phone", value: formattedPhoneNumber },
      existing: Boolean(existingUser),
      source: context.source,
      ip: context.ip,
      device: {
        deviceName: input.deviceName,
        deviceId: input.deviceId,
        clientType: input.clientType,
        clientVersion: input.clientVersion,
        osVersion: input.osVersion,
      },
      userId: existingUser?.id,
      needsInviteCode,
    })

    return {
      existingUser: isLogin,
      needsInviteCode,
      // pass back valid formatting for number
      phoneNumber: formattedPhoneNumber,
      // human readable phone number
      formattedPhoneNumber: phoneNumber.formatInternational(),
    }
  } catch (error) {
    if (error instanceof InlineError) {
      throw error
    }
    Log.shared.error("Failed to send sms code", error)
    throw new InlineError(InlineError.ApiError.INTERNAL)
  }
}
