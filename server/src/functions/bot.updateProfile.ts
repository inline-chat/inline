import { db } from "@in/server/db"
import { users } from "@in/server/db/schema/users"
import { getFileByUniqueId } from "@in/server/db/models/files"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { eq } from "drizzle-orm"
import type { FunctionContext } from "@in/server/functions/_types"
import type { UpdateBotProfileInput, UpdateBotProfileResult } from "@inline-chat/protocol/core"
import { encodeBotWithAvatar, parseBotUserId, requireManageableBot } from "./bot.avatarHelpers"

export const updateBotProfile = async (
  input: UpdateBotProfileInput,
  context: FunctionContext,
): Promise<UpdateBotProfileResult> => {
  const botUserId = parseBotUserId(input.botUserId)
  await requireManageableBot(botUserId, context)

  const updates: Partial<typeof users.$inferInsert> = {}

  if (input.name !== undefined) {
    const trimmed = input.name.trim()
    if (!trimmed) {
      throw RealtimeRpcError.BadRequest()
    }
    updates.firstName = trimmed
  }

  if (input.photoFileUniqueId !== undefined) {
    const trimmed = input.photoFileUniqueId.trim()
    if (!trimmed) {
      throw RealtimeRpcError.BadRequest()
    }

    const file = await getFileByUniqueId(trimmed)
    if (!file || file.userId !== context.currentUserId) {
      throw RealtimeRpcError.BadRequest()
    }

    updates.photoFileId = file.id
  }

  // No-op updates are allowed (e.g. user opens sheet and presses save).
  if (Object.keys(updates).length > 0) {
    await db.update(users).set(updates).where(eq(users.id, botUserId))
  }

  return {
    bot: await encodeBotWithAvatar(botUserId),
  }
}
