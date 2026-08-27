import {
  createBotAgent,
  deleteBotAgent,
  getBotAgent,
  listBotAgents,
  updateBotAgent,
} from "@in/server/functions/bot.agents"
import type { HandlerContext } from "@in/server/realtime/types"
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

const context = (handlerContext: HandlerContext) => ({
  currentSessionId: handlerContext.sessionId,
  currentUserId: handlerContext.userId,
})

export const createBotAgentHandler = (
  input: CreateBotAgentInput,
  handlerContext: HandlerContext,
): Promise<CreateBotAgentResult> => createBotAgent(input, context(handlerContext))

export const getBotAgentHandler = (
  input: GetBotAgentInput,
  handlerContext: HandlerContext,
): Promise<GetBotAgentResult> => getBotAgent(input, context(handlerContext))

export const listBotAgentsHandler = (
  input: ListBotAgentsInput,
  handlerContext: HandlerContext,
): Promise<ListBotAgentsResult> => listBotAgents(input, context(handlerContext))

export const updateBotAgentHandler = (
  input: UpdateBotAgentInput,
  handlerContext: HandlerContext,
): Promise<UpdateBotAgentResult> => updateBotAgent(input, context(handlerContext))

export const deleteBotAgentHandler = (
  input: DeleteBotAgentInput,
  handlerContext: HandlerContext,
): Promise<DeleteBotAgentResult> => deleteBotAgent(input, context(handlerContext))
