import { isValidPhoneNumber } from "@in/server/utils/validate"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { Type } from "@sinclair/typebox"
import type { Static } from "elysia"
import type { UnauthenticatedHandlerContext } from "@in/server/controllers/helpers"
import { twilio } from "@in/server/libs/twilio"
import { db } from "@in/server/db"
import { eq } from "drizzle-orm"
import { users } from "@in/server/db/schema"
import { prelude } from "@in/server/libs/prelude"
import parsePhoneNumber from "libphonenumber-js"

export const Input = Type.Object({
  phoneNumber: Type.String(),
})

export const Response = Type.Object({
  existingUser: Type.Boolean(),
  phoneNumber: Type.String(),
  formattedPhoneNumber: Type.String(),
})

export const handler = async (
  input: Static<typeof Input>,
  _: UnauthenticatedHandlerContext,
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
    let response = await prelude.sendCode(formattedPhoneNumber)

    Log.shared.debug("sending sms code to", { phoneNumber: formattedPhoneNumber })

    let existingUser = await db._query.users.findFirst({
      where: eq(users.phoneNumber, formattedPhoneNumber),
      columns: {
        pendingSetup: true,
        id: true,
        phoneNumber: true,
      },
    })

    return {
      existingUser: existingUser ? existingUser.pendingSetup !== true : false,
      // pass back valid formatting for number
      phoneNumber: formattedPhoneNumber,
      // human readable phone number
      formattedPhoneNumber: phoneNumber.formatInternational(),
    }
  } catch (error) {
    Log.shared.error("Failed to send sms code", error)
    throw new InlineError(InlineError.ApiError.INTERNAL)
  }
}
