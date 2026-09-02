import { BotSkillsModel } from "@in/server/db/models/botSkills"
import type { GetBotSkillsInput, GetBotSkillsResult } from "@inline-chat/protocol/core"
import { getOwnedBotOrThrow } from "./bot.commandsShared"
import { toProtocolBotSkill } from "./bot.skillsShared"

export const getBotSkills = async (
  input: GetBotSkillsInput,
  context: { currentUserId: number },
): Promise<GetBotSkillsResult> => {
  const botUserId = Number(input.botUserId)
  await getOwnedBotOrThrow(botUserId, context.currentUserId)
  const skills = await BotSkillsModel.getForBotUserId(botUserId)
  return { skills: skills.map(toProtocolBotSkill) }
}
