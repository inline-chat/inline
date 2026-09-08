import { adminOAuthConnections } from "@in/server/modules/oauth/adminConnections"
import { Effect } from "effect"
import os from "node:os"
import { and, desc, eq, gte, isNull, lt, or, sql } from "drizzle-orm"
import { db } from "@in/server/db"
import { chats, messages, sessions, users, waitlist } from "@in/server/db/schema"
import { connectionManager } from "@in/server/ws/connections"
import { getErrorStats } from "@in/server/utils/metrics"
import { gitCommitHash, version } from "@in/server/buildEnv"
import { getDesktopPushSuppressionMetrics } from "@in/server/modules/notifications/desktopPushSuppression"
import { ADMIN_PUBLIC_API_ORIGIN } from "@in/server/env"
import type { AdminOperationsShape } from "./adminOperations.effect"
import {
  ADMIN_ACTIVE_USERS_LIMIT,
  attempt,
  getStartOfUtcDay,
  getStartOfUtcWeek,
  jsonResult,
} from "./adminOperationsSupport.effect"

type MetricsOperationName = "technicalMetrics" | "appMetrics" | "overviewMetrics" | "activeUsers"

export type AdminMetricsOperations = Pick<AdminOperationsShape, MetricsOperationName>

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

const baseHumanUserWhere = () =>
  and(or(isNull(users.deleted), eq(users.deleted, false)), or(isNull(users.bot), eq(users.bot, false)))

const getWeeklyActivity = async (baseUserWhere: ReturnType<typeof and>, now: Date) => {
  const currentWeekStart = getStartOfUtcWeek(now)
  const firstWeekStart = new Date(currentWeekStart)
  firstWeekStart.setUTCDate(firstWeekStart.getUTCDate() - 7 * 7)

  const messageWeek = sql<string>`to_char(date_trunc('week', ${messages.date}), 'YYYY-MM-DD')`
  const threadWeek = sql<string>`to_char(date_trunc('week', ${chats.date}), 'YYYY-MM-DD')`
  const userWeek = sql<string>`to_char(date_trunc('week', ${users.date}), 'YYYY-MM-DD')`

  const [messageRows, threadRows, newUserRows] = await Promise.all([
    db
      .select({
        week: messageWeek,
        messages: sql<number>`count(*)::int`,
        activeUsers: sql<number>`count(distinct ${messages.fromId})::int`,
      })
      .from(messages)
      .innerJoin(users, eq(messages.fromId, users.id))
      .where(
        and(
          gte(messages.date, firstWeekStart),
          lt(messages.date, now),
          isNull(messages.systemMessageEncrypted),
          baseUserWhere,
        ),
      )
      .groupBy(sql`date_trunc('week', ${messages.date})`),
    db
      .select({
        week: threadWeek,
        count: sql<number>`count(*)::int`,
      })
      .from(chats)
      .where(and(eq(chats.type, "thread"), gte(chats.date, firstWeekStart), lt(chats.date, now)))
      .groupBy(sql`date_trunc('week', ${chats.date})`),
    db
      .select({
        week: userWeek,
        count: sql<number>`count(*)::int`,
      })
      .from(users)
      .where(and(gte(users.date, firstWeekStart), lt(users.date, now), baseUserWhere))
      .groupBy(sql`date_trunc('week', ${users.date})`),
  ])

  const messagesByWeek = new Map(messageRows.map((row) => [row.week, row.messages]))
  const activeUsersByWeek = new Map(messageRows.map((row) => [row.week, row.activeUsers]))
  const threadsByWeek = new Map(threadRows.map((row) => [row.week, row.count]))
  const newUsersByWeek = new Map(newUserRows.map((row) => [row.week, row.count]))

  return Array.from({ length: 8 }, (_, index) => {
    const start = new Date(firstWeekStart)
    start.setUTCDate(start.getUTCDate() + index * 7)
    const end = new Date(start)
    end.setUTCDate(end.getUTCDate() + 7)
    const key = start.toISOString().slice(0, 10)
    return {
      weekStart: start.toISOString(),
      weekEnd: end.toISOString(),
      activeUsers: activeUsersByWeek.get(key) ?? 0,
      newUsers: newUsersByWeek.get(key) ?? 0,
      messages: messagesByWeek.get(key) ?? 0,
      threads: threadsByWeek.get(key) ?? 0,
    }
  })
}

