import { db } from "@in/server/db"
import { members, spaces } from "@in/server/db/schema"
import type { FunctionContext } from "@in/server/functions/_types"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import type { GetSpacesInput, GetSpacesResult } from "@inline-chat/protocol/core"
import { and, asc, eq, isNull } from "drizzle-orm"

/** Every non-deleted space the viewer is a member of. Small and unpaged. */
export async function getSpaces(_input: GetSpacesInput, context: FunctionContext): Promise<GetSpacesResult> {
  const rows = await db
    .select({ space: spaces })
    .from(members)
    .innerJoin(spaces, eq(spaces.id, members.spaceId))
    .where(and(eq(members.userId, context.currentUserId), isNull(spaces.deleted)))
    .orderBy(asc(spaces.id))
  return {
    spaces: rows.map((row) => Encoders.space(row.space, { encodingForUserId: context.currentUserId })),
  }
}
