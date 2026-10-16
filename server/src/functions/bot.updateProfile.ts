import { db } from "@in/server/db"
import { users } from "@in/server/db/schema/users"
import { getFileByUniqueId } from "@in/server/db/models/files"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { eq } from "drizzle-orm"
import type { FunctionContext } from "@in/server/functions/_types"
import type { UpdateBotProfileInput, UpdateBotProfileResult } from "@inline-chat/protocol/core"
import { encodeBotWithAvatar, parseBotUserId, requireManageableBot } from "./bot.avatarHelpers"
import { publishCacheInvalidation } from "@in/server/modules/cache/cluster"
import { isValidUsername, normalizeUsername } from "@in/server/utils/normalize"
import {
  getPublicHandleAvailability,
  lockPublicHandleNamespace,
} from "@in/server/modules/spaces/spaceHandle"

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
    updates.lastName = null
  }

  if (input.photoFileUniqueId !== undefined) {
    const trimmed = input.photoFileUniqueId.trim()
    if (!trimmed) {
      updates.photoFileId = null
    } else {
      const file = await getFileByUniqueId(trimmed)
      if (!file || file.userId !== context.currentUserId) {
        throw RealtimeRpcError.BadRequest()
      }

      updates.photoFileId = file.id
    }
  }

  if (input.username !== undefined) {
    const username = normalizeUsername(input.username)
    if (!isValidUsername(username) || !username.toLowerCase().endsWith("bot")) {
      throw RealtimeRpcError.UsernameInvalid()
    }
    updates.username = username
  }

  // No-op updates are allowed (e.g. user opens sheet and presses save).
  if (Object.keys(updates).length > 0) {
    await db.transaction(async (tx) => {
      if (updates.username) {
        await lockPublicHandleNamespace(tx, updates.username)
        const availability = await getPublicHandleAvailability(tx, updates.username, { userId: botUserId })
        if (availability === "taken" || availability === "reserved") {
          throw RealtimeRpcError.UsernameTaken()
        }
      }
      await tx.update(users).set(updates).where(eq(users.id, botUserId))
    })
    publishCacheInvalidation({ kind: "userDisplay", userId: botUserId })
  }

  return {
    bot: await encodeBotWithAvatar(botUserId),
  }
}
