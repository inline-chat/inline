import { chats, spaces } from "@in/server/db/schema"
import type { Transaction } from "@in/server/db/types"
import { eq, sql } from "drizzle-orm"

export async function allocateSpaceThreadNumber(tx: Transaction, spaceId: number): Promise<number> {
  await tx.select({ id: spaces.id }).from(spaces).where(eq(spaces.id, spaceId)).for("update").limit(1)

  const [row] = await tx
    .select({ maxThreadNumber: sql<number>`coalesce(max(${chats.threadNumber}), 0)::int` })
    .from(chats)
    .where(eq(chats.spaceId, spaceId))

  return (row?.maxThreadNumber ?? 0) + 1
}
