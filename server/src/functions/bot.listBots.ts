import { db } from "@in/server/db"
import { userNotDeleted, users } from "@in/server/db/schema/users"
import { files } from "@in/server/db/schema/files"
import { botAvatarAssets } from "@in/server/db/schema/botAvatarAssets"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { and, asc, eq, inArray } from "drizzle-orm"
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
        userNotDeleted(),
      ),
    )
    .orderBy(asc(users.id))

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