export const getAppMetrics = async (now = new Date()) => {
  const startOfDay = getStartOfUtcDay(now)
  const weekStart = new Date(startOfDay.getTime() - 6 * 86_400_000)
  const baseUserWhere = baseHumanUserWhere()
  const [dailyActivity, wauRows, totalUsersRow, verifiedUsersRow, onlineUsersRow, weeklyActivity] = await Promise.all([
    getDailyActivity(now),
    db
      .select({
        userId: messages.fromId,
        activeDays: sql<number>`count(distinct date_trunc('day', ${messages.date}))::int`,
      })
      .from(messages)
      .innerJoin(users, eq(messages.fromId, users.id))
      .where(
        and(
          gte(messages.date, weekStart),
          lt(messages.date, now),
          isNull(messages.systemMessageEncrypted),
          baseUserWhere,
        ),
      )
      .groupBy(messages.fromId),
    db
      .select({ count: sql<number>`count(*)::int` })
      .from(users)
      .where(baseUserWhere)
      .then((rows) => rows[0]),
    db
      .select({ count: sql<number>`count(*)::int` })
      .from(users)
      .where(and(baseUserWhere, eq(users.emailVerified, true)))
      .then((rows) => rows[0]),
    db
      .select({ count: sql<number>`count(*)::int` })
      .from(users)
      .where(and(baseUserWhere, eq(users.online, true)))
      .then((rows) => rows[0]),
    getWeeklyActivity(baseUserWhere, now),
  ])
  const today = dailyActivity.at(-1)!
  return {
    asOf: now.toISOString(),
    reportingTimeZone: "UTC" as const,
    dau: today.activeUsers,
    wau: wauRows.filter((row) => row.activeDays >= 3).length,
    messagesToday: today.messages,
    activeUsersToday: today.activeUsers,
    activeUsersLast7d: wauRows.length,
    threadsCreatedToday: today.threads,
    totals: {
      totalUsers: totalUsersRow?.count ?? 0,
      verifiedUsers: verifiedUsersRow?.count ?? 0,
      onlineUsers: onlineUsersRow?.count ?? 0,
    },
    weeklyActivity,
    dailyActivity,
  }
}

// Dates in these tables are UTC timestamp-without-time-zone columns. Truncate
// directly: timezone('utc', column) would convert them to session-dependent timestamptz.
// 90 visible completed days + 6 lookback days for a seven-day mean + today.
export const getDailyActivity = async (now: Date) => {
  const currentDayStart = getStartOfUtcDay(now)
  const firstDayStart = new Date(currentDayStart.getTime() - 96 * 86_400_000)
  const messageDay = sql<string>`to_char(${messages.date}, 'YYYY-MM-DD')`
  const userDay = sql<string>`to_char(${users.date}, 'YYYY-MM-DD')`
  const threadDay = sql<string>`to_char(${chats.date}, 'YYYY-MM-DD')`
  const baseUserWhere = baseHumanUserWhere()
  const [messageRows, newUserRows, threadRows] = await Promise.all([
    db
      .select({
        day: messageDay,
        activeUsers: sql<number>`count(distinct ${messages.fromId})::int`,
        messages: sql<number>`count(*)::int`,
      })
      .from(messages)
      .innerJoin(users, eq(messages.fromId, users.id))
      .where(
        and(
          gte(messages.date, firstDayStart),
          lt(messages.date, now),
          isNull(messages.systemMessageEncrypted),
          baseUserWhere,
        ),
      )
      .groupBy(messageDay),
    db
      .select({ day: userDay, count: sql<number>`count(*)::int` })
      .from(users)
      .where(and(gte(users.date, firstDayStart), lt(users.date, now), baseUserWhere))
      .groupBy(userDay),
    db
      .select({ day: threadDay, count: sql<number>`count(*)::int` })
      .from(chats)
      .where(and(eq(chats.type, "thread"), gte(chats.date, firstDayStart), lt(chats.date, now)))
      .groupBy(threadDay),
  ])
  const messagesByDay = new Map(messageRows.map((row) => [row.day, row]))
  const newUsersByDay = new Map(newUserRows.map((row) => [row.day, row.count]))
  const threadsByDay = new Map(threadRows.map((row) => [row.day, row.count]))
  return Array.from({ length: 97 }, (_, index) => {
    const date = new Date(firstDayStart.getTime() + index * 86_400_000).toISOString()
    const key = date.slice(0, 10)
    return {
      date,
      activeUsers: messagesByDay.get(key)?.activeUsers ?? 0,
      newUsers: newUsersByDay.get(key) ?? 0,
      messages: messagesByDay.get(key)?.messages ?? 0,
      threads: threadsByDay.get(key) ?? 0,
    }
  })
}

