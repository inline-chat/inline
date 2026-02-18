import { Elysia, t } from "elysia"
import type { Server } from "bun"
import os from "node:os"
import { and, eq, gte, isNull, lt, or, sql, desc } from "drizzle-orm"
import { setup } from "@in/server/setup"
import { db } from "@in/server/db"
import {
  chats,
  messages,
  sessions,
  superadminSessions,
  superadminUsers,
  users,
  waitlist,
  spaces,
  members,
} from "@in/server/db/schema"
import { isValidEmail } from "@in/server/utils/validate"
import { normalizeEmail } from "@in/server/utils/normalize"
import {
  generateToken,
  hashToken,
} from "@in/server/utils/auth"
import { sendEmail } from "@in/server/utils/email"
import { Log } from "@in/server/utils/log"
import { ADMIN_PUBLIC_API_ORIGIN, isProd } from "@in/server/env"
import { sendInlineOnlyBotEvent } from "@in/server/modules/bot-events"
import { encrypt, decrypt } from "@in/server/modules/encryption/encryption"
import { buildOtpAuthUrl, generateTotpSecret, verifyTotpCode } from "@in/server/utils/totp"
import { connectionManager } from "@in/server/ws/connections"
import { getErrorStats } from "@in/server/utils/metrics"
import { gitCommitHash, version } from "@in/server/buildEnv"
import { FILES_PATH_PREFIX } from "@in/server/modules/files/path"
import { getR2 } from "@in/server/libs/r2"
import { UsersModel } from "@in/server/db/models/users"
import { issueEmailLoginChallenge, verifyEmailLoginChallenge } from "@in/server/modules/auth/emailLoginChallenges"

const ADMIN_COOKIE_NAME = "inline_admin_session" as const
const ADMIN_IDLE_MS = 1000 * 60 * 60 * 24
const ADMIN_TTL_MS = 1000 * 60 * 60 * 24 * 3
const ADMIN_COOKIE_MAX_AGE = Math.floor(ADMIN_TTL_MS / 1000)
const ADMIN_PASSWORD_MIN_LENGTH = 12
const STEP_UP_WINDOW_MS = 1000 * 60 * 15
const ADMIN_LOGIN_MAX_ATTEMPTS = 5
const ADMIN_LOGIN_LOCK_MS = 1000 * 60 * 15
const ADMIN_LOGIN_RESET_MS = 1000 * 60 * 60 * 24
const ADMIN_LOGIN_IP_MAX_ATTEMPTS = 30
const ADMIN_LOGIN_IP_WINDOW_MS = 1000 * 60 * 15

const adminLoginIpAttempts = new Map<string, number[]>()

const recordAdminLoginAttempt = (ip: string) => {
  const now = Date.now()
  const attempts = adminLoginIpAttempts.get(ip) ?? []
  const nextAttempts = attempts.filter((timestamp) => timestamp >= now - ADMIN_LOGIN_IP_WINDOW_MS)
  nextAttempts.push(now)
  adminLoginIpAttempts.set(ip, nextAttempts)
  return nextAttempts.length
}

const isAdminIpLocked = (ip: string) => {
  const now = Date.now()
  const attempts = adminLoginIpAttempts.get(ip) ?? []
  const active = attempts.filter((timestamp) => timestamp >= now - ADMIN_LOGIN_IP_WINDOW_MS)
  adminLoginIpAttempts.set(ip, active)
  return active.length >= ADMIN_LOGIN_IP_MAX_ATTEMPTS
}

const clearAdminIpAttempts = (ip: string) => {
  adminLoginIpAttempts.delete(ip)
}
const ADMIN_ALLOWED_ORIGINS = new Set([
  "https://admin.inline.chat",
  "http://localhost:5174",
  "http://127.0.0.1:5174",
])
const ADMIN_TOTP_ISSUER = "Inline Admin"

const adminCookieSchema = t.Cookie({
  [ADMIN_COOKIE_NAME]: t.Optional(t.String()),
})

type AdminSessionContext = {
  sessionId: number
  userId: number
  email: string
  firstName: string | null
  lastName: string | null
  passwordSet: boolean
  totpEnabled: boolean
  stepUpAt: Date | null
}

type BunServer = Server<unknown>
type AdminSet = { status?: number | string }

type AdminCookieStore = {
  [ADMIN_COOKIE_NAME]: {
    value?: string
    set: (options: {
      value: string
      httpOnly?: boolean
      secure?: boolean
      sameSite?: "strict" | "lax" | "none"
      path?: string
      maxAge?: number
    }) => void
  }
}

