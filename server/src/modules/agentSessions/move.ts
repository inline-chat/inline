import type { MoveAgentSessionInput, MoveAgentSessionResult } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { ChatModel } from "@in/server/db/models/chats"
import { agentSessions, chats } from "@in/server/db/schema"
import { chatAgentContext } from "@in/server/modules/agentConfiguration"
import { insertChatUpdate, pushChatUpdate } from "@in/server/modules/agents/chatUpdates"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { and, eq } from "drizzle-orm"
import { agentSessionChatUpdate, encodeAgentSessionForViewer } from "./state"

/**
 * Moves a work's canonical publication chat into a subthread of its current
 * chat (spec §5.2). The session row keeps its ID, native identity and delivery
 * ledger, so later syncs publish in the destination; the parent keeps its
 * status card. Retrying with the same destination is a no-op.
 */
export async function moveAgentSession(
  input: MoveAgentSessionInput,
  currentUserId: number,
): Promise<MoveAgentSessionResult> {
  if (!input.destinationPeerId || input.agentSessionId <= 0n) throw RealtimeRpcError.BadRequest()
  const [session] = await db.select().from(agentSessions).where(eq(agentSessions.id, input.agentSessionId)).limit(1)
  if (!session || (session.botUserId !== currentUserId && session.ownerUserId !== currentUserId)) {
    throw RealtimeRpcError.BadRequest()
  }
  const destination = await ChatModel.getChatFromInputPeerUnchecked(input.destinationPeerId, { currentUserId })

  if (session.chatId === destination.id) {
    return { agentSession: await encodeAgentSessionForViewer(session, destination, currentUserId), moved: false }
  }
  // Only into a subthread of the work's current chat.
  if (destination.parentChatId !== session.chatId) throw RealtimeRpcError.BadRequest()
  const [ownerAccess, botAccess] = await Promise.all([
    AccessGuards.hasChatAccess(destination, session.ownerUserId),
    AccessGuards.hasChatAccess(destination, session.botUserId),
  ])
  if (!ownerAccess || !botAccess) throw RealtimeRpcError.PeerIdInvalid()
  const bound = chatAgentContext(destination)
  if (bound && Number(bound.botUserId) !== session.botUserId) throw RealtimeRpcError.BadRequest()

  const result = await db.transaction(async (tx) => {
    // Lock both chats in ID order, then the session, so concurrent moves and
    // state reports cannot interleave.
    const chatIds = [session.chatId, destination.id].sort((a, b) => a - b)
    for (const chatId of chatIds) await tx.select({ id: chats.id }).from(chats).where(eq(chats.id, chatId)).for("update")
    const [current] = await tx.select().from(agentSessions).where(eq(agentSessions.id, session.id)).for("update").limit(1)
    if (!current) throw RealtimeRpcError.BadRequest()
    if (current.chatId === destination.id) return { row: current, moved: false as const }
    if (current.chatId !== session.chatId) throw RealtimeRpcError.BadRequest()
    // One work per (chat, bot).
    const [occupied] = await tx.select({ id: agentSessions.id }).from(agentSessions)
      .where(and(eq(agentSessions.chatId, destination.id), eq(agentSessions.botUserId, current.botUserId))).limit(1)
    if (occupied) throw RealtimeRpcError.BadRequest()

    const [row] = await tx.update(agentSessions)
      .set({ chatId: destination.id, updatedAt: new Date() })
      .where(eq(agentSessions.id, current.id))
      .returning()
    if (!row) throw RealtimeRpcError.InternalError()
    // Both chats learn where the work is now published.
    const payload = await agentSessionChatUpdate(row)
    const source = await insertChatUpdate(tx, session.chatId, payload)
    const target = await insertChatUpdate(tx, destination.id, payload)
    return { row, moved: true as const, source, target }
  })

  // The destination is a thread, so its peer is the same for every viewer.
  const agentSession = await encodeAgentSessionForViewer(result.row, destination, currentUserId)
  if (result.moved) {
    for (const { chat, durable } of [result.source, result.target]) {
      await pushChatUpdate(chat, durable, () => ({ oneofKind: "agentSessionState", agentSessionState: { agentSession } }))
    }
  }
  return { agentSession, moved: result.moved }
}
