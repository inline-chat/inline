import { db } from "@in/server/db"
import { botSkills, type DbBotSkill } from "@in/server/db/schema"
import { asc, eq } from "drizzle-orm"

export type NormalizedBotSkill = {
  key: string
  name: string
  description?: string
  sortOrder: number
}

export const BotSkillsModel = {
  async getForBotUserId(botUserId: number): Promise<DbBotSkill[]> {
    return db
      .select()
      .from(botSkills)
      .where(eq(botSkills.botUserId, botUserId))
      .orderBy(asc(botSkills.sortOrder), asc(botSkills.name), asc(botSkills.key))
  },

  async replaceForBotUserId(botUserId: number, skills: NormalizedBotSkill[]): Promise<DbBotSkill[]> {
    return db.transaction(async (tx) => {
      await tx.delete(botSkills).where(eq(botSkills.botUserId, botUserId))

      if (skills.length === 0) {
        return []
      }

      const now = new Date()
      const inserted = await tx
        .insert(botSkills)
        .values(
          skills.map((skill) => ({
            botUserId,
            key: skill.key,
            name: skill.name,
            description: skill.description,
            sortOrder: skill.sortOrder,
            createdAt: now,
            updatedAt: now,
          })),
        )
        .returning()

      return inserted.sort(compareBotSkills)
    })
  },

  async deleteForBotUserId(botUserId: number): Promise<void> {
    await db.delete(botSkills).where(eq(botSkills.botUserId, botUserId))
  },
}

function compareBotSkills(left: DbBotSkill, right: DbBotSkill): number {
  if (left.sortOrder !== right.sortOrder) {
    return left.sortOrder - right.sortOrder
  }
  const nameOrder = left.name.localeCompare(right.name)
  return nameOrder === 0 ? left.key.localeCompare(right.key) : nameOrder
}