export const getRecentOverviewActivity = async (publicOrigin: string, now: Date) => {
  const lastDay = getStartOfUtcDay(now)
  const baseUserWhere = and(gte(users.date, lastDay), lt(users.date, now), baseHumanUserWhere())
  const [newUsersRow, newWaitlistRow, recentUsers, recentWaitlist] = await Promise.all([
    db
      .select({
        count: sql<number>`count(*)::int`,
      })
      .from(users)
      .where(baseUserWhere)
      .then((rows) => rows[0]),
    db
      .select({
        count: sql<number>`count(*)::int`,
      })
      .from(waitlist)
      .where(and(gte(waitlist.date, lastDay), lt(waitlist.date, now)))
      .then((rows) => rows[0]),
    db
      .select({
        id: users.id,
        email: users.email,
        firstName: users.firstName,
        lastName: users.lastName,
        username: users.username,
        createdAt: users.date,
        pendingSetup: users.pendingSetup,
        photoFileId: users.photoFileId,
      })
      .from(users)
      .where(baseUserWhere)
      .orderBy(desc(users.date))
      .limit(8),
    db
      .select({
        id: waitlist.id,
        email: waitlist.email,
        name: waitlist.name,
        verified: waitlist.verified,
        date: waitlist.date,
      })
      .from(waitlist)
      .where(and(gte(waitlist.date, lastDay), lt(waitlist.date, now)))
      .orderBy(desc(waitlist.date))
      .limit(8),
  ])
  const origin = ADMIN_PUBLIC_API_ORIGIN ?? publicOrigin
  const oauthConnections = await adminOAuthConnections(recentUsers.map((user) => user.id))

  return {
    newUsersLastDay: newUsersRow?.count ?? 0,
    newWaitlistLastDay: newWaitlistRow?.count ?? 0,
    recentUsers: recentUsers.map((user) => ({
      id: user.id,
      email: user.email,
      firstName: user.firstName,
      lastName: user.lastName,
      username: user.username,
      createdAt: user.createdAt?.toISOString() ?? null,
      pendingSetup: user.pendingSetup,
      oauthConnections: oauthConnections.get(user.id) ?? [],
      avatarUrl: user.photoFileId ? `${origin}/admin/users/${user.id}/avatar` : null,
    })),
    recentWaitlist: recentWaitlist.map((entry) => ({
      id: entry.id,
      email: entry.email,
      name: entry.name,
      verified: entry.verified,
      date: entry.date?.toISOString() ?? null,
    })),
  }
}