export const admin = new Elysia({ name: "admin", prefix: "/admin" })
  .use(setup)
  .guard({
    beforeHandle: ({ request, set }) => {
      if (!isAllowedAdminOrigin(request)) {
        set.status = 403
        return { ok: false, error: "origin_not_allowed" }
      }
    },
  })
  .post(
    "/auth/send-email-code",
    async ({ body, cookie, request, server, set }) => {
      const existingSession = await getAdminSession(cookie as AdminCookieStore, request, server)
      if (existingSession) {
        set.status = 403
        return { ok: false, error: "already_signed_in" }
      }

      if (!isValidEmail(body.email)) {
        set.status = 400
        return { ok: false, error: "invalid_email" }
      }

      const email = normalizeEmail(body.email)
      const adminUser = await getSuperadminByEmail(email)
      if (!adminUser) {
        return { ok: true }
      }

      if (adminUser.passwordHash) {
        return { ok: true }
      }

      try {
        const challengeToken = await sendAdminLoginCode(email)
        return challengeToken ? { ok: true, challengeToken } : { ok: true }
      } catch (error) {
        Log.shared.error("Admin send email code failed", error)
        set.status = 500
        return { ok: false, error: "send_failed" }
      }
    },
    {
      body: t.Object({
        email: t.String(),
      }),
      cookie: adminCookieSchema,
    },
  )
  .post(
    "/auth/verify-email-code",
    async ({ body, cookie, request, server, set }) => {
      const existingSession = await getAdminSession(cookie as AdminCookieStore, request, server)
      if (existingSession) {
        set.status = 403
        return { ok: false, error: "already_signed_in" }
      }

      if (!isValidEmail(body.email)) {
        set.status = 400
        return { ok: false, error: "invalid_email" }
      }

      if (!body.code || body.code.length < 6) {
        set.status = 400
        return { ok: false, error: "invalid_code" }
      }

      const email = normalizeEmail(body.email)
      const adminUser = await getSuperadminByEmail(email)
      if (!adminUser) {
        set.status = 403
        return { ok: false, error: "not_allowed" }
      }

      if (adminUser.passwordHash) {
        set.status = 403
        return { ok: false, error: "password_required" }
      }

      try {
        await verifyAdminLoginCode(email, body.code, body.challengeToken)
      } catch {
        set.status = 401
        return { ok: false, error: "invalid_code" }
      }

      const user = await getOrCreateUserByEmail(email)
      if (!user) {
        set.status = 500
        return { ok: false, error: "user_missing" }
      }

      if (!adminUser.userId || adminUser.userId !== user.id) {
        await db.update(superadminUsers).set({ userId: user.id }).where(eq(superadminUsers.id, adminUser.id))
      }

      const ip = getRequestIp(request, server)
      const userAgent = request.headers.get("user-agent") ?? ""
      const { token } = await createAdminSession({ userId: user.id, ip, userAgent })

      const secure = isProd
      const adminCookie = cookie as AdminCookieStore
      adminCookie[ADMIN_COOKIE_NAME].set({
        value: token,
        httpOnly: true,
        secure,
        sameSite: "strict",
        path: "/",
        maxAge: ADMIN_COOKIE_MAX_AGE,
      })

      await notifyAdminAction({
        actionTaken: "Superadmin login (email code)",
        actorEmail: email,
        ip,
        userAgent,
      })

      return {
        ok: true,
        user: {
          id: user.id,
          email: user.email,
        },
      }
    },
    {
      body: t.Object({
        email: t.String(),
        code: t.String(),
        challengeToken: t.Optional(t.String()),
      }),
      cookie: adminCookieSchema,
    },
  )
  .post(
    "/auth/login",
    async ({ body, cookie, request, server, set }) => {
      if (!isValidEmail(body.email)) {
        set.status = 400
        return { ok: false, error: "invalid_email" }
      }

      const ip = getRequestIp(request, server) ?? "unknown"
      const email = normalizeEmail(body.email)
      const adminUser = await getSuperadminByEmail(email)
      if (!adminUser) {
        set.status = 403
        return { ok: false, error: "not_allowed" }
      }

      if (adminUser.disabledAt) {
        set.status = 403
        return { ok: false, error: "not_allowed" }
      }

      if (isAdminIpLocked(ip)) {
        set.status = 429
        return { ok: false, error: "login_locked" }
      }

      recordAdminLoginAttempt(ip)

      const now = new Date()
      if (adminUser.loginLockedUntil && adminUser.loginLockedUntil > now) {
        set.status = 429
        return { ok: false, error: "login_locked" }
      }

      let failedAttempts = adminUser.failedLoginAttempts

      if (
        adminUser.lastLoginAttemptAt &&
        now.getTime() - adminUser.lastLoginAttemptAt.getTime() > ADMIN_LOGIN_RESET_MS &&
        adminUser.failedLoginAttempts > 0
      ) {
        await db
          .update(superadminUsers)
          .set({ failedLoginAttempts: 0, loginLockedUntil: null, lastLoginAttemptAt: null })
          .where(eq(superadminUsers.id, adminUser.id))
        failedAttempts = 0
      }

      if (!adminUser.passwordHash) {
        set.status = 403
        return { ok: false, error: "password_not_set" }
      }

      const passwordValid = await Bun.password.verify(body.password ?? "", adminUser.passwordHash)
      if (!passwordValid) {
        const nextAttempts = failedAttempts + 1
        const lockedUntil =
          nextAttempts >= ADMIN_LOGIN_MAX_ATTEMPTS ? new Date(now.getTime() + ADMIN_LOGIN_LOCK_MS) : null

        await db
          .update(superadminUsers)
          .set({
            failedLoginAttempts: nextAttempts,
            lastLoginAttemptAt: now,
            loginLockedUntil: lockedUntil,
          })
          .where(eq(superadminUsers.id, adminUser.id))

        if (lockedUntil) {
          set.status = 429
          return { ok: false, error: "login_locked" }
        }

        set.status = 401
        return { ok: false, error: "invalid_credentials" }
      }

      const totpEnabled = Boolean(adminUser.totpEnabledAt)
      if (totpEnabled) {
        const secret = getTotpSecret(adminUser)
        if (!secret || !verifyTotpCode(secret, body.totpCode ?? "")) {
          const nextAttempts = failedAttempts + 1
          const lockedUntil =
            nextAttempts >= ADMIN_LOGIN_MAX_ATTEMPTS ? new Date(now.getTime() + ADMIN_LOGIN_LOCK_MS) : null

          await db
            .update(superadminUsers)
            .set({
              failedLoginAttempts: nextAttempts,
              lastLoginAttemptAt: now,
              loginLockedUntil: lockedUntil,
            })
            .where(eq(superadminUsers.id, adminUser.id))

          if (lockedUntil) {
            set.status = 429
            return { ok: false, error: "login_locked" }
          }

          set.status = 401
          return { ok: false, error: "invalid_totp" }
        }
        await db
          .update(superadminUsers)
          .set({ totpLastUsedAt: new Date() })
          .where(eq(superadminUsers.id, adminUser.id))
      }

      const user = adminUser.userId
        ? (await db.select().from(users).where(eq(users.id, adminUser.userId)).limit(1))[0]
        : await getOrCreateUserByEmail(email)

      if (!user) {
        set.status = 500
        return { ok: false, error: "user_missing" }
      }

      if (!adminUser.userId || adminUser.userId !== user.id) {
        await db.update(superadminUsers).set({ userId: user.id }).where(eq(superadminUsers.id, adminUser.id))
      }

      const userAgent = request.headers.get("user-agent") ?? ""
      const { token } = await createAdminSession({
        userId: user.id,
        ip,
        userAgent,
        stepUpAt: totpEnabled ? new Date() : null,
      })

      const secure = isProd
      const adminCookie = cookie as AdminCookieStore
      adminCookie[ADMIN_COOKIE_NAME].set({
        value: token,
        httpOnly: true,
        secure,
        sameSite: "strict",
        path: "/",
        maxAge: ADMIN_COOKIE_MAX_AGE,
      })

      await db
        .update(superadminUsers)
        .set({ failedLoginAttempts: 0, loginLockedUntil: null, lastLoginAttemptAt: now })
        .where(eq(superadminUsers.id, adminUser.id))

      clearAdminIpAttempts(ip)

      await notifyAdminAction({
        actionTaken: "Superadmin login (password)",
        actorEmail: email,
        ip,
        userAgent,
      })

      return { ok: true }
    },
    {
      body: t.Object({
        email: t.String(),
        password: t.String(),
        totpCode: t.Optional(t.String()),
      }),
      cookie: adminCookieSchema,
    },
  )
  .post(
    "/auth/set-password",
    async ({ body, cookie, request, server, set }) => {
      const session = await requireAdminSession(cookie as AdminCookieStore, request, server, set)
      if (!session) {
        return { ok: false, error: "unauthorized" }
      }

      const adminUser = await getSuperadminByUserId(session.userId)
      if (!adminUser) {
        set.status = 403
        return { ok: false, error: "not_allowed" }
      }

      if (adminUser.passwordHash) {
        set.status = 400
        return { ok: false, error: "password_already_set" }
      }

      if (!body.password || body.password.length < ADMIN_PASSWORD_MIN_LENGTH) {
        set.status = 400
        return { ok: false, error: "password_too_short" }
      }

      const passwordHash = await Bun.password.hash(body.password)
      await db
        .update(superadminUsers)
        .set({ passwordHash, passwordSetAt: new Date() })
        .where(eq(superadminUsers.id, adminUser.id))

      await notifyAdminAction({
        actionTaken: "Superadmin password set",
        actorEmail: session.email,
        ip: getRequestIp(request, server),
        userAgent: request.headers.get("user-agent") ?? "",
      })

      return { ok: true }
    },
    {
      body: t.Object({
        password: t.String(),
      }),
      cookie: adminCookieSchema,
    },
  )
  .get(
    "/auth/totp/setup",
    async ({ cookie, request, server, set }) => {
      const session = await requireAdminSession(cookie as AdminCookieStore, request, server, set)
      if (!session) {
        return { ok: false, error: "unauthorized" }
      }

      const adminUser = await getSuperadminByUserId(session.userId)
      if (!adminUser) {
        set.status = 403
        return { ok: false, error: "not_allowed" }
      }

      if (!adminUser.passwordHash) {
        set.status = 400
        return { ok: false, error: "password_required" }
      }

      if (adminUser.totpEnabledAt) {
        set.status = 400
        return { ok: false, error: "totp_already_enabled" }
      }

      const secret = generateTotpSecret()
      const encrypted = encrypt(secret)
      await db
        .update(superadminUsers)
        .set({
          totpSecretEncrypted: encrypted.encrypted,
          totpSecretIv: encrypted.iv,
          totpSecretTag: encrypted.authTag,
        })
        .where(eq(superadminUsers.id, adminUser.id))

      return {
        ok: true,
        secret,
        otpauthUrl: buildOtpAuthUrl(ADMIN_TOTP_ISSUER, session.email, secret),
      }
    },
    {
      cookie: adminCookieSchema,
    },
  )
  .post(
    "/auth/totp/verify",
    async ({ body, cookie, request, server, set }) => {
      const session = await requireAdminSession(cookie as AdminCookieStore, request, server, set)
      if (!session) {
        return { ok: false, error: "unauthorized" }
      }

      const adminUser = await getSuperadminByUserId(session.userId)
      if (!adminUser) {
        set.status = 403
        return { ok: false, error: "not_allowed" }
      }

      if (adminUser.totpEnabledAt) {
        set.status = 400
        return { ok: false, error: "totp_already_enabled" }
      }

      const secret = getTotpSecret(adminUser)
      if (!secret || !verifyTotpCode(secret, body.code ?? "")) {
        set.status = 400
        return { ok: false, error: "invalid_totp" }
      }

      await db
        .update(superadminUsers)
        .set({ totpEnabledAt: new Date(), totpLastUsedAt: new Date() })
        .where(eq(superadminUsers.id, adminUser.id))

      await notifyAdminAction({
        actionTaken: "Superadmin TOTP enabled",
        actorEmail: session.email,
        ip: getRequestIp(request, server),
        userAgent: request.headers.get("user-agent") ?? "",
      })

      return { ok: true }
    },
    {
      body: t.Object({
        code: t.String(),
      }),
      cookie: adminCookieSchema,
    },
  )
  .post(
    "/auth/step-up",
    async ({ body, cookie, request, server, set }) => {
      const session = await requireAdminSession(cookie as AdminCookieStore, request, server, set)
      if (!session) {
        return { ok: false, error: "unauthorized" }
      }

      const adminUser = await getSuperadminByUserId(session.userId)
      if (!adminUser || !adminUser.passwordHash) {
        set.status = 403
        return { ok: false, error: "not_allowed" }
      }

      if (!adminUser.totpEnabledAt) {
        set.status = 400
        return { ok: false, error: "totp_required" }
      }

      const passwordValid = await Bun.password.verify(body.password ?? "", adminUser.passwordHash)
      const secret = getTotpSecret(adminUser)
      const totpValid = secret ? verifyTotpCode(secret, body.totpCode ?? "") : false

      if (!passwordValid || !totpValid) {
        set.status = 401
        return { ok: false, error: "invalid_credentials" }
      }

      const now = new Date()
      await db
        .update(superadminSessions)
        .set({ stepUpAt: now })
        .where(eq(superadminSessions.id, session.sessionId))

      await db
        .update(superadminUsers)
        .set({ totpLastUsedAt: now })
        .where(eq(superadminUsers.id, adminUser.id))

      return { ok: true, stepUpAt: now.toISOString() }
    },
    {
      body: t.Object({
        password: t.String(),
        totpCode: t.String(),
      }),
      cookie: adminCookieSchema,
    },
  )
  .post(
    "/auth/logout",
    async ({ cookie, request, server, set }) => {
      const session = await getAdminSession(cookie as AdminCookieStore, request, server)
      if (!session) {
        set.status = 401
        return { ok: false, error: "unauthorized" }
      }

      await db
        .update(superadminSessions)
        .set({ revokedAt: new Date() })
        .where(eq(superadminSessions.id, session.sessionId))

      clearAdminCookie(cookie as AdminCookieStore)
      return { ok: true }
    },
    {
      cookie: adminCookieSchema,
    },
  )
  .get(
    "/me",
    async ({ cookie, request, server, set }) => {
      const session = await getAdminSession(cookie as AdminCookieStore, request, server)
      if (!session) {
        set.status = 401
        return { ok: false, error: "unauthorized" }
      }

      return {
        ok: true,
        user: {
          id: session.userId,
          email: session.email,
          firstName: session.firstName,
          lastName: session.lastName,
        },
        setup: {
          passwordSet: session.passwordSet,
          totpEnabled: session.totpEnabled,
        },
        session: {
          stepUpAt: session.stepUpAt ? session.stepUpAt.toISOString() : null,
        },
      }
    },
    {
      cookie: adminCookieSchema,
    },
  )
  .get(
    "/metrics/technical",
    async ({ cookie, request, server, set }) => {
      const session = await requireAdminSession(cookie as AdminCookieStore, request, server, set)
      if (!session) {
        return { ok: false, error: "unauthorized" }
      }

      if (!requireSetupComplete(session, set)) {
        return { ok: false, error: "setup_required" }
      }

      const memory = process.memoryUsage()
      const uptimeSeconds = process.uptime()
      const startedAt = new Date(Date.now() - uptimeSeconds * 1000)
      const errorStats = getErrorStats()

      const connectedToday = await countConnectedUsersToday()

      return {
        ok: true,
        metrics: {
          server: {
            version,
            gitCommit: gitCommitHash,
            startedAt: startedAt.toISOString(),
            uptimeSeconds,
            loadAverage: os.loadavg(),
          },
          memory: {
            rss: memory.rss,
            heapUsed: memory.heapUsed,
            heapTotal: memory.heapTotal,
          },
          connections: {
            total: connectionManager.getTotalConnections(),
            authenticated: connectionManager.getAuthenticatedConnectionCount(),
            authenticatedUsers: connectionManager.getAuthenticatedUserCount(),
            connectedToday,
          },
          errors: {
            last5m: errorStats.last5m,
            last15m: errorStats.last15m,
            total: errorStats.total,
          },
        },
      }
    },
    {
      cookie: adminCookieSchema,
    },
  )
  .get(
    "/metrics/app",
    async ({ cookie, request, server, set }) => {
      const session = await requireAdminSession(cookie as AdminCookieStore, request, server, set)
      if (!session) {
        return { ok: false, error: "unauthorized" }
      }

      if (!requireSetupComplete(session, set)) {
        return { ok: false, error: "setup_required" }
      }

      const metrics = await getAppMetrics()
      return { ok: true, metrics }
    },
    {
      cookie: adminCookieSchema,
    },
  )
  .get(
    "/metrics/overview",
    async ({ cookie, request, server, set }) => {
      const session = await requireAdminSession(cookie as AdminCookieStore, request, server, set)
      if (!session) {
        return { ok: false, error: "unauthorized" }
      }

      if (!requireSetupComplete(session, set)) {
        return { ok: false, error: "setup_required" }
      }

      const [appMetrics, errorStats, waitlistCountRow] = await Promise.all([
        getAppMetrics(),
        Promise.resolve(getErrorStats()),
        db
          .select({
            count: sql<number>`count(*)::int`,
          })
          .from(waitlist),
      ])

      return {
        ok: true,
        metrics: {
          dau: appMetrics.dau,
          wau: appMetrics.wau,
          messagesToday: appMetrics.messagesToday,
          mrr: 390,
          connections: {
            total: connectionManager.getTotalConnections(),
            authenticated: connectionManager.getAuthenticatedConnectionCount(),
          },
          errors: {
            last5m: errorStats.last5m,
          },
          waitlistCount: waitlistCountRow[0]?.count ?? 0,
        },
      }
    },
    {
      cookie: adminCookieSchema,
    },
  )
  .get(
    "/waitlist",
    async ({ query, cookie, request, server, set }) => {
      const session = await requireAdminSession(cookie as AdminCookieStore, request, server, set)
      if (!session) {
        return { ok: false, error: "unauthorized" }
      }

      if (!requireSetupComplete(session, set)) {
        return { ok: false, error: "setup_required" }
      }

      const search = query.query?.trim()
      const pattern = search ? `%${search}%` : null

      const whereClause = pattern
        ? or(sql`${waitlist.email} ILIKE ${pattern}`, sql`${waitlist.name} ILIKE ${pattern}`)
        : undefined

      const listQuery = whereClause
        ? db
            .select({
              id: waitlist.id,
              email: waitlist.email,
              name: waitlist.name,
              verified: waitlist.verified,
              date: waitlist.date,
            })
            .from(waitlist)
            .where(whereClause)
        : db
            .select({
              id: waitlist.id,
              email: waitlist.email,
              name: waitlist.name,
              verified: waitlist.verified,
              date: waitlist.date,
            })
            .from(waitlist)

      const countQuery = whereClause
        ? db
            .select({
              count: sql<number>`count(*)::int`.as("count"),
            })
            .from(waitlist)
            .where(whereClause)
        : db
            .select({
              count: sql<number>`count(*)::int`.as("count"),
            })
            .from(waitlist)

      const [rows, countRow] = await Promise.all([listQuery.orderBy(desc(waitlist.date)).limit(200), countQuery])

      return {
        ok: true,
        count: countRow[0]?.count ?? 0,
        entries: rows.map((row) => ({
          ...row,
          date: row.date ? row.date.toISOString() : null,
        })),
      }
    },
    {
      query: t.Object({
        query: t.Optional(t.String()),
      }),
      cookie: adminCookieSchema,
    },
  )
  .get(
    "/spaces",
    async ({ query, cookie, request, server, set }) => {
      const session = await requireAdminSession(cookie as AdminCookieStore, request, server, set)
      if (!session) {
        return { ok: false, error: "unauthorized" }
      }

      if (!requireSetupComplete(session, set)) {
        return { ok: false, error: "setup_required" }
      }

      const search = query.query?.trim()
      const pattern = search ? `%${search}%` : null

      const whereClause = pattern
        ? or(sql`${spaces.name} ILIKE ${pattern}`, sql`${spaces.handle} ILIKE ${pattern}`)
        : undefined

      const combinedWhere = whereClause ? and(isNull(spaces.deleted), whereClause) : isNull(spaces.deleted)

      const spaceQuery = db
        .select({
          id: spaces.id,
          name: spaces.name,
          handle: spaces.handle,
          createdAt: spaces.date,
          lastUpdateDate: spaces.lastUpdateDate,
          memberCount: sql<number>`count(${members.id})::int`,
        })
        .from(spaces)
        .leftJoin(members, eq(members.spaceId, spaces.id))
        .where(combinedWhere)
        .groupBy(spaces.id)

      const rows = await spaceQuery.orderBy(desc(sql`count(${members.id})`)).limit(200)

      return {
        ok: true,
        spaces: rows.map((row) => ({
          ...row,
          createdAt: row.createdAt ? row.createdAt.toISOString() : null,
          lastUpdateDate: row.lastUpdateDate ? row.lastUpdateDate.toISOString() : null,
        })),
      }
    },
    {
      query: t.Object({
        query: t.Optional(t.String()),
      }),
      cookie: adminCookieSchema,
    },
  )
  .get(
    "/users",
    async ({ query, cookie, request, server, set }) => {
      const session = await requireAdminSession(cookie as AdminCookieStore, request, server, set)
      if (!session) {
        return { ok: false, error: "unauthorized" }
      }

      if (!requireSetupComplete(session, set)) {
        return { ok: false, error: "setup_required" }
      }

      const search = query.query?.trim()
      const pattern = search ? `%${search}%` : null

      const whereClause = pattern
        ? or(
            sql`${users.email} ILIKE ${pattern}`,
            sql`${users.firstName} ILIKE ${pattern}`,
            sql`${users.lastName} ILIKE ${pattern}`,
            sql`${users.username} ILIKE ${pattern}`,
          )
        : undefined

      const queryBuilder = whereClause
        ? db
            .select({
              id: users.id,
              email: users.email,
              firstName: users.firstName,
              lastName: users.lastName,
              emailVerified: users.emailVerified,
              username: users.username,
              phoneNumber: users.phoneNumber,
              online: users.online,
              lastOnline: users.lastOnline,
              createdAt: users.date,
              deleted: users.deleted,
              bot: users.bot,
              photoFileId: users.photoFileId,
            })
            .from(users)
            .where(whereClause)
        : db
            .select({
              id: users.id,
              email: users.email,
              firstName: users.firstName,
              lastName: users.lastName,
              emailVerified: users.emailVerified,
              username: users.username,
              phoneNumber: users.phoneNumber,
              online: users.online,
              lastOnline: users.lastOnline,
              createdAt: users.date,
              deleted: users.deleted,
              bot: users.bot,
              photoFileId: users.photoFileId,
            })
            .from(users)

      const rows = await queryBuilder.orderBy(desc(users.id)).limit(50)

      const origin = ADMIN_PUBLIC_API_ORIGIN ?? new URL(request.url).origin
      const usersWithAvatars = rows.map((user) => ({
        ...user,
        lastOnline: user.lastOnline ? user.lastOnline.toISOString() : null,
        createdAt: user.createdAt ? user.createdAt.toISOString() : null,
        avatarUrl: user.photoFileId ? `${origin}/admin/users/${user.id}/avatar` : null,
      }))

      return { ok: true, users: usersWithAvatars }
    },
    {
      query: t.Object({
        query: t.Optional(t.String()),
      }),
      cookie: adminCookieSchema,
    },
  )
  .get(
    "/users/:id/avatar",
    async ({ params, cookie, request, server, set }) => {
      const session = await requireAdminSession(cookie as AdminCookieStore, request, server, set)
      if (!session) {
        return new Response(null, { status: 401 })
      }

      if (!requireSetupComplete(session, set)) {
        return new Response(null, { status: 403 })
      }

      const userId = Number(params.id)
      if (!Number.isFinite(userId)) {
        return new Response(null, { status: 400 })
      }

      const user = await UsersModel.getUserWithProfile(userId)
      const photoFile = user?.photoFile ?? null
      if (!photoFile || !photoFile.pathEncrypted || !photoFile.pathIv || !photoFile.pathTag) {
        return new Response(null, { status: 404 })
      }

      let path: string | null = null
      try {
        path = decrypt({
          encrypted: photoFile.pathEncrypted,
          iv: photoFile.pathIv,
          authTag: photoFile.pathTag,
        })
      } catch (err) {
        // Corrupt ciphertext/tag (or key mismatch) should not take down the admin handler.
        Log.shared.warn(`Failed to decrypt user avatar path for userId=${userId}`, err)
        return new Response(null, { status: 404 })
      }

      if (!path) {
        return new Response(null, { status: 404 })
      }

      const r2 = getR2()
      if (!r2) {
        return new Response(null, { status: 503 })
      }

      const file = r2.file(`${FILES_PATH_PREFIX}/${path}`)
      if (!(await file.exists())) {
        return new Response(null, { status: 404 })
      }

      const body = file.stream()
      const headers = new Headers()
      headers.set("content-type", photoFile.mimeType ?? "image/jpeg")
      headers.set("cache-control", "private, max-age=300")
      return new Response(body, { headers })
    },
    {
      params: t.Object({
        id: t.String(),
      }),
      cookie: adminCookieSchema,
    },
  )
  .get(
    "/users/:id",
    async ({ params, cookie, request, server, set }) => {
      const session = await requireAdminSession(cookie as AdminCookieStore, request, server, set)
      if (!session) {
        return { ok: false, error: "unauthorized" }
      }

      if (!requireSetupComplete(session, set)) {
        return { ok: false, error: "setup_required" }
      }

      const userId = Number(params.id)
      if (!Number.isFinite(userId)) {
        set.status = 400
        return { ok: false, error: "invalid_user" }
      }

      const user = (await db.select().from(users).where(eq(users.id, userId)).limit(1))[0]
      if (!user) {
        set.status = 404
        return { ok: false, error: "not_found" }
      }

      const userSessions = await db
        .select({
          id: sessions.id,
          clientType: sessions.clientType,
          clientVersion: sessions.clientVersion,
          osVersion: sessions.osVersion,
          lastActive: sessions.lastActive,
          active: sessions.active,
          deviceId: sessions.deviceId,
          date: sessions.date,
          revoked: sessions.revoked,
          personalDataEncrypted: sessions.personalDataEncrypted,
          personalDataIv: sessions.personalDataIv,
          personalDataTag: sessions.personalDataTag,
        })
        .from(sessions)
        .where(eq(sessions.userId, userId))
        .orderBy(desc(sessions.lastActive))
        .limit(50)

      const connections = connectionManager.getUserConnectionSummary(userId)

      const origin = ADMIN_PUBLIC_API_ORIGIN ?? new URL(request.url).origin
      return {
        ok: true,
        user: {
          id: user.id,
          email: user.email,
          firstName: user.firstName,
          lastName: user.lastName,
          emailVerified: user.emailVerified,
          avatarUrl: user.photoFileId ? `${origin}/admin/users/${user.id}/avatar` : null,
        },
        sessions: userSessions.map((sessionRow) => ({
          id: sessionRow.id,
          clientType: sessionRow.clientType,
          clientVersion: sessionRow.clientVersion,
          osVersion: sessionRow.osVersion,
          lastActive: sessionRow.lastActive ? sessionRow.lastActive.toISOString() : null,
          active: Boolean(sessionRow.active),
          deviceId: sessionRow.deviceId,
          date: sessionRow.date ? sessionRow.date.toISOString() : null,
          revoked: sessionRow.revoked ? sessionRow.revoked.toISOString() : null,
          personalData: decryptSessionPersonalData(sessionRow),
        })),
        connections,
      }
    },
    {
      params: t.Object({
        id: t.String(),
      }),
      cookie: adminCookieSchema,
    },
  )
  .post(
    "/users/:id/update",
    async ({ params, body, cookie, request, server, set }) => {
      const session = await requireAdminSession(cookie as AdminCookieStore, request, server, set)
      if (!session) {
        return { ok: false, error: "unauthorized" }
      }

      if (!requireSetupComplete(session, set)) {
        return { ok: false, error: "setup_required" }
      }

      if (!requireStepUp(session, set)) {
        return { ok: false, error: "step_up_required" }
      }

      const userId = Number(params.id)
      if (!Number.isFinite(userId)) {
        set.status = 400
        return { ok: false, error: "invalid_user" }
      }

      const updates: Partial<typeof users.$inferInsert> = {}
      if (typeof body.email === "string" && body.email.trim().length > 0) {
        const normalizedEmail = normalizeEmail(body.email)
        if (!isValidEmail(normalizedEmail)) {
          set.status = 400
          return { ok: false, error: "invalid_email" }
        }
        updates.email = normalizedEmail
      }
      if (typeof body.firstName === "string") {
        updates.firstName = body.firstName
      }
      if (typeof body.lastName === "string") {
        updates.lastName = body.lastName
      }
      if (typeof body.emailVerified === "boolean") {
        updates.emailVerified = body.emailVerified
      }

      if (Object.keys(updates).length === 0) {
        set.status = 400
        return { ok: false, error: "no_updates" }
      }

      const [updated] = await db.update(users).set(updates).where(eq(users.id, userId)).returning()
      if (!updated) {
        set.status = 404
        return { ok: false, error: "not_found" }
      }

      if (updates.email) {
        await db
          .update(superadminUsers)
          .set({ email: updates.email })
          .where(eq(superadminUsers.userId, userId))
      }

      await notifyAdminAction({
        actionTaken: `Updated user ${userId}`,
        actorEmail: session.email,
        ip: getRequestIp(request, server),
        userAgent: request.headers.get("user-agent") ?? "",
      })

      return { ok: true }
    },
    {
      params: t.Object({
        id: t.String(),
      }),
      body: t.Object({
        email: t.Optional(t.String()),
        firstName: t.Optional(t.String()),
        lastName: t.Optional(t.String()),
        emailVerified: t.Optional(t.Boolean()),
      }),
      cookie: adminCookieSchema,
    },
  )

