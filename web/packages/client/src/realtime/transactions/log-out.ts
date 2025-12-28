import { Method, type RpcCall, type RpcResult } from "@in/protocol/core"
import type { Db } from "../../database"
import { Mutation, type LocalTransaction, type LocalTransactionContext } from "./transaction"

export type LogOutContext = {
  performServerLogout?: () => Promise<void> | void
}

export class LogOutTransaction implements LocalTransaction<LogOutContext> {
  readonly localOnly = true
  readonly method = Method.UNSPECIFIED
  readonly kind = Mutation()
  readonly context: LogOutContext

  constructor(context: LogOutContext = {}) {
    this.context = context
  }

  input(): RpcCall["input"] {
    return { oneofKind: undefined }
  }

  async apply(_result: RpcResult["result"] | undefined, _db: Db) {
    // local-only transaction; no RPC result to apply
  }

  async runLocal(context: LocalTransactionContext) {
    await this.context.performServerLogout?.()
    await context.stopRealtime()
    context.auth.logout()
  }
}

export const logOut = (context?: LogOutContext) => new LogOutTransaction(context)
