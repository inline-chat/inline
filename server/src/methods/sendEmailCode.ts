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
import { isInviteCodeRequired } from "@in/server/modules/auth/signupInvites"
import { BotAlerts } from "@in/server/modules/bot-events/alerts"

export const Input = Type.Object({
  email: Type.String(),
  deviceId: Type.Optional(Type.String()),
  clientType: Type.Optional(
    Type.Union([Type.Literal("ios"), Type.Literal("macos"), Type.Literal("web"), Type.Literal("cli")]),
  ),
  clientVersion: Type.Optional(Type.String()),
  osVersion: Type.Optional(Type.String()),
  deviceName: Type.Optional(Type.String()),
})

export const Response = Type.Object({
  existingUser: Type.Boolean(),
  needsInviteCode: Type.Boolean(),
  challengeToken: Type.Optional(Type.String()),
})

export const handler = async (
  input: Static<typeof Input>,
  context: UnauthenticatedHandlerContext,
): Promise<Static<typeof Response>> => {
  try {
    if (isValidEmail(input.email) === false) {
      throw new InlineError(InlineError.ApiError.EMAIL_INVALID)
    }

    let email = normalizeEmail(input.email)

    let existingUsers = await db.select().from(users).where(eq(users.email, email)).limit(1)
    let user = existingUsers[0]
    if (user?.deleted === true) {
      throw new InlineError(InlineError.ApiError.USER_DEACTIVATED)
    }
    let existingUser = user ? user.pendingSetup !== true : false
    let needsInviteCode = await isInviteCodeRequired(user)
    let firstName = user?.firstName ?? undefined

    // store challenge-scoped code
    const { code, challengeToken } = await issueEmailLoginChallenge({ email })

    await sendEmailCode(email, code, firstName, existingUser)

    BotAlerts.authAttempt({
      kind: existingUser ? "login" : "signup",
      contact: { type: "email", value: email },
      existing: Boolean(user),
      source: context.source,
      ip: context.ip,
      device: {
        deviceName: input.deviceName,
        deviceId: input.deviceId,
        clientType: input.clientType,
        clientVersion: input.clientVersion,
        osVersion: input.osVersion,
      },
      userId: user?.id,
      needsInviteCode,
    })

    return { existingUser, needsInviteCode, challengeToken }
  } catch (error) {
    if (error instanceof InlineError) {
      throw error
    }
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
