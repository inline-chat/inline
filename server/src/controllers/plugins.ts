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
    console.log("auth", auth)
    let token = normalizeToken(auth)
    if (!token) {
      throw new InlineError(ErrorCodes.UNAUTHORIZED, "Unauthorized")
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
      throw new InlineError(ErrorCodes.UNAUTHORIZED, "Unauthorized")
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

const getUserIdFromToken = async (token: string): Promise<number> => {
  let tokenHash = hashToken(token)
  console.log("token", token)
  console.log("tokenHash", tokenHash)
  let session = await db.query.sessions.findFirst({
    where: and(eq(sessions.tokenHash, tokenHash), isNull(sessions.revoked)),
  })

  if (!session) {
    throw new InlineError(ErrorCodes.UNAUTHORIZED, "Unauthorized")
  }

  // TODO: update last active

  return session.userId
}
