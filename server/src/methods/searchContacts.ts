import { encodeMinUserInfo, TMinUserInfo } from "@in/server/api-types"
import { Type, type Static } from "@sinclair/typebox"
import { UsersModel } from "@in/server/db/models/users"
import { InMemoryRateLimiter } from "@in/server/modules/oauth/rateLimiter"
import { InlineError } from "@in/server/types/errors"

const searchLimiter = new InMemoryRateLimiter({ capacity: 10_000 })
const SEARCH_LIMIT = 20

type Context = {
  currentUserId: number
}

export const Input = Type.Object({
  q: Type.String(),
  limit: Type.Optional(Type.Integer({ default: 10 })),
})

export const Response = Type.Object({
  users: Type.Array(TMinUserInfo),
})

export const handler = async (
  input: Static<typeof Input>,
  { currentUserId }: Context,
): Promise<Static<typeof Response>> => {
  const query = input.q.trim().replace(/^@/, "")
  if (query.length < 2 || query.includes("@") || /^\+?[\d\s().-]+$/.test(query)) {
    return { users: [] }
  }

  const rate = searchLimiter.consume({
    key: `search-contacts:${currentUserId}`,
    nowMs: Date.now(),
    rule: { max: 60, windowMs: 60_000 },
  })
  if (!rate.allowed) {
    throw new InlineError(InlineError.ApiError.FLOOD)
  }

  const requestedLimit = input.limit ?? 10
  const limit = Math.min(Math.max(requestedLimit, 1), SEARCH_LIMIT)

  const users = await UsersModel.searchUsers({
    query,
    limit,
    excludeUserId: currentUserId,
    includeBotCreatorId: currentUserId,
  })

  return { users: users.map((u) => encodeMinUserInfo(u.user, { photoFile: u.photoFile ?? undefined })) }
}
