import { getCommonChats } from "@in/server/functions/messages.getCommonChats"
import { InMemoryRateLimiter } from "@in/server/modules/oauth/rateLimiter"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { HandlerContext } from "@in/server/realtime/types"
import type { GetCommonChatsInput, GetCommonChatsResult } from "@inline-chat/protocol/core"

const commonChatsLimiter = new InMemoryRateLimiter({ capacity: 10_000 })

export async function getCommonChatsHandler(
  input: GetCommonChatsInput,
  context: HandlerContext,
): Promise<GetCommonChatsResult> {
  const rate = commonChatsLimiter.consume({
    key: `get-common-chats:${context.userId}`,
    nowMs: Date.now(),
    rule: { max: 120, windowMs: 60_000 },
  })
  if (!rate.allowed) throw RealtimeRpcError.RateLimit()

  return getCommonChats(input, {
    currentUserId: context.userId,
    currentSessionId: context.sessionId,
    currentConnectionId: context.connectionId,
    isBot: context.isBot,
    signal: context.signal,
  })
}
