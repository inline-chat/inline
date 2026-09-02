import { getBotSkills } from "@in/server/functions/bot.getSkills"
import type { HandlerContext } from "@in/server/realtime/types"
import type { GetBotSkillsInput, GetBotSkillsResult } from "@inline-chat/protocol/core"

export const getBotSkillsHandler = async (
  input: GetBotSkillsInput,
  handlerContext: HandlerContext,
): Promise<GetBotSkillsResult> => {
  return getBotSkills(input, { currentUserId: handlerContext.userId })
}
