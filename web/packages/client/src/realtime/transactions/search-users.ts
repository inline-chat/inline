import { Method, type RpcCall, type RpcResult, type SearchUsersResult } from "@inline-chat/protocol/core"
import { Query, type Transaction } from "./transaction"

export type SearchUsersContext = { query: string; limit?: number }

/** `SEARCH_USERS`: the Mac's global people search. Read only: nothing is stored. */
export class SearchUsersTransaction implements Transaction<SearchUsersContext> {
  readonly method = Method.SEARCH_USERS
  readonly kind = Query()
  result: SearchUsersResult | undefined

  constructor(readonly context: SearchUsersContext) {}

  input(context: SearchUsersContext): RpcCall["input"] {
    return {
      oneofKind: "searchUsers",
      searchUsers: { query: context.query, ...(context.limit != null ? { limit: context.limit } : {}) },
    }
  }

  apply(result: RpcResult["result"] | undefined) {
    if (!result || result.oneofKind !== "searchUsers") throw new Error("invalid")
    this.result = result.searchUsers
  }
}

export const searchUsers = (context: SearchUsersContext) => new SearchUsersTransaction(context)
