import { db } from "@in/server/db"
import { loginCodes } from "@in/server/db/schema/loginCodes"
import { and, eq, gte, lt } from "drizzle-orm"
import { sessions, users, type DbNewSession } from "@in/server/db/schema"
import { isValidEmail, validateIanaTimezone, validateUpToFourSegementSemver } from "@in/server/utils/validate"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { normalizeEmail } from "@in/server/utils/normalize"
import { Log } from "@in/server/utils/log"
import { generateToken, MAX_LOGIN_ATTEMPTS } from "@in/server/utils/auth"
import { Optional, type Static, Type } from "@sinclair/typebox"
import type { UnauthenticatedHandlerContext } from "@in/server/controllers/helpers"
import { encodeUserInfo, TUserInfo } from "@in/server/api-types"
import { ipinfo, type IPInfoResponse } from "@in/server/libs/ipinfo"
import { SessionsModel } from "@in/server/db/models/sessions"
import { sendBotEvent } from "@in/server/modules/bot-events"

export const Input = Type.Object({
  email: Type.String(),
  code: Type.String(),
  deviceId: Type.Optional(Type.String()),

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
  if (input.code === "") {
    throw new InlineError(InlineError.ApiError.EMAIL_CODE_EMPTY)
  }

  if (input.code.length < 6) {
    throw new InlineError(InlineError.ApiError.EMAIL_CODE_INVALID)
  }

  if (isValidEmail(input.email) === false) {
    throw new InlineError(InlineError.ApiError.EMAIL_INVALID)
  }

  let email = normalizeEmail(input.email)

  // add random delay to limit bruteforce
  await new Promise((resolve) => setTimeout(resolve, Math.random() * 1000))

  // send code to email
  await verifyCode(email, input.code)

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
  let clientType = input.clientType ?? undefined
  let clientVersion = validateUpToFourSegementSemver(input.clientVersion ?? "")
    ? input.clientVersion ?? undefined
    : undefined
  let osVersion = validateUpToFourSegementSemver(input.osVersion ?? "") ? input.osVersion ?? undefined : undefined

  // create or fetch user by email
  let user = await getUserByEmail(email)

  if (!user) {
    throw new InlineError(InlineError.ApiError.INTERNAL)
  }

  let userId = user.id

  // save session
  // store sha256 of token in db
  let { token, tokenHash } = await generateToken(userId)

  let _ = await SessionsModel.create({
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

  return { userId: userId, token: token, user: encodeUserInfo(user) }
}

/// HELPER FUNCTIONS ///

const verifyCode = async (email: string, code: string): Promise<true> => {
  if (email && code && email === process.env["DEMO_EMAIL"] && code === process.env["DEMO_CODE"]) {
    sendTelegramEventForDemoAccount()
    return true
  }

  let existingCode = (
    await db
      .select()
      .from(loginCodes)
      .where(
        and(
          eq(loginCodes.email, email),
          gte(loginCodes.expiresAt, new Date()),
          lt(loginCodes.attempts, MAX_LOGIN_ATTEMPTS),
        ),
      )
      .limit(1)
  )[0]

  if (!existingCode) {
    throw new Error("Invalid code. Try again.")
  }

  if (existingCode.code !== code) {
    await db
      .update(loginCodes)
      .set({
        attempts: (existingCode.attempts ?? 0) + 1,
      })
      .where(eq(loginCodes.id, existingCode.id))

    throw new Error("Invalid code")
  } else {
    // delete and return token
    await db.delete(loginCodes).where(eq(loginCodes.id, existingCode.id))

    // success!!!
    return true
  }
}

const getUserByEmail = async (email: string) => {
  let user = (await db.select().from(users).where(eq(users.email, email)).limit(1))[0]

  if (!user) {
    // create user
    let user = (
      await db
        .insert(users)
        .values({
          email,
          emailVerified: true,

          // For now. ideally it should switch when user sets name
          pendingSetup: false,
        })
        .returning()
    )[0]

    sendTelegramEvent(email)

    return user
  } else {
    try {
      // update pending setup to false
      await db.update(users).set({ pendingSetup: false }).where(eq(users.email, email))
    } catch (error) {
      Log.shared.error("Failed to update pending setup to false", error)
    }
  }

  return user
}

function sendTelegramEvent(email: string) {
  sendBotEvent(`New user verified email: \n${email}\n\n🍓🫡☕️`)
}

function sendTelegramEventForDemoAccount() {
  sendBotEvent(`🤐 Someone logged in with demo account`)
}
