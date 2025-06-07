import { db } from "@in/server/db"
import { users } from "@in/server/db/schema/users"
import { generateToken, hashToken } from "@in/server/utils/auth"
import { SessionsModel } from "@in/server/db/models/sessions"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { Log } from "@in/server/utils/log"
import { checkUsernameAvailable } from "@in/server/methods/checkUsername"
import { normalizeUsername } from "@in/server/utils/normalize"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { SpaceModel } from "@in/server/db/models/spaces"

import { Member_Role, type CreateBotInput, type CreateBotResult } from "@in/protocol/core"
import type { FunctionContext } from "@in/server/functions/_types"

const log = new Log("createBot")

export const createBot = async (input: CreateBotInput, context: FunctionContext): Promise<CreateBotResult> => {
  // Validate input
  if (!input.name || input.name.trim().length === 0) {
    throw RealtimeRpcError.BadRequest
  }

  if (!input.username || input.username.trim().length < 2) {
    throw RealtimeRpcError.BadRequest
  }

  const normalizedUsername = normalizeUsername(input.username)

  // Check if username is available
  const isUsernameAvailable = await checkUsernameAvailable(normalizedUsername, {})
  if (!isUsernameAvailable) {
    throw RealtimeRpcError.BadRequest
  }

  // Create bot user
  const botUser = await db
    .insert(users)
    .values({
      firstName: input.name,
      username: normalizedUsername,
      bot: true,
      botCreatorId: context.currentUserId,
      pendingSetup: false,
      emailVerified: false,
      phoneVerified: false,
    })
    .returning()

  if (!botUser[0]) {
    log.error("Failed to create bot user", { input, currentUserId: context.currentUserId })
    throw RealtimeRpcError.InternalError
  }

  const bot = botUser[0]

  // Generate token for the bot
  const { token } = await generateToken(bot.id)

  // Create session for the bot (bots use web client type)
  await SessionsModel.create({
    userId: bot.id,
    tokenHash: hashToken(token),
    personalData: {},
    clientType: "web",
  })

  // Add bot to space if specified
  if (input.addToSpace) {
    try {
      const spaceId = Number(input.addToSpace)

      // Use the SpaceModel for better validation and error handling
      await SpaceModel.addUserToSpace(spaceId, bot.id, "member", {
        invitedBy: context.currentUserId,
      })

      log.info("Bot successfully added to space", {
        botId: bot.id,
        spaceId,
        creatorId: context.currentUserId,
      })
    } catch (error) {
      log.error("Failed to add bot to space", {
        botId: bot.id,
        spaceId: input.addToSpace,
        error,
      })
      // Don't throw here - bot creation succeeded, space invitation failed
      // The bot can still be used, just not in the specified space
    }
  }

  return {
    bot: Encoders.user({ user: bot, min: false }),
    token,
  }
}