const getRequestIp = (request: Request, server: BunServer | undefined) => {
  return (
    request.headers.get("x-forwarded-for") ??
    request.headers.get("cf-connecting-ip") ??
    request.headers.get("x-real-ip") ??
    server?.requestIP(request)?.address
  )
}

const isAllowedAdminOrigin = (request: Request) => {
  const origin = request.headers.get("origin")
  if (origin && ADMIN_ALLOWED_ORIGINS.has(origin)) {
    return true
  }

  const referer = request.headers.get("referer")
  if (referer) {
    for (const allowed of ADMIN_ALLOWED_ORIGINS) {
      if (referer.startsWith(`${allowed}/`)) {
        return true
      }
    }
  }

  return !isProd
}

const clearAdminCookie = (cookie: AdminCookieStore) => {
  const secure = isProd
  cookie[ADMIN_COOKIE_NAME].set({
    secure,
    path: "/",
    httpOnly: true,
    maxAge: 0,
    value: "",
    sameSite: "strict",
  })
}

const getSuperadminByEmail = async (email: string) => {
  return (
    await db
      .select()
      .from(superadminUsers)
      .where(and(eq(superadminUsers.email, email), isNull(superadminUsers.disabledAt)))
      .limit(1)
  )[0]
}

const getSuperadminByUserId = async (userId: number) => {
  return (
    await db
      .select()
      .from(superadminUsers)
      .where(and(eq(superadminUsers.userId, userId), isNull(superadminUsers.disabledAt)))
      .limit(1)
  )[0]
}

