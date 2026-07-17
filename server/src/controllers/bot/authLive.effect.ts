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
      return row[0]?.bot === true
    },
  }),
)
