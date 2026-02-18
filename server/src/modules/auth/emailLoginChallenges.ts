import { db } from "@in/server/db"
import { loginCodes, type DbLoginCode } from "@in/server/db/schema/loginCodes"
import {
  and,
  desc,
  eq,
  gte,
  inArray,
  lt,
} from "drizzle-orm"
import {
  generateLoginChallengeId,
  hashLoginCode,
  MAX_LOGIN_ATTEMPTS,
  secureRandomSixDigitNumber,
  verifyLoginCode,
} from "@in/server/utils/auth"

export const EMAIL_LOGIN_CHALLENGE_TTL_MS = 1000 * 60 * 10
const MAX_ACTIVE_EMAIL_LOGIN_CHALLENGES = 5
const LEGACY_VERIFY_LOOKBACK_LIMIT = 8

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

async function getVerificationCandidates(input: {
  email: string
  challengeToken?: string | null
  maxAttempts?: number
}): Promise<LoginCodeCandidate[]> {
  const maxAttempts = input.maxAttempts ?? MAX_LOGIN_ATTEMPTS
  const baseConditions = and(
    eq(loginCodes.email, input.email),
    gte(loginCodes.expiresAt, new Date()),
    lt(loginCodes.attempts, maxAttempts),
  )

  if (input.challengeToken) {
    const challengeRow = (
      await db
        .select({
          id: loginCodes.id,
          attempts: loginCodes.attempts,
          code: loginCodes.code,
          codeHash: loginCodes.codeHash,
        })
        .from(loginCodes)
        .where(and(baseConditions, eq(loginCodes.challengeId, input.challengeToken)))
        .orderBy(desc(loginCodes.date), desc(loginCodes.id))
        .limit(1)
    )[0]

    return challengeRow ? [challengeRow] : []
  }

  // TEMPORARY backward compatibility for older clients that still verify with only email+code.
  // Remove this no-token fallback after 2026-05-18 and require challengeToken for email OTP verify.
  return db
    .select({
      id: loginCodes.id,
      attempts: loginCodes.attempts,
      code: loginCodes.code,
      codeHash: loginCodes.codeHash,
    })
    .from(loginCodes)
    .where(baseConditions)
    .orderBy(desc(loginCodes.date), desc(loginCodes.id))
    .limit(LEGACY_VERIFY_LOOKBACK_LIMIT)
}

async function matchesCode(candidate: LoginCodeCandidate, code: string): Promise<boolean> {
  if (candidate.codeHash) {
    return verifyLoginCode(code, candidate.codeHash)
  }

  return candidate.code === code
}

async function incrementAttempts(candidate: LoginCodeCandidate): Promise<void> {
  await db
    .update(loginCodes)
    .set({
      attempts: (candidate.attempts ?? 0) + 1,
    })
    .where(eq(loginCodes.id, candidate.id))
}

export async function verifyEmailLoginChallenge(input: {
  email: string
  code: string
  challengeToken?: string | null
  maxAttempts?: number
}): Promise<boolean> {
  const candidates = await getVerificationCandidates(input)

  if (candidates.length === 0) {
    return false
  }

  if (input.challengeToken) {
    const candidate = candidates[0]
    if (!candidate) return false

    const matches = await matchesCode(candidate, input.code)
    if (!matches) {
      await incrementAttempts(candidate)
      return false
    }

    await db.delete(loginCodes).where(eq(loginCodes.id, candidate.id))
    return true
  }

  // Legacy no-token verification path (temporary; see removal date above).
  for (const candidate of candidates) {
    const matched = await matchesCode(candidate, input.code)
    if (!matched) continue

    await db.delete(loginCodes).where(eq(loginCodes.id, candidate.id))
    return true
  }

  const latestCandidate = candidates[0]
  if (latestCandidate) {
    await incrementAttempts(latestCandidate)
  }

  return false
}
