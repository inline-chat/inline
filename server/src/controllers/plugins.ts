import { Elysia, t } from "elysia"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { db } from "@in/server/db"
import { and, eq, isNull } from "drizzle-orm"
import { sessions } from "@in/server/db/schema"
import { hashToken } from "@in/server/utils/auth"

export const authenticate = new Elysia({ name: "authenticate" }).state("currentUserId", 0).guard({
  as: "scoped",

  headers: t.Object({
    authorization: t.Optional(t.TemplateLiteral("Bearer ${string}")),
  }),

  beforeHandle: async ({ headers, store }) => {
    let auth = headers["authorization"]
    let token = normalizeToken(auth)
    if (!token) {
      throw new InlineError(InlineError.ApiError.UNAUTHORIZED)
    }

    store.currentUserId = await getUserIdFromToken(token)
  },
})

export const authenticateGet = new Elysia({ name: "authenticate" }).state("currentUserId", 0).guard({
  as: "scoped",

  params: t.Object({
    token: t.Optional(t.String()),
  }),

  beforeHandle: async ({ headers, params, store }) => {
    let auth = params.token ?? headers["authorization"]
    let token = normalizeToken(auth)
    if (!token) {
      throw new InlineError(InlineError.ApiError.UNAUTHORIZED)
    }

    store.currentUserId = await getUserIdFromToken(token)
  },
})

const normalizeToken = (token: unknown): string | null => {
  if (typeof token !== "string") {
    return null
  }
  return token.replace("Bearer ", "").trim()
}

export const getUserIdFromToken = async (token: string): Promise<number> => {
  let supposedUserId = token.split(":")[0]
  let tokenHash = hashToken(token)
  let session = await db.query.sessions.findFirst({
    where: and(eq(sessions.tokenHash, tokenHash), isNull(sessions.revoked)),
  })

  if (!session || !supposedUserId) {
    throw new InlineError(InlineError.ApiError.UNAUTHORIZED)
  }

  // TODO: update last active

  if (session.userId !== parseInt(supposedUserId, 10)) {
    console.error("userId mismatch", session.userId, supposedUserId)
    throw new InlineError(InlineError.ApiError.UNAUTHORIZED)
  }

  return session.userId
}
