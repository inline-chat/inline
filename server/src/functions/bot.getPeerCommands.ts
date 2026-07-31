import { BotCommandsModel } from "@in/server/db/models/botCommands"
import { UsersModel } from "@in/server/db/models/users"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import type { FunctionContext } from "@in/server/functions/_types"
import type { GetPeerBotCommandsInput, GetPeerBotCommandsResult } from "@inline-chat/protocol/core"
import { toProtocolBotCommand } from "./bot.commandsShared"
import { resolvePeerBotScope } from "./bot.peerDiscovery"

export const getPeerBotCommands = async (
  input: GetPeerBotCommandsInput,
  context: FunctionContext,
): Promise<GetPeerBotCommandsResult> => {
  const { botUserIds: uniqueBotUserIds } = await resolvePeerBotScope(input.peerId, context.currentUserId)
  if (uniqueBotUserIds.length === 0) {
    return { bots: [] }
  }

  const botRows = await UsersModel.getUsersWithPhotos(uniqueBotUserIds)
  const commandsByBotUserId = await BotCommandsModel.getForBotUserIds(uniqueBotUserIds)

  return {
    bots: botRows
      .filter((row) => (commandsByBotUserId.get(row.user.id)?.length ?? 0) > 0)
      .map((row) => ({
        bot: Encoders.user({
          user: row.user,
          photoFile: row.photoFile,
          min: false,
        }),
        commands: (commandsByBotUserId.get(row.user.id) ?? []).map(toProtocolBotCommand),
      })),
  }
}
