import { db, schema } from "@in/server/db"
import { userNotDeleted, users } from "@in/server/db/schema/users"
import { BotTokensModel } from "@in/server/db/models/botTokens"
import { revokeSession } from "@in/server/modules/sessions/revokeSession"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { and, eq, isNull } from "drizzle-orm"
import type { FunctionContext } from "@in/server/functions/_types"
import type { DeleteBotInput, DeleteBotResult } from "@inline-chat/protocol/core"

export const deleteBot = async (
  input: DeleteBotInput,
  context: FunctionContext,
): Promise<DeleteBotResult> => {
  const botUserId = Number(input.botUserId)

  if (!Number.isFinite(botUserId) || botUserId <= 0) {
    throw RealtimeRpcError.BadRequest()
  }

  const [bot] = await db
    .select()
    .from(users)
    .where(and(eq(users.id, botUserId), eq(users.bot, true), userNotDeleted()))
    .limit(1)

  if (!bot || bot.botCreatorId !== context.currentUserId) {
    throw RealtimeRpcError.UserIdInvalid()
  }

  const activeSessions = await db
    .select({ id: schema.sessions.id })
    .from(schema.sessions)
    .where(and(eq(schema.sessions.userId, botUserId), isNull(schema.sessions.revoked)))

  await db
    .update(users)
    .set({
      deleted: true,
      online: false,
    })
    .where(eq(users.id, botUserId))

  await BotTokensModel.deleteByBotUserId(botUserId)

  for (const session of activeSessions) {
    await revokeSession({
      actor: "system",
      targetUserId: botUserId,
      sessionId: session.id,
    })
  }

  return { botUserId: input.botUserId }
}
