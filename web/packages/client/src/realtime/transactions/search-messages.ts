import {
  Method,
  SearchMessagesFilter,
  type InputPeer,
  type RpcCall,
  type RpcResult,
  type SearchMessagesResult,
} from "@inline-chat/protocol/core"
import type { ChatID } from "@inline/ids"
import type { Db } from "../../database"
import { upsertMessage } from "./mappers"
import { Query, type Transaction } from "./transaction"

export type SearchMessagesContext = {
  chatId: ChatID
  peerId: InputPeer
  /** Words to match (the server ANDs the words of one query). */
  queries?: string[]
  filter?: SearchMessagesFilter
  offsetId?: bigint
  limit?: number
  countOnly?: boolean
  /**
   * Commit the returned messages to the replica (`chatMedia` pages). Without
   * it the result is only returned (server text search).
   */
  store?: boolean
}

/**
 * `SEARCH_MESSAGES` in one chat. A query: sent once, nothing to undo. With
 * `store`, the page's messages commit like `GET_MESSAGES` results do (rows
 * only: a page certifies no history range, so it never closes a hole).
 */
export class SearchMessagesTransaction implements Transaction<SearchMessagesContext> {
  readonly method = Method.SEARCH_MESSAGES
  readonly kind = Query()
  /** The server's answer, once applied. */
  result: SearchMessagesResult | undefined

  constructor(readonly context: SearchMessagesContext) {}

  input(context: SearchMessagesContext): RpcCall["input"] {
    return {
      oneofKind: "searchMessages",
      searchMessages: {
        peerId: context.peerId,
        queries: context.queries ?? [],
        ...(context.limit != null ? { limit: context.limit } : {}),
        ...(context.offsetId != null ? { offsetId: context.offsetId } : {}),
        ...(context.filter != null ? { filter: context.filter } : {}),
        ...(context.countOnly ? { countOnly: true } : {}),
      },
    }
  }

  apply(result: RpcResult["result"] | undefined, db: Db) {
    if (!result || result.oneofKind !== "searchMessages") throw new Error("invalid")
    this.result = result.searchMessages
    if (!this.context.store) return
    const chatId = BigInt(this.context.chatId)
    db.batch(() => {
      for (const message of result.searchMessages.messages) {
        // A page answers for its own chat only.
        if (message.chatId === chatId) upsertMessage(db, message)
      }
    })
  }
}

export const searchMessages = (context: SearchMessagesContext) => new SearchMessagesTransaction(context)
