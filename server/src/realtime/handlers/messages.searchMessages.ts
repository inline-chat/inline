import { SearchMessagesFilter, SearchMessagesInput, SearchMessagesResult } from "@in/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { Functions } from "@in/server/functions"

export const searchMessages = async (
  input: SearchMessagesInput,
  handlerContext: HandlerContext,
): Promise<SearchMessagesResult> => {
  if (!input.peerId) {
    throw RealtimeRpcError.PeerIdInvalid()
  }

  const queries = input.queries ?? []
  const hasQueries = queries.some((query) => query.trim().length > 0)
  const hasFilter =
    input.filter !== undefined && input.filter !== SearchMessagesFilter.FILTER_UNSPECIFIED
  if (!hasQueries && !hasFilter) {
    throw RealtimeRpcError.BadRequest()
  }

  const result = await Functions.messages.searchMessages(
    {
      peerId: input.peerId,
      queries,
      limit: input.limit,
      offsetId: input.offsetId,
      filter: input.filter,
    },
    {
      currentSessionId: handlerContext.sessionId,
      currentUserId: handlerContext.userId,
    },
  )

  return { messages: result.messages }
}
