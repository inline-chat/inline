import { eq } from "drizzle-orm"
import parsePhoneNumber from "libphonenumber-js"
import { db } from "@in/server/db"
import { users } from "@in/server/db/schema"
import { DEMO_CODE, DEMO_CODE2, DEMO_EMAIL, DEMO_EMAIL2 } from "@in/server/env"
import { prelude } from "@in/server/libs/prelude"
import { verifyEmailLoginChallenge } from "@in/server/modules/auth/emailLoginChallenges"
import {
  getOrCreateUserByEmailForSignup,
  getOrCreateUserByPhoneForSignup,
} from "@in/server/modules/auth/signupInvites"
import { InlineError } from "@in/server/types/errors"
import { normalizeEmail } from "@in/server/utils/normalize"
import { isValidEmail } from "@in/server/utils/validate"

export async function verifyEmailAccountProof(input: {
  email: string
  code: string
  challengeToken?: string
  inviteCode?: string
}) {
  if (input.code.length < 6) throw new InlineError(InlineError.ApiError.EMAIL_CODE_INVALID)
  const email = normalizeEmail(input.email)
  if (!isValidEmail(email)) throw new InlineError(InlineError.ApiError.EMAIL_INVALID)
  await new Promise((resolve) => setTimeout(resolve, Math.random() * 1_000))
  const demo = (email === DEMO_EMAIL && input.code === DEMO_CODE) ||
    (email === DEMO_EMAIL2 && input.code === DEMO_CODE2)
  if (!demo && !await verifyEmailLoginChallenge({
    email,
    code: input.code,
    challengeToken: input.challengeToken,
  })) {
    throw new InlineError(InlineError.ApiError.EMAIL_CODE_INVALID)
  }
  const { user, created } = await getOrCreateUserByEmailForSignup(email, input.inviteCode)
  if (!user) throw new InlineError(InlineError.ApiError.INTERNAL)
  return { user, created, identifier: email, method: "email" as const }
}

export async function verifyPhoneAccountProof(input: {
  phoneNumber: string
  code: string
  inviteCode?: string
}) {
  const parsed = parsePhoneNumber(input.phoneNumber)
  if (!parsed?.isValid()) throw new InlineError(InlineError.ApiError.PHONE_INVALID)
  const phoneNumber = parsed.number
  const response = await prelude.checkCode(phoneNumber, input.code)
  if (response?.status !== "success") throw new InlineError(InlineError.ApiError.SMS_CODE_INVALID)
  const { user, created } = await getOrCreateUserByPhoneForSignup(phoneNumber, input.inviteCode)
  if (!user) throw new InlineError(InlineError.ApiError.INTERNAL)
  return { user, created, identifier: phoneNumber, method: "phone" as const }
}

export async function findUserForConfirmedContact(
  contact: { method: "email" | "phone"; identifier: string },
) {
  const predicate = contact.method === "email"
    ? eq(users.email, contact.identifier)
    : eq(users.phoneNumber, contact.identifier)
  return (await db.select().from(users).where(predicate).limit(1))[0]
}
