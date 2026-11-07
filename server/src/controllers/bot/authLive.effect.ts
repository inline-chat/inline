import { and, eq } from "drizzle-orm"
import { Layer } from "effect"
import { db } from "@in/server/db"
import {
  userNotDeleted,
  users,
} from "@in/server/db/schema/users"
import {
  BotAuthorization,
  makeBotAuthorization,
} from "./auth.effect"
import { touchBotOnline } from "@in/server/modules/bots/online"

export const BotAuthorizationLive = Layer.succeed(
  BotAuthorization,
  makeBotAuthorization({
    isBot: async (userId) => {
      const row = await db
        .select({ bot: users.bot })
        .from(users)
        .where(
          and(eq(users.id, userId), userNotDeleted()),
        )
        .limit(1)
      const isBot = row[0]?.bot === true
      // Every authenticated Bot API call counts as the bot being online.
      if (isBot) touchBotOnline(userId)
      return isBot
    },
  }),
)
