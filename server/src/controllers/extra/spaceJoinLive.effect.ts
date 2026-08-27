import { db } from "@in/server/db"
import { lower, spaceInviteLinks, spaces } from "@in/server/db/schema"
import {
  hashSpaceInviteToken,
  isValidSpaceInviteToken,
  normalizePublicJoinHandle,
} from "@in/server/modules/spaces/spaceInviteLinks"
import { InMemoryRateLimiter } from "@in/server/modules/oauth/rateLimiter"
import { and, eq, gt, isNull } from "drizzle-orm"
import { Effect, Layer } from "effect"
import {
  SpaceJoinOperations,
  makeSpaceJoinOperations,
  type SpaceJoinResolveInput,
} from "./spaceJoin.effect"

export const resolveSpaceJoinName = async (
  input: SpaceJoinResolveInput,
): Promise<{ name: string } | null> => {
  if (input.kind === "public_handle") {
    const normalizedHandle = normalizePublicJoinHandle(input.value)
    if (!normalizedHandle) return null
    const handle = normalizedHandle.toLowerCase()
    const [space] = await db
      .select({ name: spaces.name })
      .from(spaces)
      .where(and(
        eq(lower(spaces.handle), handle),
        eq(spaces.isPublic, true),
        eq(spaces.canPublicJoin, true),
        isNull(spaces.deleted),
      ))
      .limit(1)
    return space ?? null
  }

  if (!isValidSpaceInviteToken(input.value)) return null
  const [space] = await db
    .select({ name: spaces.name })
    .from(spaceInviteLinks)
    .innerJoin(spaces, eq(spaces.id, spaceInviteLinks.spaceId))
    .where(and(
      eq(spaceInviteLinks.tokenHash, hashSpaceInviteToken(input.value)),
      isNull(spaceInviteLinks.revokedAt),
      gt(spaceInviteLinks.expiresAt, new Date()),
      eq(spaces.isPublic, false),
      isNull(spaces.deleted),
    ))
    .limit(1)
  return space ?? null
}

export const SpaceJoinOperationsLive = Layer.effect(
  SpaceJoinOperations,
  Effect.acquireRelease(
    Effect.sync(() => new InMemoryRateLimiter({ capacity: 50_000 })),
    (limiter) => Effect.sync(() => limiter.clear()),
  ).pipe(
    Effect.map((limiter) => makeSpaceJoinOperations({
      limiter,
      resolve: resolveSpaceJoinName,
    })),
  ),
)
