import {
  Effect,
} from "effect"
import os from "node:os"
import {
  and,
  desc,
  eq,
  gte,
  isNull,
  lt,
  or,
  sql,
} from "drizzle-orm"
import {
  db,
} from "@in/server/db"
import {
  chats,
  messages,
  sessions,
  users,
  waitlist,
} from "@in/server/db/schema"
import {
  connectionManager,
} from "@in/server/ws/connections"
import {
  getErrorStats,
} from "@in/server/utils/metrics"
import {
  gitCommitHash,
  version,
} from "@in/server/buildEnv"
import {
  getDesktopPushSuppressionMetrics,
} from "@in/server/modules/notifications/desktopPushSuppression"
import {
  ADMIN_PUBLIC_API_ORIGIN,
} from "@in/server/env"
import type {
  AdminOperationsShape,
} from "./adminOperations.effect"
import {
  ADMIN_ACTIVE_USERS_LIMIT,
  attempt,
  getStartOfUtcDay,
  getStartOfUtcWeek,
  jsonResult,
} from "./adminOperationsSupport.effect"

type MetricsOperationName =
  | "technicalMetrics"
  | "appMetrics"
  | "overviewMetrics"
  | "activeUsers"

export type AdminMetricsOperations = Pick<
  AdminOperationsShape,
  MetricsOperationName
>

const getUtcDayWindowSql = () => {
  const start =
    sql<Date>`date_trunc('day', timezone('utc', now()))`
  const next = sql<Date>`${start} + interval '1 day'`
  return { start, next }
}

const countConnectedUsersToday = async () => {
  const start = getStartOfUtcDay(new Date())
  const rows = await db
    .select({
      count:
        sql<number>`count(distinct ${sessions.userId})::int`,
    })
    .from(sessions)
    .where(gte(sessions.lastActive, start))
  return rows[0]?.count ?? 0
}

const baseHumanUserWhere = () =>
  and(
    or(isNull(users.deleted), eq(users.deleted, false)),
    or(isNull(users.bot), eq(users.bot, false)),
  )

