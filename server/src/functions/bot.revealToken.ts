import { db } from "@in/server/db"
import { users } from "@in/server/db/schema/users"
import { BotTokensModel } from "@in/server/db/models/botTokens"
import { SessionsModel } from "@in/server/db/models/sessions"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { generateToken, hashToken } from "@in/server/utils/auth"
import { and, eq } from "drizzle-orm"
import type { FunctionContext } from "@in/server/functions/_types"
import type { RevealBotTokenInput, RevealBotTokenResult } from "@inline-chat/protocol/core"

export const revealBotToken = async (
  input: RevealBotTokenInput,
  context: FunctionContext,
): Promise<RevealBotTokenResult> => {
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

  let token = await BotTokensModel.getTokenByBotUserId(botUserId)
  if (!token) {
    const generated = await generateToken(botUserId)
    const session = await SessionsModel.create({
      userId: botUserId,
      tokenHash: hashToken(generated.token),
      personalData: {},
      clientType: "api",
    })
    await BotTokensModel.upsert({
      botUserId,
      sessionId: session.id,
      token: generated.token,
    })
    token = generated.token
  }

  return { token }
}