const getTotpSecret = (adminUser: typeof superadminUsers.$inferSelect) => {
  if (!adminUser.totpSecretEncrypted || !adminUser.totpSecretIv || !adminUser.totpSecretTag) {
    return null
  }

  return decrypt({
    encrypted: adminUser.totpSecretEncrypted,
    iv: adminUser.totpSecretIv,
    authTag: adminUser.totpSecretTag,
  })
}

const sendAdminLoginCode = async (email: string): Promise<string> => {
  const existingUsers = await db.select().from(users).where(eq(users.email, email)).limit(1)
  const existingUser = existingUsers[0] ? existingUsers[0].pendingSetup !== true : false
  const firstName = existingUsers[0]?.firstName ?? undefined

  const { code, challengeToken } = await issueEmailLoginChallenge({ email })

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

  return challengeToken
}

const verifyAdminLoginCode = async (email: string, code: string, challengeToken?: string): Promise<true> => {
  await new Promise((resolve) => setTimeout(resolve, Math.random() * 1000))

  const verified = await verifyEmailLoginChallenge({ email, code, challengeToken })
  if (!verified) {
    throw new Error("Invalid code")
  }

  return true
}

const getOrCreateUserByEmail = async (email: string) => {
  let user = (await db.select().from(users).where(eq(users.email, email)).limit(1))[0]

  if (!user) {
    const createdUser = (
      await db
        .insert(users)
        .values({
          email,
          emailVerified: true,
          pendingSetup: false,
        })
        .returning()
    )[0]

    if (createdUser) {
      sendInlineOnlyBotEvent(`Superadmin user provisioned: userId=${createdUser.id}`)
    }

    return createdUser
  }

  try {
    await db.update(users).set({ pendingSetup: false }).where(eq(users.email, email))
  } catch (error) {
    Log.shared.error("Failed to update pending setup to false", error)
  }

  return user
}