const getWeeklyActivity = async (
  baseUserWhere: ReturnType<typeof and>,
) => {
  const currentWeekStart = getStartOfUtcWeek(
    new Date(),
  )
  const firstWeekStart = new Date(currentWeekStart)
  firstWeekStart.setUTCDate(
    firstWeekStart.getUTCDate() - 7 * 7,
  )
  const nextWeekStart = new Date(currentWeekStart)
  nextWeekStart.setUTCDate(
    nextWeekStart.getUTCDate() + 7,
  )

  const messageWeek =
    sql<string>`to_char(date_trunc('week', timezone('utc', ${messages.date})), 'YYYY-MM-DD')`
  const threadWeek =
    sql<string>`to_char(date_trunc('week', timezone('utc', ${chats.date})), 'YYYY-MM-DD')`
  const userWeek =
    sql<string>`to_char(date_trunc('week', timezone('utc', ${users.date})), 'YYYY-MM-DD')`

  const [messageRows, threadRows, newUserRows] =
    await Promise.all([
      db
        .select({
          week: messageWeek,
          messages: sql<number>`count(*)::int`,
          activeUsers:
            sql<number>`count(distinct ${messages.fromId})::int`,
        })
        .from(messages)
        .innerJoin(
          users,
          eq(messages.fromId, users.id),
        )
        .where(
          and(
            gte(messages.date, firstWeekStart),
            lt(messages.date, nextWeekStart),
            baseUserWhere,
          ),
        )
        .groupBy(
          sql`date_trunc('week', timezone('utc', ${messages.date}))`,
        ),
      db
        .select({
          week: threadWeek,
          count: sql<number>`count(*)::int`,
        })
        .from(chats)
        .where(
          and(
            eq(chats.type, "thread"),
            gte(chats.date, firstWeekStart),
            lt(chats.date, nextWeekStart),
          ),
        )
        .groupBy(
          sql`date_trunc('week', timezone('utc', ${chats.date}))`,
        ),
      db
        .select({
          week: userWeek,
          count: sql<number>`count(*)::int`,
        })
        .from(users)
        .where(
          and(
            gte(users.date, firstWeekStart),
            lt(users.date, nextWeekStart),
            baseUserWhere,
          ),
        )
        .groupBy(
          sql`date_trunc('week', timezone('utc', ${users.date}))`,
        ),
    ])

  const messagesByWeek = new Map(
    messageRows.map((row) => [row.week, row.messages]),
  )
  const activeUsersByWeek = new Map(
    messageRows.map((row) => [
      row.week,
      row.activeUsers,
    ]),
  )
  const threadsByWeek = new Map(
    threadRows.map((row) => [row.week, row.count]),
  )
  const newUsersByWeek = new Map(
    newUserRows.map((row) => [row.week, row.count]),
  )

  return Array.from({ length: 8 }, (_, index) => {
    const start = new Date(firstWeekStart)
    start.setUTCDate(
      start.getUTCDate() + index * 7,
    )
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

const getAppMetrics = async (now = new Date()) => {
  const startOfDay = getStartOfUtcDay(now)
  const nextDay = new Date(
    startOfDay.getTime() + 24 * 60 * 60 * 1000,
  )
  const weekStart = new Date(
    startOfDay.getTime() -
      6 * 24 * 60 * 60 * 1000,
  )
  const baseUserWhere = baseHumanUserWhere()

  const [
    dauRow,
    messagesTodayRow,
    activeUsersLast7dRow,
    wauRows,
  ] = await Promise.all([
    db
      .select({
        count:
          sql<number>`count(distinct ${messages.fromId})::int`,
      })
      .from(messages)
      .innerJoin(users, eq(messages.fromId, users.id))
      .where(
        and(
          gte(messages.date, startOfDay),
          lt(messages.date, nextDay),
          baseUserWhere,
        ),
      )
      .then((rows) => rows[0]),
    db
      .select({
        count: sql<number>`count(*)::int`,
      })
      .from(messages)
      .innerJoin(users, eq(messages.fromId, users.id))
      .where(
        and(
          gte(messages.date, startOfDay),
          lt(messages.date, nextDay),
          baseUserWhere,
        ),
      )
      .then((rows) => rows[0]),
    db
      .select({
        count:
          sql<number>`count(distinct ${messages.fromId})::int`,
      })
      .from(messages)
      .innerJoin(users, eq(messages.fromId, users.id))
      .where(
        and(
          gte(messages.date, weekStart),
          lt(messages.date, nextDay),
          baseUserWhere,
        ),
      )
      .then((rows) => rows[0]),
    db
      .select({
        userId: messages.fromId,
        activeDays:
          sql<number>`count(distinct date_trunc('day', ${messages.date}))::int`,
      })
      .from(messages)
      .innerJoin(users, eq(messages.fromId, users.id))
      .where(
        and(
          gte(messages.date, weekStart),
          lt(messages.date, nextDay),
          baseUserWhere,
        ),
      )
      .groupBy(messages.fromId),
  ])

  const wau = wauRows.reduce(
    (count, row) =>
      row.activeDays >= 3 ? count + 1 : count,
    0,
  )
  const {
    start: startOfDayUtcSql,
    next: nextDayUtcSql,
  } = getUtcDayWindowSql()

  const [
    threadsTodayRow,
    totalUsersRow,
    verifiedUsersRow,
    onlineUsersRow,
    weeklyActivity,
  ] = await Promise.all([
    db
      .select({
        count: sql<number>`count(*)::int`,
      })
      .from(chats)
      .where(
        and(
          eq(chats.type, "thread"),
          gte(chats.date, startOfDayUtcSql),
          lt(chats.date, nextDayUtcSql),
        ),
      )
      .then((rows) => rows[0]),
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
      .from(users)
      .where(
        and(
          baseUserWhere,
          eq(users.emailVerified, true),
        ),
      )
      .then((rows) => rows[0]),
    db
      .select({
        count: sql<number>`count(*)::int`,
      })
      .from(users)
      .where(
        and(baseUserWhere, eq(users.online, true)),
      )
      .then((rows) => rows[0]),
    getWeeklyActivity(baseUserWhere),
  ])

  return {
    dau: dauRow?.count ?? 0,
    wau,
    messagesToday: messagesTodayRow?.count ?? 0,
    activeUsersToday: dauRow?.count ?? 0,
    activeUsersLast7d:
      activeUsersLast7dRow?.count ?? 0,
    threadsCreatedToday:
      threadsTodayRow?.count ?? 0,
    totals: {
      totalUsers: totalUsersRow?.count ?? 0,
      verifiedUsers: verifiedUsersRow?.count ?? 0,
      onlineUsers: onlineUsersRow?.count ?? 0,
    },
    weeklyActivity,
  }
}

const getDailyActivity = async (
  currentDayStart: Date,
) => {
  const firstDayStart = new Date(
    currentDayStart.getTime() -
      13 * 24 * 60 * 60 * 1000,
  )
  const nextDayStart = new Date(
    currentDayStart.getTime() +
      24 * 60 * 60 * 1000,
  )
  const messageDay =
    sql<string>`to_char(date_trunc('day', ${messages.date}), 'YYYY-MM-DD')`
  const userDay =
    sql<string>`to_char(date_trunc('day', ${users.date}), 'YYYY-MM-DD')`
  const baseUserWhere = baseHumanUserWhere()
  const [activeUserRows, newUserRows] =
    await Promise.all([
      db
        .select({
          day: messageDay,
          count:
            sql<number>`count(distinct ${messages.fromId})::int`,
        })
        .from(messages)
        .innerJoin(
          users,
          eq(messages.fromId, users.id),
        )
        .where(
          and(
            gte(messages.date, firstDayStart),
            lt(messages.date, nextDayStart),
            baseUserWhere,
          ),
        )
        .groupBy(
          sql`date_trunc('day', ${messages.date})`,
        ),
      db
        .select({
          day: userDay,
          count: sql<number>`count(*)::int`,
        })
        .from(users)
        .where(
          and(
            gte(users.date, firstDayStart),
            lt(users.date, nextDayStart),
            baseUserWhere,
          ),
        )
        .groupBy(
          sql`date_trunc('day', ${users.date})`,
        ),
    ])

  const activeUsersByDay = new Map(
    activeUserRows.map((row) => [row.day, row.count]),
  )
  const newUsersByDay = new Map(
    newUserRows.map((row) => [row.day, row.count]),
  )
  return Array.from({ length: 14 }, (_, index) => {
    const day = new Date(
      firstDayStart.getTime() +
        index * 24 * 60 * 60 * 1000,
    )
    const key = day.toISOString().slice(0, 10)
    return {
      date: day.toISOString(),
      activeUsers: activeUsersByDay.get(key) ?? 0,
      newUsers: newUsersByDay.get(key) ?? 0,
    }
  })
}

const getRecentOverviewActivity = async (
  publicOrigin: string,
) => {
  const lastDay = new Date(
    Date.now() - 24 * 60 * 60 * 1000,
  )
  const baseUserWhere = and(
    gte(users.date, lastDay),
    baseHumanUserWhere(),
  )
  const [
    newUsersRow,
    newWaitlistRow,
    recentUsers,
    recentWaitlist,
  ] = await Promise.all([
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
      .where(gte(waitlist.date, lastDay))
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
      .where(gte(waitlist.date, lastDay))
      .orderBy(desc(waitlist.date))
      .limit(8),
  ])
  const origin =
    ADMIN_PUBLIC_API_ORIGIN ?? publicOrigin

  return {
    newUsersLastDay: newUsersRow?.count ?? 0,
    newWaitlistLastDay: newWaitlistRow?.count ?? 0,
    recentUsers: recentUsers.map((user) => ({
      id: user.id,
      email: user.email,
      firstName: user.firstName,
      lastName: user.lastName,
      username: user.username,
      createdAt:
        user.createdAt?.toISOString() ?? null,
      pendingSetup: user.pendingSetup,
      avatarUrl: user.photoFileId
        ? `${origin}/admin/users/${user.id}/avatar`
        : null,
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

const getActiveMetricUsers = async (
  period: "today" | "week",
) => {
  const startOfDay = getStartOfUtcDay(new Date())
  const nextDay = new Date(
    startOfDay.getTime() + 24 * 60 * 60 * 1000,
  )
  const windowStart =
    period === "today"
      ? startOfDay
      : new Date(
          startOfDay.getTime() -
            6 * 24 * 60 * 60 * 1000,
        )
  const baseUserWhere = baseHumanUserWhere()
  const activeDays =
    sql<number>`count(distinct date_trunc('day', ${messages.date}))::int`
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
      lastActive:
        sql<string>`to_char(max(${messages.date}), 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')`,
    })
    .from(messages)
    .innerJoin(users, eq(messages.fromId, users.id))
    .where(
      and(
        gte(messages.date, windowStart),
        lt(messages.date, nextDay),
        baseUserWhere,
      ),
    )
    .groupBy(
      users.id,
      users.email,
      users.firstName,
      users.lastName,
      users.username,
    )
    .having(
      period === "week"
        ? sql`${activeDays} >= 3`
        : sql`true`,
    )
    .orderBy(desc(lastActive))
    .limit(ADMIN_ACTIVE_USERS_LIMIT)
}

export const makeAdminMetricsOperations =
  (): AdminMetricsOperations => ({
    technicalMetrics: () =>
      Effect.gen(function* () {
        const connectedToday = yield* attempt(
          "admin.metrics.technical.connected-today",
          countConnectedUsersToday,
        )
        const memory = process.memoryUsage()
        const uptimeSeconds = process.uptime()
        const startedAt = new Date(
          Date.now() - uptimeSeconds * 1000,
        )
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
              total:
                connectionManager.getTotalConnections(),
              authenticated:
                connectionManager.getAuthenticatedConnectionCount(),
              authenticatedUsers:
                connectionManager.getAuthenticatedUserCount(),
              connectedToday,
            },
            errors: errorStats,
            notifications: {
              desktopPushSuppression:
                getDesktopPushSuppressionMetrics(),
            },
          },
        })
      }),
    appMetrics: () =>
      attempt(
        "admin.metrics.app",
        getAppMetrics,
      ).pipe(
        Effect.map((metrics) =>
          jsonResult({
            ok: true as const,
            metrics,
          }),
        ),
      ),
    overviewMetrics: (_session, request) =>
      attempt(
        "admin.metrics.overview",
        async () => {
          const metricsNow = new Date()
          const currentDayStart =
            getStartOfUtcDay(metricsNow)
          const [
            appMetrics,
            waitlistCountRow,
            recentActivity,
            dailyActivity,
          ] = await Promise.all([
            getAppMetrics(metricsNow),
            db
              .select({
                count: sql<number>`count(*)::int`,
              })
              .from(waitlist)
              .then((rows) => rows[0]),
            getRecentOverviewActivity(
              request.publicOrigin,
            ),
            getDailyActivity(currentDayStart),
          ])
          const errorStats = getErrorStats()
          return jsonResult({
            ok: true as const,
            metrics: {
              dau: appMetrics.dau,
              wau: appMetrics.wau,
              messagesToday:
                appMetrics.messagesToday,
              // TODO(effect-cutover): replace the retained
              // placeholder with billing-derived MRR once the
              // admin dashboard has a billing capability.
              mrr: 390,
              connections: {
                total:
                  connectionManager.getTotalConnections(),
                authenticated:
                  connectionManager.getAuthenticatedConnectionCount(),
              },
              errors: {
                last5m: errorStats.last5m,
              },
              waitlistCount:
                waitlistCountRow?.count ?? 0,
              newUsersLastDay:
                recentActivity.newUsersLastDay,
              newWaitlistLastDay:
                recentActivity.newWaitlistLastDay,
              recentUsersLastDay:
                recentActivity.recentUsers,
              recentWaitlistLastDay:
                recentActivity.recentWaitlist,
              dailyActivity,
            },
          })
        },
      ),
    activeUsers: (query) =>
      attempt(
        "admin.metrics.active-users",
        () =>
          getActiveMetricUsers(
            query.period ?? "today",
          ),
      ).pipe(
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