const getActiveMetricUsers = async (period: "today" | "week") => {
  const now = new Date()
  const startOfDay = getStartOfUtcDay(now)
  const windowStart = period === "today" ? startOfDay : new Date(startOfDay.getTime() - 6 * 24 * 60 * 60 * 1000)
  const baseUserWhere = baseHumanUserWhere()
  const activeDays = sql<number>`count(distinct date_trunc('day', ${messages.date}))::int`
  const lastActive = sql<Date>`max(${messages.date})`

  return db
    .select({
      id: users.id,
      email: users.email,
      firstName: users.firstName,
      lastName: users.lastName,
      username: users.username,
      activeDays,
      messageCount: sql<number>`count(*)::int`,
      lastActive: sql<string>`to_char(max(${messages.date}), 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')`,
    })
    .from(messages)
    .innerJoin(users, eq(messages.fromId, users.id))
    .where(
      and(
        gte(messages.date, windowStart),
        lt(messages.date, now),
        isNull(messages.systemMessageEncrypted),
        baseUserWhere,
      ),
    )
    .groupBy(users.id, users.email, users.firstName, users.lastName, users.username)
    .having(period === "week" ? sql`${activeDays} >= 3` : sql`true`)
    .orderBy(desc(lastActive))
    .limit(ADMIN_ACTIVE_USERS_LIMIT)
}

export const makeAdminMetricsOperations = (): AdminMetricsOperations => ({
  technicalMetrics: () =>
    Effect.gen(function* () {
      const connectedToday = yield* attempt("admin.metrics.technical.connected-today", countConnectedUsersToday)
      const memory = process.memoryUsage()
      const uptimeSeconds = process.uptime()
      const startedAt = new Date(Date.now() - uptimeSeconds * 1000)
      const errorStats = getErrorStats()
      return jsonResult({
        ok: true as const,
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
          errors: errorStats,
          notifications: {
            desktopPushSuppression: getDesktopPushSuppressionMetrics(),
          },
        },
      })
    }),
  appMetrics: () =>
    attempt("admin.metrics.app", getAppMetrics).pipe(
      Effect.map((metrics) =>
        jsonResult({
          ok: true as const,
          metrics,
        }),
      ),
    ),
  overviewMetrics: (_session, request) =>
    attempt("admin.metrics.overview", async () => {
      const metricsNow = new Date()
      const [appMetrics, waitlistCountRow, recentActivity] = await Promise.all([
        getAppMetrics(metricsNow),
        db
          .select({
            count: sql<number>`count(*)::int`,
          })
          .from(waitlist)
          .then((rows) => rows[0]),
        getRecentOverviewActivity(request.publicOrigin, metricsNow),
      ])
      const errorStats = getErrorStats()
      return jsonResult({
        ok: true as const,
        metrics: {
          dau: appMetrics.dau,
          wau: appMetrics.wau,
          messagesToday: appMetrics.messagesToday,
          // TODO(effect-cutover): replace the retained
          // placeholder with billing-derived MRR once the
          // admin dashboard has a billing capability.
          mrr: 390,
          connections: {
            total: connectionManager.getTotalConnections(),
            authenticated: connectionManager.getAuthenticatedConnectionCount(),
          },
          errors: {
            last5m: errorStats.last5m,
          },
          waitlistCount: waitlistCountRow?.count ?? 0,
          newUsersLastDay: recentActivity.newUsersLastDay,
          newWaitlistLastDay: recentActivity.newWaitlistLastDay,
          recentUsersLastDay: recentActivity.recentUsers,
          recentWaitlistLastDay: recentActivity.recentWaitlist,
          dailyActivity: appMetrics.dailyActivity,
          asOf: appMetrics.asOf,
          reportingTimeZone: appMetrics.reportingTimeZone,
        },
      })
    }),
  activeUsers: (query) =>
    attempt("admin.metrics.active-users", () => getActiveMetricUsers(query.period ?? "today")).pipe(
      Effect.map((activeUsers) =>
        jsonResult({
          ok: true as const,
          period: query.period ?? "today",
          limit: ADMIN_ACTIVE_USERS_LIMIT,
          users: activeUsers,
        }),
      ),
    ),
})