type CreateAdminSessionInput = {
  userId: number
  ip: string | null | undefined
  userAgent: string
  stepUpAt?: Date | null
}

const createAdminSession = async ({ userId, ip, userAgent, stepUpAt }: CreateAdminSessionInput) => {
  const now = new Date()
  const expiresAt = new Date(now.getTime() + ADMIN_TTL_MS)
  const idleExpiresAt = new Date(now.getTime() + ADMIN_IDLE_MS)
  const { token, tokenHash } = await generateToken(userId)

  await db.insert(superadminSessions).values({
    userId,
    tokenHash,
    lastSeenAt: now,
    stepUpAt: stepUpAt ?? null,
    expiresAt,
    idleExpiresAt,
    ip: ip ?? null,
    userAgentHash: userAgent ? hashToken(userAgent) : null,
    date: now,
  })

  return { token }
}

const getAdminSession = async (cookie: AdminCookieStore, request: Request, _server: BunServer | undefined) => {
  const token = cookie[ADMIN_COOKIE_NAME]?.value
  if (!token) return null

  const tokenHash = hashToken(token)
  const session = (
    await db
      .select()
      .from(superadminSessions)
      .where(and(eq(superadminSessions.tokenHash, tokenHash), isNull(superadminSessions.revokedAt)))
      .limit(1)
  )[0]

  if (!session) return null

  const tokenUserId = Number(token.split(":")[0])
  if (!Number.isFinite(tokenUserId) || tokenUserId !== session.userId) {
    return null
  }

  const now = new Date()
  if (session.expiresAt <= now || session.idleExpiresAt <= now) {
    return null
  }

  const userAgent = request.headers.get("user-agent") ?? ""
  const userAgentHash = userAgent ? hashToken(userAgent) : null
  if (session.userAgentHash && userAgentHash && session.userAgentHash !== userAgentHash) {
    return null
  }

  const adminUser = await getSuperadminByUserId(session.userId)
  if (!adminUser) return null

  const user = (await db.select().from(users).where(eq(users.id, session.userId)).limit(1))[0]
  if (!user || !user.email) return null

  await db
    .update(superadminSessions)
    .set({
      lastSeenAt: now,
      idleExpiresAt: new Date(now.getTime() + ADMIN_IDLE_MS),
    })
    .where(eq(superadminSessions.id, session.id))

  return {
    sessionId: session.id,
    userId: user.id,
    email: user.email,
    firstName: user.firstName ?? null,
    lastName: user.lastName ?? null,
    passwordSet: Boolean(adminUser.passwordHash),
    totpEnabled: Boolean(adminUser.totpEnabledAt),
    stepUpAt: session.stepUpAt ?? null,
  } satisfies AdminSessionContext
}

