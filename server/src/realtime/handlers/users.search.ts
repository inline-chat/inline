import type { SearchUsersInput, SearchUsersResult } from "@inline-chat/protocol/core"
import { UsersModel } from "@in/server/db/models/users"
import { InMemoryRateLimiter } from "@in/server/modules/oauth/rateLimiter"
import { encodePublicUser } from "@in/server/modules/privacy/userPrivacy"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { HandlerContext } from "@in/server/realtime/types"

const searchLimiter = new InMemoryRateLimiter({ capacity: 10_000 })
const SEARCH_LIMIT = 20

export async function searchUsersHandler(
  input: SearchUsersInput,
  context: HandlerContext,
): Promise<SearchUsersResult> {
  const query = input.query.trim().replace(/^@/, "")
  if (query.length < 2 || query.includes("@") || /^\+?[\d\s().-]+$/.test(query)) {
    return { users: [] }
  }

  const rate = searchLimiter.consume({
    key: `search-users:${context.userId}`,
    nowMs: Date.now(),
    rule: { max: 60, windowMs: 60_000 },
  })
  if (!rate.allowed) {
    throw RealtimeRpcError.RateLimit()
  }

  const requestedLimit = input.limit ?? SEARCH_LIMIT
  const limit = Math.min(Math.max(requestedLimit, 1), SEARCH_LIMIT)
  const matches = await UsersModel.searchUsers({
    query,
    limit,
    excludeUserId: context.userId,
  })

  return {
    users: matches.map(({ user, photoFile }) => encodePublicUser({ user, photoFile })),
  }
}
