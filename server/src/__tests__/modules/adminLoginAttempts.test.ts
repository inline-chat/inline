import { describe, expect, it } from "bun:test"
import { eq } from "drizzle-orm"
import { db } from "@in/server/db"
import { superadminUsers } from "@in/server/db/schema/superadminUsers"
import { completeAdminPasswordLogin, recordAdminLoginFailure } from "@in/server/modules/auth/adminLoginAttempts"
import { setupTestLifecycle } from "../database"

describe("admin login concurrency", () => {
  setupTestLifecycle()
  const account = async () => {
    const [row] = await db.insert(superadminUsers).values({ email: "admin@example.test", passwordHash: "verified-hash" }).returning()
    return row!
  }

  it("counts concurrent failures without losing increments or extending the first lock", async () => {
    const admin = await account()
    const now = new Date()
    await Promise.all(Array.from({ length: 20 }, () => recordAdminLoginFailure(admin.id, now)))
    const [row] = await db.select().from(superadminUsers).where(eq(superadminUsers.id, admin.id))
    expect(row!.failedLoginAttempts).toBe(20)
    expect(row!.loginLockedUntil?.getTime()).toBe(now.getTime() + 15 * 60_000)
    let created = false
    expect(await completeAdminPasswordLogin(admin, async () => { created = true; return "session" }, now)).toBeUndefined()
    expect(created).toBe(false)
  })

  it("resets an expired window atomically, and rolls back a failed session creation", async () => {
    const admin = await account()
    const now = new Date()
    await db.update(superadminUsers).set({ failedLoginAttempts: 4, lastLoginAttemptAt: new Date(now.getTime() - 25 * 60 * 60_000) })
      .where(eq(superadminUsers.id, admin.id))
    await Promise.all([recordAdminLoginFailure(admin.id, now), recordAdminLoginFailure(admin.id, now)])
    await expect(completeAdminPasswordLogin(admin, async () => { throw new Error("session failed") }, now)).rejects.toThrow("session failed")
    const [row] = await db.select().from(superadminUsers).where(eq(superadminUsers.id, admin.id))
    expect(row!.failedLoginAttempts).toBe(2)
    expect(row!.loginLockedUntil).toBeNull()
    expect(await completeAdminPasswordLogin(admin, async () => "session", now)).toBe("session")
    const [reset] = await db.select().from(superadminUsers).where(eq(superadminUsers.id, admin.id))
    expect(reset!.failedLoginAttempts).toBe(0)
  })

  it("rejects an account disabled or whose password changed during verification", async () => {
    const admin = await account()
    await db.update(superadminUsers).set({ passwordHash: "new-hash" }).where(eq(superadminUsers.id, admin.id))
    expect(await completeAdminPasswordLogin(admin, async () => "session")).toBeUndefined()
    await db.update(superadminUsers).set({ passwordHash: admin.passwordHash, disabledAt: new Date() }).where(eq(superadminUsers.id, admin.id))
    expect(await completeAdminPasswordLogin(admin, async () => "session")).toBeUndefined()
  })

  it("preserves a failure arriving while a successful login holds the account lock", async () => {
    const admin = await account()
    await recordAdminLoginFailure(admin.id)
    let acquired!: () => void
    let release!: () => void
    const locked = new Promise<void>((resolve) => { acquired = resolve })
    const unblock = new Promise<void>((resolve) => { release = resolve })
    const success = completeAdminPasswordLogin(admin, async () => {
      acquired()
      await unblock
      return "session"
    })
    await locked
    let failureFinished = false
    const failure = recordAdminLoginFailure(admin.id).then(() => { failureFinished = true })
    try {
      await Bun.sleep(20)
      expect(failureFinished).toBe(false)
    } finally {
      release()
    }
    expect(await success).toBe("session")
    await failure
    const [row] = await db.select().from(superadminUsers).where(eq(superadminUsers.id, admin.id))
    expect(row!.failedLoginAttempts).toBe(1)
    expect(row!.loginLockedUntil).toBeNull()
  })
})
