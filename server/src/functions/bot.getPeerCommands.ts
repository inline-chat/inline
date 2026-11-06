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
  const { botUserIdsByProximity } = await resolvePeerBotScope(input.peerId, context.currentUserId)
  if (botUserIdsByProximity.length === 0) {
    return { bots: [] }
  }

  const [botRows, commandsByBotUserId] = await Promise.all([
    UsersModel.getUsersWithPhotos(botUserIdsByProximity),
    BotCommandsModel.getForBotUserIds(botUserIdsByProximity),
  ])
  // Clients rank equally good matches by this order, so the bot you're talking to comes first.
  const proximity = new Map(botUserIdsByProximity.map((botUserId, index) => [botUserId, index]))
  botRows.sort((left, right) => (proximity.get(left.user.id) ?? 0) - (proximity.get(right.user.id) ?? 0))

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
