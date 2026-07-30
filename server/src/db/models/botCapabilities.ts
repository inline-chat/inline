import { db } from "@in/server/db"
import { botCapabilities, type DbBotCapability } from "@in/server/db/schema"
import { and, asc, eq, inArray, notInArray, sql } from "drizzle-orm"

export const BotCapabilitiesModel = {
  async getForBotUserId(botUserId: number): Promise<DbBotCapability[]> {
    return db
      .select()
      .from(botCapabilities)
      .where(eq(botCapabilities.botUserId, botUserId))
      .orderBy(asc(botCapabilities.kind))
  },

  async getForBotUserIds(botUserIds: number[]): Promise<Map<number, DbBotCapability[]>> {
    const uniqueIds = Array.from(new Set(botUserIds.filter((id) => Number.isSafeInteger(id) && id > 0)))
    if (uniqueIds.length === 0) return new Map()

    const rows = await db
      .select()
      .from(botCapabilities)
      .where(inArray(botCapabilities.botUserId, uniqueIds))
      .orderBy(asc(botCapabilities.botUserId), asc(botCapabilities.kind))

    const byBotUserId = new Map<number, DbBotCapability[]>()
    for (const row of rows) {
      const capabilities = byBotUserId.get(row.botUserId) ?? []
      capabilities.push(row)
      byBotUserId.set(row.botUserId, capabilities)
    }
    return byBotUserId
  },

  async replaceForBotUserId(
    botUserId: number,
    capabilities: ReadonlyArray<{ kind: string; version: number }>,
  ): Promise<DbBotCapability[]> {
    return db.transaction(async (tx) => {
      if (capabilities.length === 0) {
        await tx.delete(botCapabilities).where(eq(botCapabilities.botUserId, botUserId))
        return []
      }

      const now = new Date()
      await tx
        .insert(botCapabilities)
        .values(capabilities.map(({ kind, version }) => ({
          botUserId,
          kind,
          version,
          createdAt: now,
          updatedAt: now,
        })))
        .onConflictDoUpdate({
          target: [botCapabilities.botUserId, botCapabilities.kind],
          set: {
            version: sql.raw(`excluded.${botCapabilities.version.name}`),
            updatedAt: now,
          },
        })

      await tx.delete(botCapabilities).where(and(
        eq(botCapabilities.botUserId, botUserId),
        notInArray(botCapabilities.kind, capabilities.map(({ kind }) => kind)),
      ))

      return tx
        .select()
        .from(botCapabilities)
        .where(eq(botCapabilities.botUserId, botUserId))
        .orderBy(asc(botCapabilities.kind))
    })
  },
}
