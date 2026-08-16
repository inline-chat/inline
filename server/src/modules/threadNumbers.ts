import { spaces, users } from "@in/server/db/schema"
import type { Transaction } from "@in/server/db/types"
import type { ScopeRef } from "@in/server/modules/scopes"
import { eq, sql } from "drizzle-orm"

export async function allocateThreadNumber(tx: Transaction, scope: ScopeRef): Promise<number> {
  if (scope.type === "space") {
    const [owner] = await tx
      .update(spaces)
      .set({ nextThreadNumber: sql`${spaces.nextThreadNumber} + 1` })
      .where(eq(spaces.id, scope.id))
      .returning({ nextThreadNumber: spaces.nextThreadNumber })

    if (!owner) throw new Error(`Space scope ${scope.id} does not exist`)
    return owner.nextThreadNumber - 1
  }

  const [owner] = await tx
    .update(users)
    .set({ nextThreadNumber: sql`${users.nextThreadNumber} + 1` })
    .where(eq(users.id, scope.id))
    .returning({ nextThreadNumber: users.nextThreadNumber })

  if (!owner) throw new Error(`User scope ${scope.id} does not exist`)
  return owner.nextThreadNumber - 1
}
