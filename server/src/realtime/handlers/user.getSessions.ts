import { Method, type AccountSession, type GetSessionsInput, type GetSessionsResult } from "@inline-chat/protocol/core"
import { SessionsModel, type SessionWithDecryptedData } from "@in/server/db/models/sessions"
import type { HandlerContext } from "@in/server/realtime/types"
import { connectionPresenceForUser } from "@in/server/modules/internalMessaging/presenceView"

export const method = Method.GET_SESSIONS

export const getSessionsHandler = async (
  _input: GetSessionsInput,
  handlerContext: HandlerContext,
): Promise<GetSessionsResult> => {
  const sessions = await SessionsModel.getValidSessionsByUserId(handlerContext.userId)
  sessions.sort(compareSessions)
  const presence = await connectionPresenceForUser(handlerContext.userId)

  return {
    sessions: sessions.map((session) => encodeSession(session, handlerContext.sessionId, presence.activeSessionIds.has(session.id))),
  }
}

export function encodeSession(session: SessionWithDecryptedData, currentSessionId: number, active = false): AccountSession {
  return {
    id: BigInt(session.id),
    clientType: session.clientType ?? "unknown",
    clientVersion: session.clientVersion ?? undefined,
    osVersion: session.osVersion ?? undefined,
    deviceName: session.personalData.deviceName ?? undefined,
    city: session.personalData.city ?? undefined,
    country: session.personalData.country ?? undefined,
    timezone: session.personalData.timezone ?? undefined,
    createdAt: dateSeconds(session.date),
    lastActiveAt: dateSeconds(session.lastActive),
    active,
    current: session.id === currentSessionId,
  }
}

function compareSessions(a: SessionWithDecryptedData, b: SessionWithDecryptedData): number {
  return dateMs(b.lastActive) - dateMs(a.lastActive) || dateMs(b.date) - dateMs(a.date) || b.id - a.id
}

function dateSeconds(date: Date | null): bigint {
  return BigInt(Math.floor(dateMs(date) / 1_000))
}

function dateMs(date: Date | null): number {
  return date?.getTime() ?? 0
}
