import { db } from "@in/server/db"
import { loginCodes } from "@in/server/db/schema/loginCodes"
import { and, eq, gte, lt } from "drizzle-orm"
import { sessions, users, type DbNewSession } from "@in/server/db/schema"
import { isValidEmail, validateIanaTimezone, validateUpToFourSegementSemver } from "@in/server/utils/validate"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { normalizeEmail } from "@in/server/utils/normalize"
import { Log } from "@in/server/utils/log"
import { generateToken, MAX_LOGIN_ATTEMPTS } from "@in/server/utils/auth"
import { type Static, Type } from "@sinclair/typebox"
import type { UnauthenticatedHandlerContext } from "@in/server/controllers/v1/helpers"
import { encodeUserInfo, TUserInfo } from "@in/server/models"
import { ipinfo } from "@in/server/libs/ipinfo"

export const Input = Type.Object({
  email: Type.String(),
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
    if (isValidEmail(input.email) === false) {
      throw new InlineError(ErrorCodes.INAVLID_ARGS, "Invalid email")
    }

    let email = normalizeEmail(input.email)

    // add random delay to limit bruteforce
    await new Promise((resolve) => setTimeout(resolve, Math.random() * 1000))

    // send code to email
    await verifyCode(email, input.code)

    // make session
    let ipInfo = requestIp ? await ipinfo(requestIp) : undefined
    let ip = requestIp ?? null
    let country = ipInfo?.country ?? null
    let region = ipInfo?.region ?? null
    let city = ipInfo?.city ?? null
    let timezone = validateIanaTimezone(input.timezone ?? "") ? input.timezone ?? null : ipInfo?.timezone ?? null
    let clientType = input.clientType ?? null
    let clientVersion = validateUpToFourSegementSemver(input.clientVersion ?? "") ? input.clientVersion ?? null : null
    let osVersion = validateUpToFourSegementSemver(input.osVersion ?? "") ? input.osVersion ?? null : null

    // create or fetch user by email
    let user = await getUserByEmail(email)
    let userId = user.id

    // save session
    let { token } = await createSession({
      userId,
      ip,
      country,
      region,
      city,
      timezone,
      clientType,
      clientVersion: clientVersion ?? null,
      osVersion: osVersion ?? null,
      deviceName: input.deviceName ?? null,
    })

    return { userId: userId, token: token, user: encodeUserInfo(user) }
  } catch (error) {
    Log.shared.error("Failed to send email code", error)
    throw new InlineError(ErrorCodes.SERVER_ERROR, "Failed to send email code")
  }
}

/// HELPER FUNCTIONS ///

const verifyCode = async (email: string, code: string): Promise<true> => {
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

    // success!!
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
          // pending setup
        })
        .returning()
    )[0]

    return user
  }

  return user
}

export const createSession = async ({
  userId,
  ...session
}: {
  userId: number
} & Omit<DbNewSession, "tokenHash">): Promise<{ token: string }> => {
  // store sha256 of token in db
  let { token, tokenHash } = await generateToken(userId)

  // store session
  await db.insert(sessions).values({
    userId,
    ...session,
    tokenHash,
    date: new Date(),
  })

  return { token }
}
