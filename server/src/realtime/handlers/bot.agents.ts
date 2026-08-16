import { createBotAgent, getBotAgent, listBotAgents } from "@in/server/functions/bot.agents"
import type { HandlerContext } from "@in/server/realtime/types"
import type {
  CreateBotAgentInput,
  CreateBotAgentResult,
  GetBotAgentInput,
  GetBotAgentResult,
  ListBotAgentsInput,
  ListBotAgentsResult,
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
