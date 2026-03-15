import { db } from "@in/server/db"
import { botCommands, type DbBotCommand } from "@in/server/db/schema"
import { and, asc, eq, inArray } from "drizzle-orm"

export const BotCommandsModel = {
  async getForBotUserId(botUserId: number): Promise<DbBotCommand[]> {
    return db
      .select()
      .from(botCommands)
      .where(eq(botCommands.botUserId, botUserId))
      .orderBy(asc(botCommands.sortOrder), asc(botCommands.command))
  },

  async getForBotUserIds(botUserIds: number[]): Promise<Map<number, DbBotCommand[]>> {
    const uniqueBotUserIds = Array.from(new Set(botUserIds.filter((id) => Number.isFinite(id) && id > 0)))
    if (uniqueBotUserIds.length === 0) {
      return new Map()
    }

    const rows = await db
      .select()
      .from(botCommands)
      .where(inArray(botCommands.botUserId, uniqueBotUserIds))
      .orderBy(asc(botCommands.botUserId), asc(botCommands.sortOrder), asc(botCommands.command))

    const commandsByBotUserId = new Map<number, DbBotCommand[]>()
    for (const row of rows) {
      const existing = commandsByBotUserId.get(row.botUserId)
      if (existing) {
        existing.push(row)
      } else {
        commandsByBotUserId.set(row.botUserId, [row])
      }
    }

    return commandsByBotUserId
  },

  async replaceForBotUserId(
    botUserId: number,
    commands: Array<{ command: string; description: string; sortOrder: number }>,
  ): Promise<DbBotCommand[]> {
    return db.transaction(async (tx) => {
      await tx.delete(botCommands).where(eq(botCommands.botUserId, botUserId))

      if (commands.length === 0) {
        return []
      }

      const now = new Date()
      const inserted = await tx
        .insert(botCommands)
        .values(
          commands.map((command) => ({
            botUserId,
            command: command.command,
            description: command.description,
            sortOrder: command.sortOrder,
            createdAt: now,
            updatedAt: now,
          })),
        )
        .returning()

      return inserted.sort((left, right) => {
        if (left.sortOrder !== right.sortOrder) {
          return left.sortOrder - right.sortOrder
        }
        return left.command.localeCompare(right.command)
      })
    })
  },

  async deleteForBotUserId(botUserId: number): Promise<void> {
    await db.delete(botCommands).where(eq(botCommands.botUserId, botUserId))
  },

  async getByBotUserIdAndCommand(botUserId: number, command: string): Promise<DbBotCommand | undefined> {
    const [row] = await db
      .select()
      .from(botCommands)
      .where(and(eq(botCommands.botUserId, botUserId), eq(botCommands.command, command)))
      .limit(1)

    return row
  },
}
