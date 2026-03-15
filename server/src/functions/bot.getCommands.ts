import type { FunctionContext } from "@in/server/functions/_types"
import type { GetBotCommandsInput, GetBotCommandsResult } from "@inline-chat/protocol/core"
import { BotCommandsModel } from "@in/server/db/models/botCommands"
import { getOwnedBotOrThrow, toProtocolBotCommand } from "./bot.commandsShared"

export const getBotCommands = async (
  input: GetBotCommandsInput,
  context: FunctionContext,
): Promise<GetBotCommandsResult> => {
  const botUserId = Number(input.botUserId)
  await getOwnedBotOrThrow(botUserId, context.currentUserId)

  const commands = await BotCommandsModel.getForBotUserId(botUserId)
  return {
    commands: commands.map(toProtocolBotCommand),
  }
}
