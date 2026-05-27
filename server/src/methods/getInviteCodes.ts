import { eq, desc } from "drizzle-orm"
import { Type, type Static } from "@sinclair/typebox"
import type { HandlerContext } from "@in/server/controllers/helpers"
import { db } from "@in/server/db"
import { inviteCodes } from "@in/server/db/schema"

export const Input = Type.Object({})

export const Response = Type.Object({
  codes: Type.Array(
    Type.Object({
      code: Type.String(),
      redeemed: Type.Boolean(),
      redeemedAt: Type.Optional(Type.String()),
    }),
  ),
})

export const handler = async (
  _: Static<typeof Input>,
  context: HandlerContext,
): Promise<Static<typeof Response>> => {
  const rows = await db
    .select({
      code: inviteCodes.code,
      redeemedAt: inviteCodes.redeemedAt,
      date: inviteCodes.date,
    })
    .from(inviteCodes)
    .where(eq(inviteCodes.ownerUserId, context.currentUserId))
    .orderBy(desc(inviteCodes.date))

  return {
    codes: rows.map((row) => ({
      code: row.code,
      redeemed: row.redeemedAt != null,
      redeemedAt: row.redeemedAt ? row.redeemedAt.toISOString() : undefined,
    })),
  }
}
