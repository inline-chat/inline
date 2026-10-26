import {
  AgentGrantRequirement,
  AgentOutputMode,
  AgentParticipationMode,
  type AgentParticipation,
  type GetAgentParticipationsInput,
  type GetAgentParticipationsResult,
  type Peer,
  type SetAgentParticipationInput,
  type SetAgentParticipationResult,
} from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { ChatModel } from "@in/server/db/models/chats"
import { UsersModel } from "@in/server/db/models/users"
import { agentParticipations, type DbAgentParticipation, type DbChat } from "@in/server/db/schema"
import { insertChatUpdate, pushChatUpdate } from "@in/server/modules/agents/chatUpdates"
import { resolveAgentAccess, satisfiesGrantRequirement } from "@in/server/modules/agents/grants"
import { validOutputMode } from "@in/server/modules/agents/runtime"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { encodeOutputPeerFromChat } from "@in/server/realtime/encoders/encodePeer"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { eq, sql } from "drizzle-orm"

export function encodeAgentParticipation(row: DbAgentParticipation, peerId: Peer): AgentParticipation {
  return {
    peerId,
    botUserId: BigInt(row.botUserId),
    mode: row.mode,
    joinedBy: row.joinedBy === null ? undefined : BigInt(row.joinedBy),
    revision: row.revision,
    date: encodeDateStrict(row.updatedAt),
    outputMode: row.outputMode ?? undefined,
  }
}

export async function getAgentParticipations(
  input: GetAgentParticipationsInput,
  currentUserId: number,
): Promise<GetAgentParticipationsResult> {
  if (!input.peerId) throw RealtimeRpcError.BadRequest()
  const chat = await ChatModel.getChatFromInputPeerUnchecked(input.peerId, { currentUserId })
  await AccessGuards.ensureChatAccess(chat, currentUserId)
  const rows = await db.select().from(agentParticipations).where(eq(agentParticipations.chatId, chat.id))
  const peerId = encodeOutputPeerFromChat(chat, { currentUserId })
  return { participations: rows.map((row) => encodeAgentParticipation(row, peerId)) }
}

/**
 * The bot itself (joining on a mention or invite), its owner, or a CONFIGURE
 * grantee (spec §7).
 */
export async function setAgentParticipation(
  input: SetAgentParticipationInput,
  currentUserId: number,
): Promise<SetAgentParticipationResult> {
  if (!input.peerId) throw RealtimeRpcError.BadRequest()
  // Unspecified keeps the current mode, so an output-mode change sends only that.
  if (input.mode < AgentParticipationMode.UNSPECIFIED || input.mode > AgentParticipationMode.MUTED) {
    throw RealtimeRpcError.BadRequest()
  }
  if (input.outputMode !== undefined && !validOutputMode(input.outputMode)) throw RealtimeRpcError.BadRequest()
  const botUserId = Number(input.botUserId)
  if (!Number.isSafeInteger(botUserId) || botUserId <= 0) throw RealtimeRpcError.UserIdInvalid()
  const bot = await UsersModel.getUserById(botUserId)
  if (!bot?.bot || UsersModel.isDeleted(bot)) throw RealtimeRpcError.UserIdInvalid()

  const chat = await ChatModel.getChatFromInputPeerUnchecked(input.peerId, { currentUserId })
  await AccessGuards.ensureChatAccess(chat, currentUserId)
  // The agent can only take part where it has access.
  if (!(await AccessGuards.hasChatAccess(chat, botUserId))) throw RealtimeRpcError.UserIdInvalid()

  const actingAsBot = currentUserId === botUserId
  if (!actingAsBot) {
    const access = await resolveAgentAccess(bot, currentUserId)
    if (!satisfiesGrantRequirement(access, AgentGrantRequirement.CONFIGURE)) throw RealtimeRpcError.AgentGrantRequired()
    if (input.joinedBy !== undefined) throw RealtimeRpcError.BadRequest()
  } else if (input.outputMode !== undefined) {
    // The output mode is a person's choice in Agent Settings, not the bot's.
    throw RealtimeRpcError.BadRequest()
  }
  const outputMode = input.outputMode === undefined
    ? undefined
    : input.outputMode === AgentOutputMode.UNSPECIFIED ? null : input.outputMode
  const joinedBy = await validJoinedBy(input.joinedBy, chat)

  const { row, durable, lockedChat } = await db.transaction(async (tx) => {
    const now = new Date()
    const [saved] = await tx
      .insert(agentParticipations)
      .values({
        chatId: chat.id,
        botUserId,
        // A new participation created only to set the output mode must not join
        // the agent to ambient conversation; mentions reach it either way.
        mode: input.mode !== AgentParticipationMode.UNSPECIFIED
          ? input.mode
          : input.outputMode !== undefined ? AgentParticipationMode.MENTIONS_ONLY : AgentParticipationMode.ACTIVE,
        joinedBy: joinedBy ?? (actingAsBot ? null : currentUserId),
        outputMode: outputMode ?? null,
      })
      .onConflictDoUpdate({
        target: [agentParticipations.chatId, agentParticipations.botUserId],
        set: {
          ...(input.mode === AgentParticipationMode.UNSPECIFIED ? {} : { mode: input.mode }),
          ...(outputMode === undefined ? {} : { outputMode }),
          ...(joinedBy === undefined ? {} : { joinedBy }),
          revision: sql`${agentParticipations.revision} + 1`,
          updatedAt: now,
        },
      })
      .returning()
    if (!saved) throw RealtimeRpcError.InternalError()
    const { chat: lockedChat, durable } = await insertChatUpdate(tx, chat.id, {
      oneofKind: "agentParticipation",
      agentParticipation: {
        botUserId: BigInt(saved.botUserId),
        mode: saved.mode,
        joinedBy: saved.joinedBy === null ? undefined : BigInt(saved.joinedBy),
        revision: saved.revision,
        date: encodeDateStrict(saved.updatedAt),
        outputMode: saved.outputMode ?? undefined,
      },
    })
    return { row: saved, durable, lockedChat }
  })

  await pushChatUpdate(lockedChat, durable, (peerId) => ({
    oneofKind: "agentParticipation",
    agentParticipation: { participation: encodeAgentParticipation(row, peerId) },
  }))
  return { participation: encodeAgentParticipation(row, encodeOutputPeerFromChat(chat, { currentUserId })) }
}

async function validJoinedBy(input: bigint | undefined, chat: DbChat): Promise<number | undefined> {
  if (input === undefined) return undefined
  const userId = Number(input)
  if (!Number.isSafeInteger(userId) || userId <= 0) throw RealtimeRpcError.UserIdInvalid()
  if (!(await AccessGuards.hasChatAccess(chat, userId))) throw RealtimeRpcError.UserIdInvalid()
  return userId
}
