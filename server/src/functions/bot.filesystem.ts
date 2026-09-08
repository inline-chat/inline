import { db } from "@in/server/db"
import { users, userNotDeleted } from "@in/server/db/schema"
import { and, eq } from "drizzle-orm"
import type { AnswerBotFilesystemInput, AnswerBotFilesystemResult, RequestBotFilesystemInput, RequestBotFilesystemResult } from "@inline-chat/protocol/core"
import type { FunctionContext } from "./_types"
import { getCurrentBotOrThrow } from "./bot.capabilitiesShared"
import { resolveCapableBotForPeer } from "./bot.chatSettingsShared"
import { botFilesystemBroker } from "@in/server/modules/botFilesystem/broker"
import { validateFilesystemRequest, validateFilesystemResponse } from "@in/server/modules/botFilesystem/validation"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { sendMessageToRealtimeBot } from "@in/server/realtime/message"

async function requireOwner(botId: number, actorId: number): Promise<void> {
  const [bot] = await db.select({ id: users.id }).from(users).where(and(
    eq(users.id, botId), eq(users.bot, true), eq(users.botCreatorId, actorId), userNotDeleted(),
  )).limit(1)
  if (!bot) throw RealtimeRpcError.BadRequest()
}

export async function requestBotFilesystem(input: RequestBotFilesystemInput, context: FunctionContext): Promise<RequestBotFilesystemResult> {
  validateFilesystemRequest(input)
  const botId = Number(input.botUserId)
  if (!Number.isSafeInteger(botId) || botId <= 0) throw RealtimeRpcError.BadRequest()
  await requireOwner(botId, context.currentUserId)
  const target = await resolveCapableBotForPeer({ peerId: input.peerId, botUserId: input.botUserId, version: 1, actorUserId: context.currentUserId })
  const pending = botFilesystemBroker.create(botId)
  if (!pending) return { response: { result: { oneofKind: "problem", problem: "The remote browser is busy. Try again." } } }
  try {
    const recipients = await sendMessageToRealtimeBot(botId, { oneofKind: "bot", bot: { event: {
      oneofKind: "filesystemRequested", filesystemRequested: {
        requestId: pending.id, actorUserId: BigInt(context.currentUserId), chatId: BigInt(target.chatId), input,
      },
    } } })
    if (recipients === 0) botFilesystemBroker.answer(pending.id, botId, { result: { oneofKind: "problem", problem: "The remote machine is offline." } })
  } catch {
    botFilesystemBroker.answer(pending.id, botId, { result: { oneofKind: "problem", problem: "Couldn’t reach the remote machine." } })
  }
  const response = await pending.response
  await requireOwner(botId, context.currentUserId)
  return { response }
}

export async function answerBotFilesystem(input: AnswerBotFilesystemInput, context: FunctionContext): Promise<AnswerBotFilesystemResult> {
  const bot = await getCurrentBotOrThrow(context.currentUserId)
  const response = validateFilesystemResponse(input.response)
  if (!botFilesystemBroker.answer(input.requestId, bot.id, response)) throw RealtimeRpcError.BadRequest()
  return {}
}
