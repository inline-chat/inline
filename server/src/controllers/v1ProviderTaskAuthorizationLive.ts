import { db } from "@in/server/db"
import { messages } from "@in/server/db/schema"
import { getAuthorizedChat } from "@in/server/modules/authorization/legacyAccessGuards"
import { Authorize } from "@in/server/utils/authorize"
import { and, eq } from "drizzle-orm"
import { makeProviderTaskAuthorizer } from "./v1ProviderTaskAuthorization"

export const authorizeProviderTask = makeProviderTaskAuthorizer({
  getAuthorizedChat,
  hasMessage: async (chatId, messageId) => {
    const [message] = await db
      .select({ messageId: messages.messageId })
      .from(messages)
      .where(
        and(
          eq(messages.chatId, chatId),
          eq(messages.messageId, messageId),
        ),
      )
      .limit(1)
    return message !== undefined
  },
  requireSpaceMember: async (spaceId, userId) => {
    await Authorize.spaceMember(spaceId, userId)
  },
})
