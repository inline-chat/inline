import { Elysia, t } from "elysia"
import { setup } from "@in/server/setup"
import crypto from "crypto"

// todo: make a custom error code module

function secureRandomSixDigitNumber() {
  return crypto.randomInt(100000, 1000000)
}

const MAX_ATTEMPTS = 6

export const auth = new Elysia({ prefix: "auth" })

  .get(
    "/send-sms-code",
    async ({ query: { phone_number } }) => {
      // todo
      return await twilio.sendVerificationToken(phone_number, "sms")
    },
    {
      query: t.Object({
        phone_number: t.String(),
      }),
    },
  )
  .get(
    "/verify-sms-code",
    async ({ query: { code, phone_number } }) => {
      // todo
      return await twilio.checkVerificationToken(phone_number, code)
    },
    {
      query: t.Object({
        phone_number: t.String(),
        code: t.String(),
      }),
    },
  )
  .get(
    "/send-email-code",
    async ({ query }) => {
      if (isValidEmail(query.email) === false) {
        return {
          ok: false,
          errorCode: ErrorCodes.INAVLID_ARGS,
          description: "Invalid email",
        }
      }

      // store code
      let { code, existingUser } = await getLoginCode(query.email)

      // send code to email
      await sendEmail(query.email, code)

      return {
        ok: true,
        existingUser,
      }
    },
    {
      query: t.Object({
        email: t.String(),
      }),
    },
  )
  .get(
    "/verify-email-code",
    async ({ query, server, request }) => {
      // add random delay to limit bruteforce
      await new Promise((resolve) => setTimeout(resolve, Math.random() * 1000))

      if (isValidEmail(query.email) === false) {
        return {
          ok: false,
          errorCode: ErrorCodes.INAVLID_ARGS,
          description: "Invalid email",
        }
      }

      // send code to email
      await verifyEmailCode(query.email, query.code)

      // make session
      let ip = server?.requestIP(request)?.address
      let userAgent = query.userAgent
      let timeZone = query.timeZone

      // create or fetch user by email
      let user = await getUserByEmail(query.email)
      let userId = user.id

      // save session
      let { token } = await createSession({ userId, ip, userAgent, timeZone })

      return {
        ok: true,
        userId: String(userId),
        token,
      }
    },
    {
      query: t.Object({
        email: t.String(),
        code: t.String(),
        userAgent: t.Optional(t.String()),
        timeZone: t.Optional(t.String()),
      }),
    },
  )

// todo: extract
const todo = () => {}
import { db } from "@in/server/db"
import { loginCodes, DbNewLoginCode } from "@in/server/db/schema/loginCodes"
import { and, eq, gte, lt } from "drizzle-orm"
import { sessions, users } from "@in/server/db/schema"
import { twilio } from "@in/server/libs/twilio"
import { isValidEmail } from "@in/server/utils/validate"
import { ErrorCodes } from "@in/server/types/errors"

const getLoginCode = async (
  email: string,
): Promise<{ code: string; existingUser: boolean }> => {
  // if there is one that isn't yet expired, ensure we return the same code.
  // To avoid a denial of service attack if the attacker keeps triggering
  // new codes preventing user from logging in

  let existingUsers = await db
    .select()
    .from(users)
    .where(eq(users.email, email))
    .limit(1)
  let existingUser = Boolean(existingUsers[0])

  // check
  let existingCode = (
    await db
      .select()
      .from(loginCodes)
      .where(
        and(
          eq(loginCodes.email, email),
          gte(loginCodes.expiresAt, new Date()),
          lt(loginCodes.attempts, MAX_ATTEMPTS),
        ),
      )
      .limit(1)
  )?.[0]

  if (existingCode) {
    return { code: existingCode.code, existingUser }
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

  return { code, existingUser }
}

const sendEmail = async (email: string, code: string) => {
  console.log(`Sending email to ${email} with code ${code}`)
  // todo
}

const verifyEmailCode = async (email: string, code: string): Promise<true> => {
  let existingCode = (
    await db
      .select()
      .from(loginCodes)
      .where(
        and(
          eq(loginCodes.email, email),
          gte(loginCodes.expiresAt, new Date()),
          lt(loginCodes.attempts, MAX_ATTEMPTS),
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
  let user = (
    await db.select().from(users).where(eq(users.email, email)).limit(1)
  )[0]

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

const createSession = async ({
  userId,
  ip,
  userAgent,
  timeZone,
}: {
  userId: bigint
  ip: string | undefined
  userAgent: string | undefined
  timeZone: string | undefined
}): Promise<{ token: string }> => {
  // store sha256 of token in db
  let { token, tokenHash } = generateRandomSHA256()

  // store session
  let session = await db.insert(sessions).values({
    userId,
    tokenHash,
    // userAgent,
    // timeZone,
    // ip,
  })

  return { token }
}

function generateRandomSHA256() {
  // Generate 32 bytes of random data
  const token = crypto.randomBytes(32)

  // Create a SHA256 hash of the random bytes
  const hash = crypto.createHash("sha256")
  hash.update(token)

  // Return the hash as a hexadecimal string
  let tokenHash = hash.digest("hex")

  return { token: token.toString("hex"), tokenHash }
}
