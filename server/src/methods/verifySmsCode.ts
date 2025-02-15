import { isValidPhoneNumber, validateIanaTimezone, validateUpToFourSegementSemver } from "@in/server/utils/validate"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { Type } from "@sinclair/typebox"
import type { Static } from "elysia"
import type { UnauthenticatedHandlerContext } from "@in/server/controllers/helpers"
import { twilio } from "@in/server/libs/twilio"
import { db } from "@in/server/db"
import { eq } from "drizzle-orm"
import { users } from "@in/server/db/schema"
import { encodeUserInfo, TUserInfo } from "@in/server/api-types"
import { ipinfo } from "@in/server/libs/ipinfo"
import { generateToken } from "@in/server/utils/auth"
import { SessionsModel } from "@in/server/db/models/sessions"

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
      throw new InlineError(InlineError.ApiError.PHONE_INVALID)
    }

    // send sms code
    let response = await twilio.verify.checkVerificationToken(input.phoneNumber, input.code)

    if (response?.status !== "approved" || response?.valid === false || !response.to) {
      throw new InlineError(InlineError.ApiError.SMS_CODE_INVALID)
    }

    // Formatted in E.164 format. It's important to use this format for phone numbers.
    // Otherwise, we'll endup with duplicates.
    const phoneNumber = response.to

    // make session
    let ipInfo = requestIp ? await ipinfo(requestIp) : undefined
    let ip = requestIp ?? undefined
    let country = ipInfo?.country ?? undefined
    let region = ipInfo?.region ?? undefined
    let city = ipInfo?.city ?? undefined
    let timezone = validateIanaTimezone(input.timezone ?? "")
      ? input.timezone ?? undefined
      : ipInfo?.timezone ?? undefined
    let clientType = input.clientType ?? undefined
    let clientVersion = validateUpToFourSegementSemver(input.clientVersion ?? "")
      ? input.clientVersion ?? undefined
      : undefined
    let osVersion = validateUpToFourSegementSemver(input.osVersion ?? "") ? input.osVersion ?? undefined : undefined

    // create or fetch user by email
    let user = await getUserByPhoneNumber(phoneNumber)

    if (!user) {
      Log.shared.error("Failed to verify sms code", { phoneNumber })
      throw new InlineError(InlineError.ApiError.INTERNAL)
    }

    let userId = user.id

    // save session
    let { token, tokenHash } = await generateToken(userId)

    let _ = await SessionsModel.create({
      userId,
      tokenHash,
      personalData: {
        country,
        region,
        city,
        timezone,
        deviceName: input.deviceName ?? undefined,
        ip,
      },
      clientType: clientType ?? "web",
      clientVersion: clientVersion ?? undefined,
      osVersion: osVersion ?? undefined,
    })

    return { userId: userId, token: token, user: encodeUserInfo(user) }
  } catch (error) {
    Log.shared.error("Failed to verify sms code", error)
    throw new InlineError(InlineError.ApiError.INTERNAL)
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
