import { db } from "@in/server/db"
import { userNotDeleted, users } from "@in/server/db/schema/users"
import { files } from "@in/server/db/schema/files"
import { botAvatarAssets } from "@in/server/db/schema/botAvatarAssets"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { agentGrants } from "@in/server/db/schema"
import { and, asc, eq, inArray, isNull, or, sql } from "drizzle-orm"
import type { FunctionContext } from "@in/server/functions/_types"
import { AgentGrantOperation, type ListBotsInput, type ListBotsResult } from "@inline-chat/protocol/core"

/** The caller's bots, and on request the ones they manage as an admin (a CONFIGURE grant naming them). */
export const listBots = async (input: ListBotsInput, context: FunctionContext): Promise<ListBotsResult> => {
  const managedIds = input.includeManaged === true
    ? (await db
        .select({ botUserId: agentGrants.botUserId })
        .from(agentGrants)
        .where(and(
          eq(agentGrants.subjectUserId, context.currentUserId),
          isNull(agentGrants.revokedAt),
          sql`(${agentGrants.operations} & ${1 << AgentGrantOperation.CONFIGURE}) <> 0`,
        ))).map((row) => row.botUserId)
    : []
  const botRows = await db
    .select({ bot: users, photo: files })
    .from(users)
    .leftJoin(files, eq(users.photoFileId, files.id))
    .where(
      and(
        eq(users.bot, true),
        managedIds.length > 0
          ? or(eq(users.botCreatorId, context.currentUserId), inArray(users.id, managedIds))
          : eq(users.botCreatorId, context.currentUserId),
        userNotDeleted(),
      ),
    )
    // Own bots first, then managed ones.
    .orderBy(sql`(${users.botCreatorId} = ${context.currentUserId}) desc`, asc(users.id))

  const botIds = botRows.map((row) => row.bot.id)
  const avatarRows =
    botIds.length > 0
      ? await db
          .select({ avatar: botAvatarAssets, file: files })
          .from(botAvatarAssets)
          .innerJoin(files, eq(botAvatarAssets.fileId, files.id))
          .where(inArray(botAvatarAssets.botUserId, botIds))
      : []
  const avatarsByBotId = new Map(avatarRows.map((row) => [row.avatar.botUserId, row]))

  return {
    bots: botRows.map((row) => {
      const avatar = avatarsByBotId.get(row.bot.id)
      return Encoders.user({
        user: row.bot,
        photoFile: row.photo ?? undefined,
        botAvatar: avatar?.avatar,
        botAvatarFile: avatar?.file,
        min: false,
      })
    }),
  }
}
