import { db } from "@in/server/db"
import { users } from "@in/server/db/schema/users"
import { files } from "@in/server/db/schema/files"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { and, asc, eq, isNull, or } from "drizzle-orm"
import type { FunctionContext } from "@in/server/functions/_types"
import type { ListBotsInput, ListBotsResult } from "@inline-chat/protocol/core"

export const listBots = async (_input: ListBotsInput, context: FunctionContext): Promise<ListBotsResult> => {
  const botRows = await db
    .select({ bot: users, photo: files })
    .from(users)
    .leftJoin(files, eq(users.photoFileId, files.id))
    .where(
      and(
        eq(users.bot, true),
        eq(users.botCreatorId, context.currentUserId),
        or(isNull(users.deleted), eq(users.deleted, false)),
      ),
    )
    .orderBy(asc(users.id))

  return {
    bots: botRows.map((row) =>
      Encoders.user({
        user: row.bot,
        photoFile: row.photo ?? undefined,
        min: false,
      }),
    ),
  }
}
