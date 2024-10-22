import { db } from "@in/server/db"
import { loginCodes } from "@in/server/db/schema/loginCodes"
import { and, eq, gte, lt } from "drizzle-orm"
import { sessions, users } from "@in/server/db/schema"
import { isValidEmail } from "@in/server/utils/validate"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { normalizeEmail } from "@in/server/utils/normalize"
import { Log } from "@in/server/utils/log"
import { generateToken, MAX_LOGIN_ATTEMPTS } from "@in/server/utils/auth"
import { type Static, Type } from "@sinclair/typebox"
import type { UnauthenticatedHandlerContext } from "@in/server/controllers/v1/helpers"

export const Input = Type.Object({
  email: Type.String(),
  code: Type.String(),
})

type Output = {
  userId: number
  token: string
}

export const Response = Type.Object({
  userId: Type.Number(),
  token: Type.String(),
})

export const encode = (output: Output): Static<typeof Response> => {
  return { userId: output.userId, token: output.token }
}

export const handler = async (
  input: Static<typeof Input>,
  _: UnauthenticatedHandlerContext,
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
    // let ip = server?.requestIP(request)?.address
    // let userAgent = query.userAgent
    // let timeZone = query.timeZone

    // create or fetch user by email
    let user = await getUserByEmail(email)
    let userId = user.id

    // save session
    let { token } = await createSession({ userId })

    return {
      userId: userId,
      token,
    }
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
}: {
  userId: number
  // ip: string | undefined
  // userAgent: string | undefined
  // timeZone: string | undefined
}): Promise<{ token: string }> => {
  // store sha256 of token in db
  let { token, tokenHash } = await generateToken(userId)

  // store session
  await db.insert(sessions).values({
    userId,
    tokenHash,
    date: new Date(),
    // userAgent,
    // timeZone,
    // ip,
  })

  return { token }
}
