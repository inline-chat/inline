import { db } from "@in/server/db"
import { botAvatarAssets } from "@in/server/db/schema"
import { eq } from "drizzle-orm"
import type { ClearBotAvatarInput, ClearBotAvatarResult } from "@inline-chat/protocol/core"
import type { FunctionContext } from "./_types"
import { encodeBotWithAvatar, notifyBotAvatarChanged, parseBotUserId, requireManageableBot } from "./bot.avatarHelpers"

export const clearBotAvatar = async (
  input: ClearBotAvatarInput,
  context: FunctionContext,
): Promise<ClearBotAvatarResult> => {
  const botUserId = parseBotUserId(input.botUserId)
  await requireManageableBot(botUserId, context)

  await db.delete(botAvatarAssets).where(eq(botAvatarAssets.botUserId, botUserId))

  const bot = await encodeBotWithAvatar(botUserId)
  await notifyBotAvatarChanged(botUserId)
  return { bot }
}
