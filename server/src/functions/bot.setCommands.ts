import type { FunctionContext } from "@in/server/functions/_types"
import type { SetBotCommandsInput, SetBotCommandsResult } from "@inline-chat/protocol/core"
import { BotCommandsModel } from "@in/server/db/models/botCommands"
import { getOwnedBotOrThrow, normalizeProtocolBotCommands, toProtocolBotCommand } from "./bot.commandsShared"

export const setBotCommands = async (
  input: SetBotCommandsInput,
  context: FunctionContext,
): Promise<SetBotCommandsResult> => {
  const botUserId = Number(input.botUserId)
  await getOwnedBotOrThrow(botUserId, context.currentUserId)

  const normalizedCommands = normalizeProtocolBotCommands(input.commands)
  const commands = await BotCommandsModel.replaceForBotUserId(botUserId, normalizedCommands)

  return {
    commands: commands.map(toProtocolBotCommand),
  }
}
