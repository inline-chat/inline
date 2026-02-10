import { db } from "@in/server/db"
import { botTokens } from "@in/server/db/schema/botTokens"
import { users } from "@in/server/db/schema/users"
import { BotTokensModel } from "@in/server/db/models/botTokens"
import { SessionsModel } from "@in/server/db/models/sessions"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { generateToken, hashToken } from "@in/server/utils/auth"
import { and, eq } from "drizzle-orm"
import type { FunctionContext } from "@in/server/functions/_types"
import type { RotateBotTokenInput, RotateBotTokenResult } from "@inline-chat/protocol/core"

export const rotateBotToken = async (
  input: RotateBotTokenInput,
  context: FunctionContext,
): Promise<RotateBotTokenResult> => {
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

  // If there is an existing session for the current token, we revoke it after
  // issuing the new token so the previous token becomes invalid immediately.
  const [existing] = await db
    .select({ sessionId: botTokens.sessionId })
    .from(botTokens)
    .where(eq(botTokens.botUserId, botUserId))
    .limit(1)

  const { token } = await generateToken(botUserId)

  const session = await SessionsModel.create({
    userId: botUserId,
    tokenHash: hashToken(token),
    personalData: {},
    clientType: "api",
  })

  await BotTokensModel.upsert({
    botUserId,
    sessionId: session.id,
    token,
  })

  if (existing?.sessionId) {
    await SessionsModel.revoke(existing.sessionId)
  }

  return { token }
}

