import type { GetUsersInput, GetUsersResult } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { UsersModel } from "@in/server/db/models/users"
import { dialogs, type DbUser } from "@in/server/db/schema"
import { InMemoryRateLimiter } from "@in/server/modules/oauth/rateLimiter"
import { encodePublicUser } from "@in/server/modules/privacy/userPrivacy"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { HandlerContext } from "@in/server/realtime/types"
import { and, eq, inArray } from "drizzle-orm"

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
  // Match the existing getUser contract, never returning private contact fields.
  // Presence is only a bot's, and only for its owner or someone with a DM with it.
  const rows = await UsersModel.getActiveUsersWithPhoto(ids)
  const botStatusIds = await botStatusAudienceIds(
    context.userId,
    rows.flatMap(({ user }) => (user.bot === true ? [user] : [])),
  )
  const profiles = new Map(rows.map((row) => [
    row.user.id,
    encodePublicUser(row, { includeBotStatus: botStatusIds.has(row.user.id) }),
  ]))
  return { users: ids.flatMap((id) => profiles.get(id) ?? []) }
}

/** Bots whose presence the viewer may see: ones they own or have a DM with. */
async function botStatusAudienceIds(viewerUserId: number, bots: DbUser[]): Promise<Set<number>> {
  const visible = new Set(bots.flatMap((bot) => (bot.botCreatorId === viewerUserId ? [bot.id] : [])))
  const others = bots.flatMap((bot) => (visible.has(bot.id) ? [] : [bot.id]))
  if (others.length === 0) return visible
  const rows = await db
    .select({ peerUserId: dialogs.peerUserId })
    .from(dialogs)
    .where(and(eq(dialogs.userId, viewerUserId), inArray(dialogs.peerUserId, others)))
  for (const { peerUserId } of rows) if (peerUserId !== null) visible.add(peerUserId)
  return visible
}