const requireAdminSession = async (
  cookie: AdminCookieStore,
  request: Request,
  server: BunServer | undefined,
  set: AdminSet,
) => {
  const session = await getAdminSession(cookie, request, server)
  if (!session) {
    set.status = 401
    return null
  }
  return session
}

const requireSetupComplete = (session: AdminSessionContext, set: AdminSet) => {
  if (!session.passwordSet || !session.totpEnabled) {
    set.status = 403
    return false
  }
  return true
}

const requireStepUp = (session: AdminSessionContext, set: AdminSet) => {
  if (!session.stepUpAt) {
    set.status = 403
    return false
  }

  const age = Date.now() - session.stepUpAt.getTime()
  if (age > STEP_UP_WINDOW_MS) {
    set.status = 403
    return false
  }

  return true
}

type AdminActionNotification = {
  actionTaken: string
  actorEmail: string
  ip?: string | null
  userAgent?: string | null
}

const notifyAdminAction = async ({ actionTaken, actorEmail, ip, userAgent }: AdminActionNotification) => {
  try {
    const recipients = await db
      .select({ email: superadminUsers.email })
      .from(superadminUsers)
      .where(isNull(superadminUsers.disabledAt))

    const emails = Array.from(new Set(recipients.map((row) => row.email)))
    const timestamp = new Date().toISOString()

    await Promise.all(
      emails.map((email) =>
        sendEmail({
          to: email,
          content: {
            template: "adminAction",
            variables: {
              actionTaken,
              actorEmail,
              ip: ip ?? null,
              userAgent: userAgent ?? null,
              timestamp,
            },
          },
        }),
      ),
    )
  } catch (error) {
    Log.shared.error("Failed to send admin action email", error)
  }
}

