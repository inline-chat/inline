import { Elysia, t } from "elysia"
import { InlineError } from "@in/server/types/errors"
import { normalizeToken } from "@in/server/utils/auth"
import { getUserIdFromToken } from "@in/server/controllers/plugins"
import { db } from "@in/server/db"
import { users } from "@in/server/db/schema/users"
import { eq } from "drizzle-orm"

export type BotHandlerContext = {
  currentUserId: number
  currentSessionId: number
  ip: string | undefined
}

const requireBotUser = async (userId: number) => {
  const row = await db.select({ bot: users.bot }).from(users).where(eq(users.id, userId)).limit(1)
  if (!row[0]?.bot) {
    throw new InlineError(InlineError.ApiError.UNAUTHORIZED)
  }
}

const getIp = (request: Request, server: any): string | undefined => {
  return (
    request.headers.get("x-forwarded-for") ??
    request.headers.get("cf-connecting-ip") ??
    request.headers.get("x-real-ip") ??
    server?.requestIP(request)?.address
  )
}

const normalizePathToken = (token: string): string | null => {
  try {
    const decoded = decodeURIComponent(token)
    const normalized = normalizeToken(decoded)
    if (normalized) return normalized
  } catch {
    // Fallback to raw token when decoding fails on malformed percent sequences.
  }

  return normalizeToken(token)
}

export const authenticateBotHeader = new Elysia({ name: "authenticate-bot-header" })
  .state("currentUserId", 0)
  .state("currentSessionId", 0)
  .state("ip", undefined as string | undefined)
  .guard({
    as: "scoped",
    headers: t.Object({
      authorization: t.Optional(t.String()),
    }),
    beforeHandle: async ({ headers, store, request, server }) => {
      const token = normalizeToken(headers.authorization)
      if (!token) throw new InlineError(InlineError.ApiError.UNAUTHORIZED)

      const { userId, sessionId } = await getUserIdFromToken(token)
      await requireBotUser(userId)

      store.currentUserId = userId
      store.currentSessionId = sessionId
      store.ip = getIp(request, server)
    },
  })

export const authenticateBotPathOrHeader = new Elysia({ name: "authenticate-bot-path-or-header" })
  .state("currentUserId", 0)
  .state("currentSessionId", 0)
  .state("ip", undefined as string | undefined)
  .guard({
    as: "scoped",
    params: t.Object({
      token: t.String(),
    }),
    headers: t.Object({
      authorization: t.Optional(t.String()),
    }),
    beforeHandle: async ({ headers, params, store, request, server }) => {
      const headerToken = normalizeToken(headers.authorization)
      const token = headerToken ?? normalizePathToken(params.token)
      if (!token) throw new InlineError(InlineError.ApiError.UNAUTHORIZED)

      const { userId, sessionId } = await getUserIdFromToken(token)
      await requireBotUser(userId)

      store.currentUserId = userId
      store.currentSessionId = sessionId
      store.ip = getIp(request, server)
    },
  })
