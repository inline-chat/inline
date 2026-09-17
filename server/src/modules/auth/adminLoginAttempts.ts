import { db } from "@in/server/db"
import { superadminUsers, type DbSuperadminUser } from "@in/server/db/schema/superadminUsers"
import type { Transaction } from "@in/server/db/types"
import { eq, sql } from "drizzle-orm"

const MAX_ATTEMPTS = 5
const LOCK_MS = 15 * 60_000
const RESET_MS = 24 * 60 * 60_000

export async function recordAdminLoginFailure(id: number, now = new Date()): Promise<Date | null> {
  const next = sql<number>`case when ${superadminUsers.lastLoginAttemptAt} < ${new Date(now.getTime() - RESET_MS).toISOString()}::timestamp
    then 1 else ${superadminUsers.failedLoginAttempts} + 1 end`
  const [row] = await db.update(superadminUsers).set({
    failedLoginAttempts: next,
    lastLoginAttemptAt: now,
    loginLockedUntil: sql`case
      when ${superadminUsers.loginLockedUntil} > ${now.toISOString()}::timestamp then ${superadminUsers.loginLockedUntil}
      when ${next} >= ${MAX_ATTEMPTS} then ${new Date(now.getTime() + LOCK_MS).toISOString()}::timestamp
      else null end`,
  }).where(eq(superadminUsers.id, id)).returning({ lockedUntil: superadminUsers.loginLockedUntil })
  if (!row) throw new Error("Admin account no longer exists")
  return row.lockedUntil
}

/** Recheck authority after expensive verification; session and success reset commit together. */
export async function completeAdminPasswordLogin<T>(
  verified: DbSuperadminUser,
  createSession: (tx: Transaction) => Promise<T>,
  now = new Date(),
): Promise<T | undefined> {
  return db.transaction(async (tx) => {
    const [current] = await tx.select().from(superadminUsers)
      .where(eq(superadminUsers.id, verified.id)).for("update")
    if (!current || current.disabledAt || (current.loginLockedUntil && current.loginLockedUntil > now) ||
      current.passwordHash !== verified.passwordHash ||
      current.totpEnabledAt?.getTime() !== verified.totpEnabledAt?.getTime() ||
      !sameBytes(current.totpSecretEncrypted, verified.totpSecretEncrypted) ||
      !sameBytes(current.totpSecretIv, verified.totpSecretIv) || !sameBytes(current.totpSecretTag, verified.totpSecretTag)) return undefined
    await tx.update(superadminUsers).set({
      failedLoginAttempts: 0, loginLockedUntil: null, lastLoginAttemptAt: now,
    }).where(eq(superadminUsers.id, verified.id))
    return createSession(tx)
  })
}

const sameBytes = (a: Buffer | null, b: Buffer | null): boolean =>
  a === null || b === null ? a === b : a.equals(b)
