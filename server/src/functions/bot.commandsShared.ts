import { db } from "@in/server/db"
import { users, type DbUser } from "@in/server/db/schema/users"
import { and, eq, isNull, or } from "drizzle-orm"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { BotCommand } from "@inline-chat/protocol/core"

const BOT_COMMAND_RE = /^[a-z0-9_]+$/
const BOT_COMMAND_LIMIT = 100

export async function getOwnedBotOrThrow(botUserId: number, currentUserId: number): Promise<DbUser> {
  if (!Number.isFinite(botUserId) || botUserId <= 0) {
    throw RealtimeRpcError.BadRequest()
  }

  const [bot] = await db
    .select()
    .from(users)
    .where(and(eq(users.id, botUserId), eq(users.bot, true), or(isNull(users.deleted), eq(users.deleted, false))))
    .limit(1)

  if (!bot || bot.botCreatorId !== currentUserId) {
    throw RealtimeRpcError.UserIdInvalid()
  }

  return bot
}

export function normalizeProtocolBotCommands(
  commands: BotCommand[] | undefined,
): Array<{ command: string; description: string; sortOrder: number }> {
  if (!commands) {
    return []
  }

  if (commands.length > BOT_COMMAND_LIMIT) {
    throw RealtimeRpcError.BadRequest()
  }

  const seenCommands = new Set<string>()

  return commands.map((command, index) => {
    const normalizedCommand = command.command.trim()
    const normalizedDescription = command.description.trim()

    if (
      normalizedCommand.length < 1 ||
      normalizedCommand.length > 32 ||
      !BOT_COMMAND_RE.test(normalizedCommand) ||
      normalizedDescription.length < 1 ||
      normalizedDescription.length > 256 ||
      seenCommands.has(normalizedCommand)
    ) {
      throw RealtimeRpcError.BadRequest()
    }

    seenCommands.add(normalizedCommand)

    return {
      command: normalizedCommand,
      description: normalizedDescription,
      sortOrder: command.sortOrder ?? index,
    }
  })
}

export function toProtocolBotCommand(input: {
  command: string
  description: string
  sortOrder?: number | null
}): BotCommand {
  return {
    command: input.command,
    description: input.description,
    sortOrder: input.sortOrder ?? undefined,
  }
}
