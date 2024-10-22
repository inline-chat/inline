import { isValidPhoneNumber, validateUpToFourSegementSemver } from "@in/server/utils/validate"
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
import { encodeUserInfo, TUserInfo } from "@in/server/models"
import { ipinfo } from "@in/server/libs/ipinfo"

export const Input = Type.Object({
  phoneNumber: Type.String(),
  code: Type.String(),

  // optional
  clientType: Type.Optional(Type.Union([Type.Literal("ios"), Type.Literal("macos"), Type.Literal("web")])),
  clientVersion: Type.Optional(Type.String()),
  osVersion: Type.Optional(Type.String()),
  deviceName: Type.Optional(Type.String()),
  timezone: Type.Optional(Type.String()),
})

export const Response = Type.Object({
  userId: Type.Number(),
  token: Type.String(),
  user: TUserInfo,
})

export const handler = async (
  input: Static<typeof Input>,
  { ip: requestIp }: UnauthenticatedHandlerContext,
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

    // make session
    let ipInfo = requestIp ? await ipinfo(requestIp) : undefined
    let ip = requestIp ?? null
    let country = ipInfo?.country ?? null
    let region = ipInfo?.region ?? null
    let city = ipInfo?.city ?? null
    let timezone = input.timezone ?? ipInfo?.timezone ?? null
    let clientType = input.clientType ?? null
    let clientVersion = validateUpToFourSegementSemver(input.clientVersion ?? "") ? input.clientVersion ?? null : null
    let osVersion = validateUpToFourSegementSemver(input.osVersion ?? "") ? input.osVersion ?? null : null
    let deviceName = input.deviceName ?? null
    // create or fetch user by email
    let user = await getUserByPhoneNumber(phoneNumber)
    let userId = user.id

    // save session
    let { token } = await createSession({
      userId,
      country,
      region,
      city,
      timezone,
      ip,
      clientType,
      clientVersion,
      osVersion,
      deviceName,
    })

    return { userId: userId, token: token, user: encodeUserInfo(user) }
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