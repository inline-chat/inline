import { db } from "@in/server/db"
import type { Transaction } from "@in/server/db/types"
import { loginCodes, type DbLoginCode } from "@in/server/db/schema/loginCodes"
import { and, desc, eq, gte, inArray, lt, sql } from "drizzle-orm"
import {
  generateLoginChallengeId,
  hashLoginCode,
  MAX_LOGIN_ATTEMPTS,
  secureRandomSixDigitNumber,
  verifyLoginCode,
} from "@in/server/utils/auth"

export const EMAIL_LOGIN_CHALLENGE_TTL_MS = 1000 * 60 * 10
const MAX_ACTIVE_EMAIL_LOGIN_CHALLENGES = 5

type LoginCodeCandidate = Pick<DbLoginCode, "id" | "attempts" | "code" | "codeHash">

export async function issueEmailLoginChallenge(input: {
  email: string
  ttlMs?: number
}): Promise<{ code: string; challengeToken: string }> {
  const code = secureRandomSixDigitNumber().toString()
  const codeHash = await hashLoginCode(code)
  const challengeToken = generateLoginChallengeId()
  const ttlMs = input.ttlMs ?? EMAIL_LOGIN_CHALLENGE_TTL_MS

  await db.insert(loginCodes).values({
    email: input.email,
    code: null,
    codeHash,
    challengeId: challengeToken,
    expiresAt: new Date(Date.now() + ttlMs),
    attempts: 0,
  })

  await pruneActiveEmailChallenges(input.email)

  return { code, challengeToken }
}

async function pruneActiveEmailChallenges(email: string): Promise<void> {
  const activeRows = await db
    .select({ id: loginCodes.id })
    .from(loginCodes)
    .where(and(eq(loginCodes.email, email), gte(loginCodes.expiresAt, new Date())))
    .orderBy(desc(loginCodes.date), desc(loginCodes.id))

  const staleRows = activeRows.slice(MAX_ACTIVE_EMAIL_LOGIN_CHALLENGES)
  if (staleRows.length === 0) return

  await db.delete(loginCodes).where(inArray(loginCodes.id, staleRows.map((row) => row.id)))
}

// Reserve a guess before hashing. The conditional update serializes concurrent
// requests so they cannot all reuse the same remaining attempt.
async function claimVerificationAttempt(input: {
  email: string
  challengeToken?: string | null
  maxAttempts?: number
}): Promise<LoginCodeCandidate | undefined> {
  if (!input.challengeToken) return undefined
  return (await db.update(loginCodes)
    .set({ attempts: sql`coalesce(${loginCodes.attempts}, 0) + 1` })
    .where(and(
      eq(loginCodes.email, input.email),
      eq(loginCodes.challengeId, input.challengeToken),
      gte(loginCodes.expiresAt, new Date()),
      lt(sql`coalesce(${loginCodes.attempts}, 0)`, input.maxAttempts ?? MAX_LOGIN_ATTEMPTS),
    ))
    .returning({ id: loginCodes.id, attempts: loginCodes.attempts, code: loginCodes.code, codeHash: loginCodes.codeHash }))[0]
}

async function matchesCode(candidate: LoginCodeCandidate, code: string): Promise<boolean> {
  if (candidate.codeHash) {
    return verifyLoginCode(code, candidate.codeHash)
  }

  return candidate.code === code
}

export async function verifyEmailLoginChallenge(input: {
  email: string
  code: string
  challengeToken?: string | null
  maxAttempts?: number
}, completeInTransaction?: (tx: Transaction) => Promise<void>): Promise<boolean> {
  const candidate = await claimVerificationAttempt(input)
  if (!candidate || !await matchesCode(candidate, input.code)) return false

  // Correct proof does not spend the wrong-code budget when invite validation
  // fails. Consumption and account creation must then commit together.
  await db.update(loginCodes).set({ attempts: sql`${loginCodes.attempts} - 1` })
    .where(eq(loginCodes.id, candidate.id))
  return db.transaction(async (tx) => {
    const consumed = await tx.delete(loginCodes).where(and(
      eq(loginCodes.id, candidate.id),
      gte(loginCodes.expiresAt, new Date()),
    )).returning({ id: loginCodes.id })
    if (consumed.length !== 1) return false
    await completeInTransaction?.(tx)
    return true
  })
}