type SessionPersonalData = {
  country?: string
  region?: string
  city?: string
  timezone?: string
  ip?: string
  deviceName?: string
}

const decryptSessionPersonalData = (session: {
  personalDataEncrypted: Buffer | null
  personalDataIv: Buffer | null
  personalDataTag: Buffer | null
}): SessionPersonalData => {
  try {
    if (!session.personalDataEncrypted || !session.personalDataIv || !session.personalDataTag) {
      return {}
    }

    const decrypted = decrypt({
      encrypted: session.personalDataEncrypted,
      iv: session.personalDataIv,
      authTag: session.personalDataTag,
    })

    return JSON.parse(decrypted) as SessionPersonalData
  } catch (error) {
    Log.shared.error("Failed to decrypt session personal data", error)
    return {}
  }
}

const getStartOfUtcDay = (date: Date) => {
  return new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate()))
}

// Use the DB clock to compute the UTC day window. This avoids issues where the
// app process timezone/clock differs across deploys/instances and subtly shifts
// "today" boundaries when passing JS Dates as SQL params.
const getUtcDayWindowSql = () => {
  const start = sql<Date>`date_trunc('day', timezone('utc', now()))`
  const next = sql<Date>`${start} + interval '1 day'`
  return { start, next }
}

const countConnectedUsersToday = async () => {
  const start = getStartOfUtcDay(new Date())
  const rows = await db
    .select({
      count: sql<number>`count(distinct ${sessions.userId})::int`,
    })
    .from(sessions)
    .where(gte(sessions.lastActive, start))

  return rows[0]?.count ?? 0
}

