import type { SearchMessagesGlobalInput } from "@inline-chat/protocol/core"
import { searchMessagesGlobal } from "@in/server/functions/messages.searchMessagesGlobal"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { HandlerContext } from "@in/server/realtime/types"
import { searchFailureClass } from "@in/server/modules/search/cloudFailure"
import { Log } from "@in/server/utils/log"

const log = new Log("search.global")

export async function searchMessagesGlobalHandler(input: SearchMessagesGlobalInput, context: HandlerContext) {
  try {
    return await searchMessagesGlobal(input, context)
  } catch (cause) {
    if (cause instanceof RealtimeRpcError) throw cause
    // Driver errors can contain SQL, opaque tags and bound values.
    log.error("Global message search failed", { failure: searchFailureClass(cause) })
    throw RealtimeRpcError.InternalError()
  }
}
