import { db } from "@in/server/db"
import { BotCapabilitiesModel } from "@in/server/db/models/botCapabilities"
import { UsersModel } from "@in/server/db/models/users"
import { messages } from "@in/server/db/schema"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import type { FunctionContext } from "./_types"
import type { GetPeerBotsInput, GetPeerBotsResult } from "@inline-chat/protocol/core"
import { and, desc, eq, inArray } from "drizzle-orm"
import { hasChatSettingsCapability, toProtocolBotCapability } from "./bot.capabilitiesShared"
import { resolvePeerBotScope } from "./bot.peerDiscovery"

export async function getPeerBots(input: GetPeerBotsInput, context: FunctionContext): Promise<GetPeerBotsResult> {
  const { chat, botUserIds } = await resolvePeerBotScope(input.peerId, context.currentUserId)
  if (botUserIds.length === 0) return { bots: [] }

  const [botRows, capabilitiesByBotUserId] = await Promise.all([
    UsersModel.getUsersWithPhotos(botUserIds),
    BotCapabilitiesModel.getForBotUserIds(botUserIds),
  ])
  botRows.sort((left, right) => left.user.id - right.user.id)

  const capableIds = botUserIds.filter((botUserId) =>
    hasChatSettingsCapability(capabilitiesByBotUserId.get(botUserId) ?? []),
  )
  let suggestedBotUserId: bigint | undefined
  if (capableIds.length > 0) {
    const [latest] = await db
      .select({ userId: messages.fromId })
      .from(messages)
      .where(and(eq(messages.chatId, chat.id), inArray(messages.fromId, capableIds)))
      .orderBy(desc(messages.messageId))
      .limit(1)
    suggestedBotUserId = BigInt(latest?.userId ?? capableIds[0]!)
  }

  return {
    bots: botRows.map((row) => ({
      bot: Encoders.user({ user: row.user, photoFile: row.photoFile, min: true }),
      capabilities: (capabilitiesByBotUserId.get(row.user.id) ?? []).flatMap((capability) => {
        const encoded = toProtocolBotCapability(capability)
        return encoded ? [encoded] : []
      }),
    })),
    suggestedBotUserId,
  }
}
