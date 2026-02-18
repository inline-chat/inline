import { db } from "@in/server/db"
import { eq } from "drizzle-orm"
import { users } from "@in/server/db/schema"
import { isValidEmail } from "@in/server/utils/validate"
import { InlineError } from "@in/server/types/errors"
import { normalizeEmail } from "@in/server/utils/normalize"
import { Log } from "@in/server/utils/log"
import { Type } from "@sinclair/typebox"
import type { Static } from "elysia"
import type { UnauthenticatedHandlerContext } from "@in/server/controllers/helpers"
import { sendEmail } from "@in/server/utils/email"
import { issueEmailLoginChallenge } from "@in/server/modules/auth/emailLoginChallenges"

export const Input = Type.Object({
  email: Type.String(),
})

export const Response = Type.Object({
  existingUser: Type.Boolean(),
  challengeToken: Type.Optional(Type.String()),
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

    let existingUsers = await db.select().from(users).where(eq(users.email, email)).limit(1)
    let existingUser = existingUsers[0] ? existingUsers[0].pendingSetup !== true : false
    let firstName = existingUsers[0]?.firstName ?? undefined

    // store challenge-scoped code
    const { code, challengeToken } = await issueEmailLoginChallenge({ email })

    await sendEmailCode(email, code, firstName, existingUser)

    return { existingUser, challengeToken }
  } catch (error) {
    Log.shared.error("Failed to send email code", error)
    throw new InlineError(InlineError.ApiError.INTERNAL)
  }
}

const sendEmailCode = async (email: string, code: string, firstName: string | undefined, existingUser: boolean) => {
  await sendEmail({
    to: email,
    content: {
      template: "code",
      variables: {
        code,
        firstName,
        isExistingUser: existingUser,
      },
    },
  })
}
