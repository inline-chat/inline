import { BotCommandsModel } from "@in/server/db/models/botCommands"
import { UsersModel } from "@in/server/db/models/users"
import type { DbChat } from "@in/server/db/schema"
import { getBotUserIdsForChatScope } from "@in/server/functions/bot.peerDiscovery"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import {
  MessageEntity_Type,
  type MessageEntities,
  type MessageEntity,
} from "@inline-chat/protocol/core"

type ResolveBotCommandTargetsInput = {
  text: string
  entities: MessageEntities | undefined
  chat: DbChat
  currentUserId: number
}

type ParsedBotCommand = {
  command: string
  username?: string
}

const parseBotCommandEntity = (text: string, entity: MessageEntity): ParsedBotCommand | null => {
  const offset = Number(entity.offset)
  const length = Number(entity.length)
  if (
    !Number.isSafeInteger(offset) ||
    !Number.isSafeInteger(length) ||
    offset < 0 ||
    length <= 0 ||
    offset + length > text.length
  ) {
    return null
  }

  const match = /^\/([a-z0-9_]{1,32})(?:@([a-z0-9_]{2,64}))?$/i.exec(
    text.slice(offset, offset + length),
  )
  if (!match?.[1]) return null
  return {
    command: match[1].toLowerCase(),
    ...(match[2] ? { username: match[2].toLowerCase() } : {}),
  }
}

const structuredTarget = (entity: MessageEntity): number | null => {
  if (entity.entity.oneofKind !== "botCommand") return null
  const target = Number(entity.entity.botCommand.botUserId)
  if (!Number.isSafeInteger(target) || target <= 0) {
    throw RealtimeRpcError.BadRequest()
  }
  return target
}

/**
 * Validates new-client command targets and backfills a unique catalog target
 * for range-only entities emitted by older clients.
 */
export const resolveBotCommandTargets = async ({
  text,
  entities,
  chat,
  currentUserId,
}: ResolveBotCommandTargetsInput): Promise<MessageEntities | undefined> => {
  const commandEntities = (entities?.entities ?? []).filter(
    (entity): entity is MessageEntity => entity?.type === MessageEntity_Type.BOT_COMMAND,
  )
  if (commandEntities.length === 0) return entities

  const botUserIds = Array.from(new Set(await getBotUserIdsForChatScope(chat, currentUserId)))
  const commandsByBotUserId = await BotCommandsModel.getForBotUserIds(botUserIds)
  const botRows = await UsersModel.getUsersWithPhotos(botUserIds)
  const botUserIdByUsername = new Map(
    botRows
      .filter((row) => row.user.username)
      .map((row) => [row.user.username!.toLowerCase(), row.user.id] as const),
  )

  let changed = false
  const resolved = (entities?.entities ?? []).map((entity) => {
    if (!entity || entity.type !== MessageEntity_Type.BOT_COMMAND) return entity

    const parsed = parseBotCommandEntity(text, entity)
    if (!parsed) {
      if (entity.entity.oneofKind === "botCommand") throw RealtimeRpcError.BadRequest()
      return entity
    }

    const explicitEntityTarget = structuredTarget(entity)
    const textualTarget = parsed.username ? botUserIdByUsername.get(parsed.username) : undefined
    if (parsed.username && !textualTarget) throw RealtimeRpcError.BadRequest()
    if (explicitEntityTarget && textualTarget && explicitEntityTarget !== textualTarget) {
      throw RealtimeRpcError.BadRequest()
    }

    const advertisedTargets = botUserIds.filter((botUserId) =>
      (commandsByBotUserId.get(botUserId) ?? []).some((command) => command.command === parsed.command),
    )
    const selectedTarget = explicitEntityTarget ?? textualTarget
    if (selectedTarget && !advertisedTargets.includes(selectedTarget)) {
      throw RealtimeRpcError.BadRequest()
    }

    const target = selectedTarget ?? (advertisedTargets.length === 1 ? advertisedTargets[0] : undefined)
    if (!target || explicitEntityTarget === target) return entity

    changed = true
    return {
      ...entity,
      entity: {
        oneofKind: "botCommand" as const,
        botCommand: { botUserId: BigInt(target) },
      },
    }
  })

  return changed ? { entities: resolved } : entities
}
