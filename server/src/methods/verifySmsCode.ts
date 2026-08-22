import { validateIanaTimezone, validateUpToFourSegementSemver } from "@in/server/utils/validate"
import { InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { Type } from "@sinclair/typebox"
import type { Static } from "elysia"
import type { UnauthenticatedHandlerContext } from "@in/server/controllers/helpers"
import { encodeUserInfo, TUserInfo } from "@in/server/api-types"
import { type IPInfoResponse } from "@in/server/libs/ipinfo"
import { generateToken } from "@in/server/utils/auth"
import { SessionsModel } from "@in/server/db/models/sessions"
import { sendBotEvent } from "@in/server/modules/bot-events"
import { maskPhoneNumber } from "@in/server/utils/privacy"
import { BotAlerts } from "@in/server/modules/bot-events/alerts"
import { isSignupComplete } from "@in/server/modules/auth/signupInvites"
import { normalizeAuthClientType } from "@in/server/modules/auth/clientType"
import { syncTimeZoneForElectedAppleSession } from "@in/server/modules/users/timeZoneSync"
import { verifyPhoneAccountProof } from "@in/server/modules/auth/contactProof"

export const Input = Type.Object({
  phoneNumber: Type.String(),
  code: Type.String(),
  inviteCode: Type.Optional(Type.String()),
  deviceId: Type.Optional(Type.String()),

  // optional
  clientType: Type.Optional(Type.String()),
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
  context: UnauthenticatedHandlerContext,
): Promise<Static<typeof Response>> => {
  try {
    const requestIp = context.ip
    const clientType = normalizeAuthClientType(input.clientType, "verifySmsCode")

    if (!input.deviceId) {
      Log.shared.warn("Missing deviceId on verifySmsCode", {
        clientType,
        clientVersion: input.clientVersion,
        osVersion: input.osVersion,
      })
    }

    const proof = await verifyPhoneAccountProof(input)
    const formattedPhoneNumber = proof.identifier

    // Record contact proof before account/session mutation so a missing later checkpoint locates where the flow stopped.
    const confirmedUser = proof.created ? undefined : proof.user
    BotAlerts.authContactConfirmed({
      contact: { type: "phone", value: formattedPhoneNumber },
      user: confirmedUser,
      source: context.source,
      ip: requestIp,
      device: {
        deviceName: input.deviceName,
        deviceId: input.deviceId,
        clientType,
        clientVersion: input.clientVersion,
        osVersion: input.osVersion,
      },
    })

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
    let clientVersion = validateUpToFourSegementSemver(input.clientVersion ?? "")
      ? input.clientVersion ?? undefined
      : undefined
    let osVersion = validateUpToFourSegementSemver(input.osVersion ?? "") ? input.osVersion ?? undefined : undefined

    // create or fetch user by phone
    let { user, created } = proof

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

    if (timezone) {
      user =
        (await syncTimeZoneForElectedAppleSession({
          userId,
          sessionId: session.id,
          timeZone: timezone,
        })) ?? user
    }

    // New users are reported only after onboarding has saved their final profile.
    if (isSignupComplete(user)) {
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
    }

    if (created) {
      sendTelegramEvent(formattedPhoneNumber)
    }

    return { userId: userId, token: token, user: encodeUserInfo(user) }
  } catch (error) {
    if (error instanceof InlineError) {
      throw error
    }

    throw new InlineError(
      InlineError.ApiError.INTERNAL,
      { cause: error },
    )
  }
}

function sendTelegramEvent(phoneNumber: string) {
  sendBotEvent(`New user verified phone: \n${maskPhoneNumber(phoneNumber)}\n\n🍓🫡☕️`)
}
