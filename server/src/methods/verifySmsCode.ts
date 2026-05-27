import { validateIanaTimezone, validateUpToFourSegementSemver } from "@in/server/utils/validate"
import { InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { Type } from "@sinclair/typebox"
import type { Static } from "elysia"
import type { UnauthenticatedHandlerContext } from "@in/server/controllers/helpers"
import { db } from "@in/server/db"
import { eq } from "drizzle-orm"
import { users } from "@in/server/db/schema"
import { encodeUserInfo, TUserInfo } from "@in/server/api-types"
import { type IPInfoResponse } from "@in/server/libs/ipinfo"
import { generateToken } from "@in/server/utils/auth"
import { SessionsModel } from "@in/server/db/models/sessions"
import parsePhoneNumber from "libphonenumber-js"
import { prelude } from "@in/server/libs/prelude"
import { sendBotEvent } from "@in/server/modules/bot-events"
import { maskPhoneNumber } from "@in/server/utils/privacy"
import { BotAlerts } from "@in/server/modules/bot-events/alerts"
import { getOrCreateUserByPhoneForSignup } from "@in/server/modules/auth/signupInvites"

export const Input = Type.Object({
  phoneNumber: Type.String(),
  code: Type.String(),
  inviteCode: Type.Optional(Type.String()),
  deviceId: Type.Optional(Type.String()),

  // optional
  clientType: Type.Optional(
    Type.Union([Type.Literal("ios"), Type.Literal("macos"), Type.Literal("web"), Type.Literal("cli")]),
  ),
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
    // if (isValidPhoneNumber(input.phoneNumber) === false) {
    //   throw new InlineError(InlineError.ApiError.PHONE_INVALID)
    // }

    // parse phone number
    const phoneNumber = parsePhoneNumber(input.phoneNumber)
    if (!phoneNumber?.isValid()) {
      throw new InlineError(InlineError.ApiError.PHONE_INVALID)
    }

    if (!input.deviceId) {
      Log.shared.warn("Missing deviceId on verifySmsCode", {
        clientType: input.clientType,
        clientVersion: input.clientVersion,
        osVersion: input.osVersion,
      })
    }

    let formattedPhoneNumber = phoneNumber.number

    // send sms code
    let response = await prelude.checkCode(formattedPhoneNumber, input.code)

    if (response?.status !== "success") {
      throw new InlineError(InlineError.ApiError.SMS_CODE_INVALID)
    }

    // Formatted in E.164 format. It's important to use this format for phone numbers.
    // Otherwise, we'll endup with duplicates.
    // const phoneNumber = response.to

    // make session
    //    let ipInfo = requestIp ? await ipinfo(requestIp) : undefined
    // Note(@mo): diable  for now it's so slow and adds false negatives
    let ipInfo = undefined as IPInfoResponse | undefined
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

    // create or fetch user by phone
    let { user, created } = await getOrCreateUserByPhoneForSignup(formattedPhoneNumber, input.inviteCode)

    if (!user) {
      Log.shared.error("Failed to verify sms code", { phoneNumber })
      throw new InlineError(InlineError.ApiError.INTERNAL)
    }

    let userId = user.id

    // save session
    let { token, tokenHash } = await generateToken(userId)

    const session = await SessionsModel.create({
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
      deviceId: input.deviceId ?? undefined,
    })

    // Best-effort internal alert (should never affect the user action).
    BotAlerts.login({
      userId,
      device: {
        deviceName: session.personalData.deviceName,
        deviceId: session.deviceId,
        clientType: session.clientType,
        clientVersion: session.clientVersion,
        osVersion: session.osVersion,
      },
    })

    if (created) {
      sendTelegramEvent(formattedPhoneNumber)
    }

    return { userId: userId, token: token, user: encodeUserInfo(user) }
  } catch (error) {
    if (error instanceof InlineError) {
      throw error
    }

    Log.shared.error("Failed to verify sms code", error)
    throw new InlineError(InlineError.ApiError.INTERNAL)
  }
}

function sendTelegramEvent(phoneNumber: string) {
  sendBotEvent(`New user verified phone: \n${maskPhoneNumber(phoneNumber)}\n\n🍓🫡☕️`)
}
