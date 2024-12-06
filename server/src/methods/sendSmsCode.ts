import { isValidPhoneNumber } from "@in/server/utils/validate"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { Type } from "@sinclair/typebox"
import type { Static } from "elysia"
import type { UnauthenticatedHandlerContext } from "@in/server/controllers/v1/helpers"
import { twilio } from "@in/server/libs/twilio"
import { db } from "@in/server/db"
import { eq } from "drizzle-orm"
import { users } from "@in/server/db/schema"

export const Input = Type.Object({
  phoneNumber: Type.String(),
})

export const Response = Type.Object({
  existingUser: Type.Boolean(),
  phoneNumber: Type.String(),
})

export const handler = async (
  input: Static<typeof Input>,
  _: UnauthenticatedHandlerContext,
): Promise<Static<typeof Response>> => {
  try {
    // verify formatting
    if (isValidPhoneNumber(input.phoneNumber) === false) {
      throw new InlineError(InlineError.ApiError.PHONE_INVALID)
    }

    // validate phone number via twilio lookups
    const lookup = await twilio.lookups.phoneNumbers(input.phoneNumber)
    if (lookup.valid === false) {
      throw new InlineError(InlineError.ApiError.PHONE_INVALID)
    }

    // lookup.phone_number is in E.164 format

    // send sms code
    let response = await twilio.verify.sendVerificationToken(lookup.phone_number, "sms")

    if (response?.status !== "pending") {
      throw new InlineError(InlineError.ApiError.INTERNAL)
    }

    Log.shared.debug("sending sms code to", { phoneNumber: lookup.phone_number })

    let existingUser = await db.query.users.findFirst({
      where: eq(users.phoneNumber, lookup.phone_number),
      columns: {
        id: true,
        phoneNumber: true,
      },
    })

    return {
      existingUser: !!existingUser,
      // pass back valid formatting for number
      phoneNumber: lookup.phone_number,
    }
  } catch (error) {
    Log.shared.error("Failed to send sms code", error)
    throw new InlineError(InlineError.ApiError.INTERNAL)
  }
}
