import { and, eq, isNull } from "drizzle-orm"
import { db } from "@in/server/db"
import { members, spaces, users } from "@in/server/db/schema"
import { AccessGuardsCache } from "@in/server/modules/authorization/accessGuardsCache"
import { connectionManager } from "@in/server/ws/connections"
import type { Transaction } from "@in/server/db/types"

type MembershipQuery = Pick<typeof db, "select"> | Pick<Transaction, "select">

type SpaceMembershipGenerationInput = {
  spaceId: number
  userId: number
  memberId: number
}

/** Returns the current membership only while its Space remains authoritative. */
export async function getCurrentSpaceMembership(
  spaceId: number,
  userId: number,
  query: MembershipQuery = db,
) {
  const [current] = await query
    .select({ member: members })
    .from(members)
    .innerJoin(spaces, eq(spaces.id, members.spaceId))
    .where(and(
      eq(members.spaceId, spaceId),
      eq(members.userId, userId),
      isNull(spaces.deleted),
    ))
    .limit(1)
  return current?.member
}

/**
 * Publishes a committed add only if that exact membership is still current.
 * If a newer generation won, repair process-local subscription/cache state to
 * that generation without letting the stale add become authoritative.
 */
export async function activateCommittedSpaceMembership(
  input: SpaceMembershipGenerationInput,
  publishAdd?: () => undefined,
): Promise<boolean> {
  return withLockedMembership(input, (current) => {
    if (!current) {
      connectionManager.unsubscribeUserFromSpace(input.userId, input.spaceId)
      resetMembershipCache(input)
      return false
    }

    connectionManager.activateSpaceMembership(input.userId, input.spaceId)
    resetMembershipCache(input)
    AccessGuardsCache.setSpaceMember(input.spaceId, input.userId)
    const isCurrent = current.id === input.memberId
    if (isCurrent) publishAdd?.()
    return isCurrent
  })
}

/**
 * Publishes a committed removal only if no current nondeleted membership has
 * superseded it. A winning re-add is activated instead.
 */
export async function deactivateCommittedSpaceMembership(
  input: SpaceMembershipGenerationInput,
  publishRemoval?: () => undefined,
): Promise<boolean> {
  return withLockedMembership(input, (current) => {
    if (current) {
      connectionManager.activateSpaceMembership(input.userId, input.spaceId)
      resetMembershipCache(input)
      AccessGuardsCache.setSpaceMember(input.spaceId, input.userId)
      return false
    }

    connectionManager.unsubscribeUserFromSpace(input.userId, input.spaceId)
    resetMembershipCache(input)
    publishRemoval?.()
    return true
  })
}

/**
 * The authority mutation has already committed. Reuse its user -> Space lock
 * order while projecting it so another process cannot commit a re-add between
 * the DB check and an unsequenced eviction. The callback may only synchronously
 * queue process-local events: never await a provider, another DB connection, or
 * network I/O while these owners are locked.
 */
async function withLockedMembership(
  input: SpaceMembershipGenerationInput,
  project: (current: Awaited<ReturnType<typeof getCurrentSpaceMembership>>) => boolean,
): Promise<boolean> {
  return db.transaction(async (tx) => {
    await tx.select({ id: users.id }).from(users).where(eq(users.id, input.userId)).for("update").limit(1)
    await tx.select({ id: spaces.id }).from(spaces).where(eq(spaces.id, input.spaceId)).for("update").limit(1)
    const current = await getCurrentSpaceMembership(input.spaceId, input.userId, tx)
    return project(current)
  }).catch((error: unknown) => {
    // Future Grid events use cached Space subscribers. If authority cannot be
    // checked, stop that fanout without inventing a possibly stale UI eviction.
    // A legitimate concurrent re-add can hydrate again on its next connection.
    connectionManager.unsubscribeUserFromSpace(input.userId, input.spaceId)
    resetMembershipCache(input)
    throw error
  })
}

function resetMembershipCache(input: SpaceMembershipGenerationInput): void {
  AccessGuardsCache.resetForUser(input.userId)
  AccessGuardsCache.resetSpaceMember(input.spaceId, input.userId)
}
