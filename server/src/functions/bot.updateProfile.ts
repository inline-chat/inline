import { db } from "@in/server/db"
import { users } from "@in/server/db/schema/users"
import { files } from "@in/server/db/schema/files"
import { getFileByUniqueId } from "@in/server/db/models/files"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { and, eq } from "drizzle-orm"
import type { FunctionContext } from "@in/server/functions/_types"
import type { UpdateBotProfileInput, UpdateBotProfileResult } from "@inline-chat/protocol/core"

export const updateBotProfile = async (
  input: UpdateBotProfileInput,
  context: FunctionContext,
): Promise<UpdateBotProfileResult> => {
  const botUserId = Number(input.botUserId)

  if (!Number.isFinite(botUserId) || botUserId <= 0) {
    throw RealtimeRpcError.BadRequest()
  }

  const [bot] = await db
    .select()
    .from(users)
    .where(and(eq(users.id, botUserId), eq(users.bot, true)))
    .limit(1)

  if (!bot || bot.botCreatorId !== context.currentUserId) {
    throw RealtimeRpcError.UserIdInvalid()
  }

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

  const [row] = await db
    .select({ bot: users, photo: files })
    .from(users)
    .leftJoin(files, eq(users.photoFileId, files.id))
    .where(eq(users.id, botUserId))
    .limit(1)

  if (!row) {
    throw RealtimeRpcError.InternalError()
  }

  return {
    bot: Encoders.user({
      user: row.bot,
      photoFile: row.photo ?? undefined,
      min: false,
    }),
  }
}

