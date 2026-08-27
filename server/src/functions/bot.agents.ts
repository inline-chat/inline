import { BotAgentsModel } from "@in/server/db/models/botAgents"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type {
  CreateBotAgentInput,
  CreateBotAgentResult,
  GetBotAgentInput,
  GetBotAgentResult,
  ListBotAgentsInput,
  ListBotAgentsResult,
  DeleteBotAgentInput,
  DeleteBotAgentResult,
  UpdateBotAgentInput,
  UpdateBotAgentResult,
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

const patchOptionalText = (
  value: string | undefined,
  maxLength: number,
): string | null | undefined => {
  if (value === undefined) return undefined
  return boundedOptionalText(value, maxLength) ?? null
}

const parseAgentId = (value: bigint): number => {
  const agentId = Number(value)
  if (!Number.isSafeInteger(agentId) || agentId <= 0) throw RealtimeRpcError.BadRequest()
  return agentId
}

const requireManageableAgent = async (agentId: number, context: FunctionContext) => {
  const agent = await BotAgentsModel.get(agentId)
  if (!agent) throw RealtimeRpcError.BadRequest()
  await requireManageableBot(Number(agent.botUserId), context)
  return agent
}

export const createBotAgent = async (
  input: CreateBotAgentInput,
  context: FunctionContext,
): Promise<CreateBotAgentResult> => {
  const botUserId = parseBotUserId(input.botUserId)
  await requireManageableBot(botUserId, context)
  return {
    agent: await BotAgentsModel.create({
      botUserId,
      name: requiredName(input.name),
      handle: boundedOptionalText(input.handle, 256),
      emoji: boundedOptionalText(input.emoji, 64),
      description: boundedOptionalText(input.description, 4_000),
      skillKey: boundedOptionalText(input.skillKey, 256),
      instructions: boundedOptionalText(input.instructions, 32_000),
    }),
  }
}

export const getBotAgent = async (
  input: GetBotAgentInput,
  context: FunctionContext,
): Promise<GetBotAgentResult> => {
  const agentId = parseAgentId(input.agentId)
  const agent = await requireManageableAgent(agentId, context)
  const botUserId = Number(agent.botUserId)
  return { bot: await encodeBotWithAvatar(botUserId), agent }
}

export const listBotAgents = async (
  input: ListBotAgentsInput,
  context: FunctionContext,
): Promise<ListBotAgentsResult> => {
  const botUserId = parseBotUserId(input.botUserId)
  await requireManageableBot(botUserId, context)
  return { agents: await BotAgentsModel.list(botUserId) }
}

export const updateBotAgent = async (
  input: UpdateBotAgentInput,
  context: FunctionContext,
): Promise<UpdateBotAgentResult> => {
  const agentId = parseAgentId(input.agentId)
  await requireManageableAgent(agentId, context)

  const hasPatch = [
    input.name,
    input.handle,
    input.emoji,
    input.description,
    input.skillKey,
    input.instructions,
  ].some((value) => value !== undefined)
  if (!hasPatch) throw RealtimeRpcError.BadRequest()

  const agent = await BotAgentsModel.update({
    agentId,
    name: input.name === undefined ? undefined : requiredName(input.name),
    handle: patchOptionalText(input.handle, 256),
    emoji: patchOptionalText(input.emoji, 64),
    description: patchOptionalText(input.description, 4_000),
    skillKey: patchOptionalText(input.skillKey, 256),
    instructions: patchOptionalText(input.instructions, 32_000),
  })
  if (!agent) throw RealtimeRpcError.BadRequest()
  return { agent }
}

export const deleteBotAgent = async (
  input: DeleteBotAgentInput,
  context: FunctionContext,
): Promise<DeleteBotAgentResult> => {
  const agentId = parseAgentId(input.agentId)
  await requireManageableAgent(agentId, context)
  if (!await BotAgentsModel.delete(agentId)) throw RealtimeRpcError.BadRequest()
  return { agentId: BigInt(agentId) }
}
