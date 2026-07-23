import type { Method, RpcCall, RpcResult } from "@inline-chat/protocol/core"
import type { ChatID } from "@inline/ids"
import type { Db } from "../../database"
import type { AuthStore } from "../../auth"
import type { TransactionError } from "./transaction-errors"

export type QueryConfig = {}

export type MutationConfig = {
  transient?: boolean
  /**
   * Retry after the RPC was handed to the transport but no server ACK arrived.
   * This is only safe for queries or mutations with a server-enforced
   * idempotency identity.
   */
  retryAfterTransportLoss?: boolean
  /**
   * Retry after the server ACKed the RPC but its result was lost.
   * This is a stronger ambiguity boundary than retryAfterTransportLoss.
   */
  retryAfterAck?: boolean
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

export type TransactionBlocker = {
  type: "chatCreated"
  chatId: ChatID
}

export type TransactionBlockerState =
  | "blocked"
  | "satisfied"
  | "failed"

export const chatCreatedBlocker = (
  chatId: ChatID,
): TransactionBlocker => ({ type: "chatCreated", chatId })

export interface Transaction<Context = unknown> {
  readonly method: Method
  readonly kind: TransactionKind
  readonly context: Context
  readonly persistence?: {
    type: string
    /**
     * Persisted transactions may be restored after any crash point, including
     * after the server committed the mutation. Only replay-safe mutations can
     * opt into the durable outbox.
     */
    replayPolicy: "idempotent"
  }
  /** Dependencies that must be satisfied before this transaction is sent. */
  readonly blockers?: readonly TransactionBlocker[]
  /** Dependencies made durable by a successful apply. */
  readonly satisfiedBlockersOnSuccess?: readonly TransactionBlocker[]

  input(context: Context): RpcCall["input"]
  /**
   * Synchronous preflight run inside the same database recipe, before the
   * durable outbox snapshots `context`. Use it only to capture rollback or
   * dependency state needed by optimistic/failure handling.
   */
  prepare?: (db: Db, auth: AuthStore) => void
  /**
   * Synchronous cache recipe. RealtimeClient commits this together with
   * durable outbox completion in one database transaction.
   */
  apply(result: RpcResult["result"] | undefined, db: Db): void

  /**
   * Synchronous cache recipe committed atomically with durable transaction
   * metadata. Network or other async work does not belong in this hook.
   */
  optimistic?: (db: Db, auth: AuthStore) => void
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
