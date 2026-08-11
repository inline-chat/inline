import { db } from "@in/server/db"
import { lower, spaces, users } from "@in/server/db/schema"
import type { Transaction } from "@in/server/db/types"
import { isReservedUsername } from "@in/server/modules/users/reservedUsernames"
import { normalizeUsername } from "@in/server/utils/normalize"
import { eq, sql } from "drizzle-orm"

export const MAX_SPACE_HANDLE_LENGTH = 256

export function normalizeSpaceHandle(value: string): string | null {
  const handle = normalizeUsername(value)
  if (handle.length < 2 || handle.length > MAX_SPACE_HANDLE_LENGTH || isReservedUsername(handle)) {
    return null
  }
  return handle
}

type PublicHandleQuery = Pick<typeof db, "select">

export type PublicHandleOwner = {
  userId?: number
  spaceId?: number
}

export type PublicHandleAvailability = "available" | "current" | "taken"

/** Serializes server-mediated claims across the user and space handle tables. */
export async function lockPublicHandleNamespace(tx: Transaction, value: string): Promise<void> {
  const handle = normalizeUsername(value).toLowerCase()
  await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${handle}, 0))`)
}

export async function getPublicHandleAvailability(
  query: PublicHandleQuery,
  value: string,
  owner: PublicHandleOwner = {},
): Promise<PublicHandleAvailability> {
  const handle = normalizeUsername(value).toLowerCase()
  const [user] = await query
    .select({ id: users.id })
    .from(users)
    .where(eq(lower(users.username), handle))
    .limit(1)
  const [space] = await query
    .select({ id: spaces.id })
    .from(spaces)
    .where(eq(lower(spaces.handle), handle))
    .limit(1)

  if ((user && user.id !== owner.userId) || (space && space.id !== owner.spaceId)) {
    return "taken"
  }
  if (user || space) {
    return "current"
  }
  return "available"
}

export function isSpaceHandleUniqueError(error: unknown): boolean {
  if (!error || typeof error !== "object") return false

  const record = error as Record<string, unknown>
  return (
    record["code"] === "23505" &&
    (record["constraint"] === "spaces_handle_unique" ||
      record["constraint_name"] === "spaces_handle_unique" ||
      String(record["message"] ?? "").includes("spaces_handle_unique"))
  )
}
