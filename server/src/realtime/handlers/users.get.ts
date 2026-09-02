import type { GetUsersInput, GetUsersResult } from "@inline-chat/protocol/core"
import { UsersModel } from "@in/server/db/models/users"
import { InMemoryRateLimiter } from "@in/server/modules/oauth/rateLimiter"
import { encodePublicUser } from "@in/server/modules/privacy/userPrivacy"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { HandlerContext } from "@in/server/realtime/types"

const lookupLimiter = new InMemoryRateLimiter({ capacity: 10_000 })

export async function getUsersHandler(input: GetUsersInput, context: HandlerContext): Promise<GetUsersResult> {
  if (input.userIds.length > 50 || input.userIds.some((id) => id <= 0n || id > BigInt(Number.MAX_SAFE_INTEGER))) {
    throw RealtimeRpcError.BadRequest()
  }
  const ids = [...new Set(input.userIds.map(Number))]
  if (ids.length === 0) return { users: [] }
  if (!lookupLimiter.consume({
    key: `get-users:${context.userId}`,
    nowMs: Date.now(),
    rule: { max: 60, windowMs: 60_000 },
  }).allowed) {
    throw RealtimeRpcError.RateLimit()
  }

  // Global-search visibility controls discovery, not lookup of a known public ID.
  // Match the existing getUser contract, never returning private contact/presence fields.
  const rows = await UsersModel.getActiveUsersWithPhoto(ids)
  const profiles = new Map(rows.map((row) => [row.user.id, encodePublicUser(row)]))
  return { users: ids.flatMap((id) => profiles.get(id) ?? []) }
}
