import {
  AgentGrantRequirement,
  AgentSessionControl,
  type ControlAgentSessionInput,
  type ControlAgentSessionResult,
} from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { UsersModel } from "@in/server/db/models/users"
import { agentSessions, chats } from "@in/server/db/schema"
import { resolveAgentAccess, satisfiesGrantRequirement } from "@in/server/modules/agents/grants"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { eq } from "drizzle-orm"

/**
 * Work bar stop, pause and resume. Relayed to the session's bot like a message
 * action; the bridge maps it to the harness's own operations.
 */
export async function controlAgentSession(
  input: ControlAgentSessionInput,
  currentUserId: number,
): Promise<ControlAgentSessionResult> {
  if (input.op < AgentSessionControl.STOP || input.op > AgentSessionControl.RESUME) throw RealtimeRpcError.BadRequest()
  if (input.agentSessionId <= 0n) throw RealtimeRpcError.BadRequest()
  const [session] = await db.select().from(agentSessions).where(eq(agentSessions.id, input.agentSessionId)).limit(1)
  if (!session) throw RealtimeRpcError.BadRequest()
  const [chat] = await db.select().from(chats).where(eq(chats.id, session.chatId)).limit(1)
  if (!chat) throw RealtimeRpcError.PeerIdInvalid()
  // Same answer for missing and inaccessible sessions.
  if (!(await AccessGuards.hasChatAccess(chat, currentUserId))) throw RealtimeRpcError.BadRequest()

  const bot = await UsersModel.getUserById(session.botUserId)
  if (!bot?.bot || UsersModel.isDeleted(bot)) throw RealtimeRpcError.BadRequest()
  const access = await resolveAgentAccess(bot, currentUserId)
  if (!satisfiesGrantRequirement(access, AgentGrantRequirement.STEER)) throw RealtimeRpcError.AgentGrantRequired()

  const control = {
    agentSessionId: session.id,
    op: input.op,
    actorUserId: BigInt(currentUserId),
    chatId: BigInt(chat.id),
  }
  const durable = await UserBucketUpdates.enqueue({
    userId: bot.id,
    update: { oneofKind: "userAgentSessionControl", userAgentSessionControl: { interactionId: 0n, ...control } },
  })
  const interactionId = BigInt(durable.seq)
  RealtimeUpdates.pushToUser(bot.id, [{
    seq: durable.seq,
    date: encodeDateStrict(durable.date),
    update: { oneofKind: "agentSessionControl", agentSessionControl: { interactionId, ...control } },
  }])
  return { interactionId }
}