const getAppMetrics = async () => {
  const now = new Date()
  const startOfDay = getStartOfUtcDay(now)
  const nextDay = new Date(startOfDay.getTime() + 24 * 60 * 60 * 1000)
  const weekStart = new Date(startOfDay.getTime() - 6 * 24 * 60 * 60 * 1000)
  const baseUserWhere = and(
    or(isNull(users.deleted), eq(users.deleted, false)),
    or(isNull(users.bot), eq(users.bot, false)),
  )

  const [dauRow] = await db
    .select({
      count: sql<number>`count(distinct ${messages.fromId})::int`,
    })
    .from(messages)
    .innerJoin(users, eq(messages.fromId, users.id))
    .where(and(gte(messages.date, startOfDay), lt(messages.date, nextDay), baseUserWhere))

  const [messagesTodayRow] = await db
    .select({
      count: sql<number>`count(*)::int`,
    })
    .from(messages)
    .innerJoin(users, eq(messages.fromId, users.id))
    .where(and(gte(messages.date, startOfDay), lt(messages.date, nextDay), baseUserWhere))

  const [activeUsersLast7dRow] = await db
    .select({
      count: sql<number>`count(distinct ${messages.fromId})::int`,
    })
    .from(messages)
    .innerJoin(users, eq(messages.fromId, users.id))
    .where(and(gte(messages.date, weekStart), lt(messages.date, nextDay), baseUserWhere))

  const wauRows = await db
    .select({
      userId: messages.fromId,
      activeDays: sql<number>`count(distinct date_trunc('day', ${messages.date}))::int`,
    })
    .from(messages)
    .innerJoin(users, eq(messages.fromId, users.id))
    .where(and(gte(messages.date, weekStart), lt(messages.date, nextDay), baseUserWhere))
    .groupBy(messages.fromId)

  const wau = wauRows.reduce((count, row) => (row.activeDays >= 3 ? count + 1 : count), 0)

  const { start: startOfDayUtcSql, next: nextDayUtcSql } = getUtcDayWindowSql()
  const [threadsTodayRow] = await db
    .select({
      count: sql<number>`count(*)::int`,
    })
    .from(chats)
    .where(and(eq(chats.type, "thread"), gte(chats.date, startOfDayUtcSql), lt(chats.date, nextDayUtcSql)))

  const [totalUsersRow] = await db
    .select({
      count: sql<number>`count(*)::int`,
    })
    .from(users)
    .where(baseUserWhere)

  const [verifiedUsersRow] = await db
    .select({
      count: sql<number>`count(*)::int`,
    })
    .from(users)
    .where(and(baseUserWhere, eq(users.emailVerified, true)))

  const [onlineUsersRow] = await db
    .select({
      count: sql<number>`count(*)::int`,
    })
    .from(users)
    .where(and(baseUserWhere, eq(users.online, true)))

  return {
    dau: dauRow?.count ?? 0,
    wau,
    messagesToday: messagesTodayRow?.count ?? 0,
    activeUsersToday: dauRow?.count ?? 0,
    activeUsersLast7d: activeUsersLast7dRow?.count ?? 0,
    threadsCreatedToday: threadsTodayRow?.count ?? 0,
    totals: {
      totalUsers: totalUsersRow?.count ?? 0,
      verifiedUsers: verifiedUsersRow?.count ?? 0,
      onlineUsers: onlineUsersRow?.count ?? 0,
    },
  }
}
