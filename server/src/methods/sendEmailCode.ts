import { db } from "@in/server/db"
import { loginCodes } from "@in/server/db/schema/loginCodes"
import { and, eq, gte, lt } from "drizzle-orm"
import { users } from "@in/server/db/schema"
import { isValidEmail } from "@in/server/utils/validate"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { normalizeEmail } from "@in/server/utils/normalize"
import { Log } from "@in/server/utils/log"
import { MAX_LOGIN_ATTEMPTS, secureRandomSixDigitNumber } from "@in/server/utils/auth"
import { Type } from "@sinclair/typebox"
import type { Static } from "elysia"
import type { UnauthenticatedHandlerContext } from "@in/server/controllers/helpers"
import { isProd } from "@in/server/env"
import { sendEmail } from "@in/server/utils/email"

export const Input = Type.Object({
  email: Type.String(),
})

export const Response = Type.Object({
  existingUser: Type.Boolean(),
})

export const handler = async (
  input: Static<typeof Input>,
  _: UnauthenticatedHandlerContext,
): Promise<Static<typeof Response>> => {
  try {
    if (isValidEmail(input.email) === false) {
      throw new InlineError(InlineError.ApiError.EMAIL_INVALID)
    }

    let email = normalizeEmail(input.email)

    // store code
    let { code, existingUser, firstName } = await getLoginCode(email)

    // send code to email
    await sendEmailCode(email, code, firstName)

    return { existingUser }
  } catch (error) {
    Log.shared.error("Failed to send email code", error)
    throw new InlineError(InlineError.ApiError.INTERNAL)
  }
}

/// HELPER FUNCTIONS ///
const getLoginCode = async (
  email: string,
): Promise<{ code: string; existingUser: boolean; firstName: string | undefined }> => {
  // if there is one that isn't yet expired, ensure we return the same code.
  // To avoid a denial of service attack if the attacker keeps triggering
  // new codes preventing user from logging in

  let existingUsers = await db.select().from(users).where(eq(users.email, email)).limit(1)
  let existingUser = Boolean(existingUsers[0])
  let firstName = existingUsers[0]?.firstName ?? undefined

  // check
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
  )?.[0]

  if (existingCode) {
    return { code: existingCode.code, existingUser, firstName }
  }

  // generate
  let code = secureRandomSixDigitNumber().toString()

  // delete all prev attempts
  await db.delete(loginCodes).where(eq(loginCodes.email, email))

  await db.insert(loginCodes).values({
    code,
    email,
    expiresAt: new Date(Date.now() + 1000 * 60 * 10), // 10 minutes
    attempts: 0,
  })

  return { code, existingUser, firstName }
}

const sendEmailCode = async (email: string, code: string, firstName: string | undefined) => {
  await sendEmail({ to: email, content: { template: "code", variables: { code, firstName } } })
}
