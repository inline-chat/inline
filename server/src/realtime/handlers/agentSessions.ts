import type {
  ConnectAgentSessionInput,
  ConnectAgentSessionResult,
  GetAgentSessionInput,
  GetAgentSessionResult,
  SyncAgentSessionMessagesInput,
  SyncAgentSessionMessagesResult,
} from "@inline-chat/protocol/core"
import {
  connectAgentSession,
  getAgentSession,
  syncAgentSessionMessages,
} from "@in/server/modules/agentSessions/service"
import type { HandlerContext } from "@in/server/realtime/types"

export function connectAgentSessionHandler(
  input: ConnectAgentSessionInput,
  context: HandlerContext,
): Promise<ConnectAgentSessionResult> {
  return connectAgentSession(input, context.userId)
}

export function getAgentSessionHandler(
  input: GetAgentSessionInput,
  context: HandlerContext,
): Promise<GetAgentSessionResult> {
  return getAgentSession(input, context.userId)
}

export function syncAgentSessionMessagesHandler(
  input: SyncAgentSessionMessagesInput,
  context: HandlerContext,
): Promise<SyncAgentSessionMessagesResult> {
  // Realtime V3 authorization currently carries the authenticated user ID but
  // not a duplicated is_bot flag. The service proves that this exact user is
  // the bound bot on every call.
  return syncAgentSessionMessages(input, context.userId)
}
