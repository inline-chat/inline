import type { Method, RpcCall, RpcResult } from "@inline-chat/protocol/core"
import type { Db } from "../../database"
import type { AuthStore } from "../../auth"
import type { TransactionError } from "./transaction-errors"

export type QueryConfig = {}

export type MutationConfig = {
  transient?: boolean
}

export type TransactionKind =
  | { kind: "query"; config: QueryConfig }
  | { kind: "mutation"; config: MutationConfig }

export const Query = (config: QueryConfig = {}): TransactionKind => ({
  kind: "query",
  config,
})

export const Mutation = (config: MutationConfig = {}): TransactionKind => ({
  kind: "mutation",
  config,
})

export interface Transaction<Context = unknown> {
  readonly method: Method
  readonly kind: TransactionKind
  readonly context: Context

  input(context: Context): RpcCall["input"]
  apply(result: RpcResult["result"] | undefined, db: Db): Promise<void>

  optimistic?: (db: Db, auth: AuthStore) => Promise<void> | void
  failed?: (error: TransactionError, db: Db, auth: AuthStore) => Promise<void> | void
  cancelled?: (db: Db, auth: AuthStore) => Promise<void> | void
  describe?: () => string
}

export type LocalTransactionContext = {
  auth: AuthStore
  db: Db
  stopRealtime: () => Promise<void>
}

export interface LocalTransaction<Context = unknown> extends Transaction<Context> {
  readonly localOnly: true
  runLocal(context: LocalTransactionContext): Promise<void>
}
