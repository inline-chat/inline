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
import { createSession } from "@in/server/methods/verifyEmailCode"

export const Input = Type.Object({
  phoneNumber: Type.String(),
  code: Type.String(),
})

export const Response = Type.Object({
  userId: Type.Number(),
  token: Type.String(),
})

export const handler = async (
  input: Static<typeof Input>,
  _: UnauthenticatedHandlerContext,
): Promise<Static<typeof Response>> => {
  try {
    // verify formatting
    if (isValidPhoneNumber(input.phoneNumber) === false) {
      throw new InlineError(ErrorCodes.INAVLID_ARGS, "Invalid phone number format")
    }

    // send sms code
    let response = await twilio.verify.checkVerificationToken(input.phoneNumber, input.code)

    if (response?.status !== "approved" || response?.valid === false || !response.to) {
      throw new InlineError(ErrorCodes.SERVER_ERROR, "Failed to send sms code")
    }

    // Formatted in E.164 format. It's important to use this format for phone numbers.
    // Otherwise, we'll endup with duplicates.
    const phoneNumber = response.to

    // create or fetch user by email
    let user = await getUserByPhoneNumber(phoneNumber)
    let userId = user.id

    // save session
    let { token } = await createSession({ userId })

    return {
      userId: userId,
      token,
    }
  } catch (error) {
    Log.shared.error("Failed to verify sms code", error)
    throw new InlineError(ErrorCodes.SERVER_ERROR, "Failed to verify sms code")
  }
}

/// helpers

const getUserByPhoneNumber = async (phoneNumber: string) => {
  let user = (await db.select().from(users).where(eq(users.phoneNumber, phoneNumber)).limit(1))[0]

  if (!user) {
    // create user
    let user = (
      await db
        .insert(users)
        .values({
          phoneNumber,
          phoneVerified: true,
        })
        .returning()
    )[0]

    return user
  }

  return user
}
