import type { BotSkill } from "@inline-chat/protocol/core"
import type { DbBotSkill } from "@in/server/db/schema"
import type { NormalizedBotSkill } from "@in/server/db/models/botSkills"
import { RealtimeRpcError } from "@in/server/realtime/errors"

export const BOT_SKILL_LIMIT = 250

export function normalizeProtocolBotSkills(skills: BotSkill[] | undefined): NormalizedBotSkill[] {
  if (!skills) {
    return []
  }
  if (skills.length > BOT_SKILL_LIMIT) {
    throw RealtimeRpcError.BadRequest()
  }

  const seenKeys = new Set<string>()
  return skills.map((skill, index) => {
    const key = skill.key.trim()
    const name = skill.name.trim()
    const description = normalizeOptionalText(skill.description)
    const sortOrder = skill.sortOrder ?? index

    if (
      key.length < 1 ||
      key.length > 256 ||
      name.length < 1 ||
      name.length > 256 ||
      (description?.length ?? 0) > 4_000 ||
      !Number.isInteger(sortOrder) ||
      sortOrder < -2_147_483_648 ||
      sortOrder > 2_147_483_647 ||
      seenKeys.has(key)
    ) {
      throw RealtimeRpcError.BadRequest()
    }

    seenKeys.add(key)
    return { key, name, description, sortOrder }
  })
}

export function toProtocolBotSkill(skill: DbBotSkill): BotSkill {
  return {
    key: skill.key,
    name: skill.name,
    description: skill.description ?? undefined,
    sortOrder: skill.sortOrder,
  }
}

function normalizeOptionalText(value: string | undefined): string | undefined {
  const normalized = value?.trim()
  return normalized ? normalized : undefined
}
