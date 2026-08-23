import { BotAgentsModel } from "@in/server/db/models/botAgents"
import { getServerConfig } from "@in/server/modules/serverConfig"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type {
  CreateBotAgentInput,
  CreateBotAgentResult,
  GetBotAgentInput,
  GetBotAgentResult,
  ListBotAgentsInput,
  ListBotAgentsResult,
} from "@inline-chat/protocol/core"
import type { FunctionContext } from "./_types"
import { encodeBotWithAvatar, parseBotUserId, requireManageableBot } from "./bot.avatarHelpers"

const requiredName = (value: string): string => {
  const name = value.trim()
  if (!name || name.length > 256) throw RealtimeRpcError.BadRequest()
  return name
}

const boundedOptionalText = (value: string | undefined, maxLength: number): string | undefined => {
  const text = value?.trim()
  if (!text) return undefined
  if (text.length > maxLength) throw RealtimeRpcError.BadRequest()
  return text
}

const requireAgentsEnabled = async (): Promise<void> => {
  if ((await getServerConfig("agents.rollout")).value !== "enabled") {
    throw RealtimeRpcError.BadRequest()
  }
}

export const createBotAgent = async (
  input: CreateBotAgentInput,
  context: FunctionContext,
): Promise<CreateBotAgentResult> => {
  await requireAgentsEnabled()
  const botUserId = parseBotUserId(input.botUserId)
  await requireManageableBot(botUserId, context)
  return {
    agent: await BotAgentsModel.create({
      botUserId,
      name: requiredName(input.name),
      handle: boundedOptionalText(input.handle, 256),
      emoji: boundedOptionalText(input.emoji, 64),
      description: input.description,
      skillKey: boundedOptionalText(input.skillKey, 256),
      instructions: input.instructions,
    }),
  }
}

export const getBotAgent = async (
  input: GetBotAgentInput,
  context: FunctionContext,
): Promise<GetBotAgentResult> => {
  await requireAgentsEnabled()
  const agentId = Number(input.agentId)
  if (!Number.isSafeInteger(agentId) || agentId <= 0) throw RealtimeRpcError.BadRequest()
  const agent = await BotAgentsModel.get(agentId)
  if (!agent) throw RealtimeRpcError.BadRequest()
  const botUserId = Number(agent.botUserId)
  await requireManageableBot(botUserId, context)
  return { bot: await encodeBotWithAvatar(botUserId), agent }
}

export const listBotAgents = async (
  input: ListBotAgentsInput,
  context: FunctionContext,
): Promise<ListBotAgentsResult> => {
  await requireAgentsEnabled()
  const botUserId = parseBotUserId(input.botUserId)
  await requireManageableBot(botUserId, context)
  return { agents: await BotAgentsModel.list(botUserId) }
}
