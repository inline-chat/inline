import { validateIanaTimezone, validateUpToFourSegementSemver } from "@in/server/utils/validate"
import { Log } from "@in/server/utils/log"
import { generateToken } from "@in/server/utils/auth"
import { type Static, Type } from "@sinclair/typebox"
import type { UnauthenticatedHandlerContext } from "@in/server/controllers/helpers"
import { encodeUserInfo, TUserInfo } from "@in/server/api-types"
import { type IPInfoResponse } from "@in/server/libs/ipinfo"
import { SessionsModel } from "@in/server/db/models/sessions"
import { sendBotEvent } from "@in/server/modules/bot-events"
import { maskEmail } from "@in/server/utils/privacy"
import { BotAlerts } from "@in/server/modules/bot-events/alerts"
import { isSignupComplete } from "@in/server/modules/auth/signupInvites"
import { normalizeAuthClientType } from "@in/server/modules/auth/clientType"
import { syncTimeZoneForElectedAppleSession } from "@in/server/modules/users/timeZoneSync"
import { verifyEmailAccountProof } from "@in/server/modules/auth/contactProof"

export const Input = Type.Object({
  email: Type.String(),
  code: Type.String(),
  challengeToken: Type.Optional(Type.String()),
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
  const requestIp = context.ip
  const clientType = normalizeAuthClientType(input.clientType, "verifyEmailCode")

  if (!input.deviceId) {
    Log.shared.warn("Missing deviceId on verifyEmailCode", {
      clientType,
      clientVersion: input.clientVersion,
      osVersion: input.osVersion,
    })
  }

  const proof = await verifyEmailAccountProof(input)
  const email = proof.identifier
  const confirmedUser = proof.user
  BotAlerts.authContactConfirmed({
    contact: { type: "email", value: email },
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

  // make session
  //let ipInfo = requestIp ? await ipinfo(requestIp) : undefined
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

  // create or fetch user by email
  let { user, created } = proof

  let userId = user.id

  // save session
  // store sha256 of token in db
  let { token, tokenHash } = await generateToken(userId)

  const session = await SessionsModel.create({
    userId,
    tokenHash,
    deviceId: input.deviceId ?? undefined,
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
    sendTelegramEvent(email)
  }

  return { userId: userId, token: token, user: encodeUserInfo(user) }
}

/// HELPER FUNCTIONS ///

function sendTelegramEvent(email: string) {
  sendBotEvent(`New user verified email: \n${maskEmail(email)}\n\n🍓🫡☕️`)
}
