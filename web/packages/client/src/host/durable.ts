/**
 * The host's own durable intents: replay-safe server operations whose
 * transactions the realtime outbox's registry (`transaction-registry.ts`,
 * owned elsewhere) does not know, so the realtime client could not restore
 * them after a restart.
 *
 * A host record is a `pending_transaction` row of type `host_intent`. It is
 * written with status `failed`, which the realtime client never restores or
 * runs (it restores only `pending` rows, and resends only failed
 * `send_message` rows), so the host alone owns it; its real state is in the
 * payload. Nothing new in the schema.
 *
 * - Accept: one commit holds the record, the transaction's `prepare` and
 *   its optimistic rows (invariant 2). `accepted` follows that commit.
 * - Send: the transaction runs through the realtime client without its
 *   optimistic step (already committed) and without `persistence`; its
 *   `apply` deletes the record in the same commit as the server's result, its
 *   `failed` rolls back and deletes it. Retries after a lost acknowledgement
 *   or a dropped connection come from the transaction's mutation config.
 * - Restart: `resumeHostRecords` rebuilds each record's transaction from the
 *   stored context, re-runs its optimistic step (idempotent) and sends it
 *   again. The server operations here are replay-safe.
 */
import type { RpcResult } from "@inline-chat/protocol/core"
import type { Db } from "../database"
import { DbObjectKind, type PendingTransaction } from "../database/models"
import { DbQueryPlanType } from "../database/types"
import type { RealtimeClient } from "../realtime/realtime"
import type { Transaction, TransactionError } from "../realtime/transactions"
import type { AuthStore } from "../auth"

export const HOST_RECORD_TYPE = "host_intent"

/**
 * A record that only names the UI's transaction ID of a `sendText` in the
 * realtime outbox (`MessageRow.tx`). Context `{ chatId, clientKey }`. It is
 * never sent; it goes once its send leaves the outbox.
 */
export const SEND_TX_RECORD = "sendTx"

export type HostRecordPayload = {
  /** What the record is for; the host's own registry decodes it. */
  kind: string
  /** The UI's transaction ID, so a re-posted intent finds its record. */
  tx?: string
  /** The transaction's context after `prepare` (previous values for rollback). */
  context: unknown
  /** Free-form state of a multi-step record (media sends). */
  state?: unknown
}

let sequence = 0

export const newHostRecordId = (kind: string, now: number) =>
  `host:${kind}:${now.toString(36)}:${(sequence = (sequence + 1) % 1_000_000).toString(36)}:${Math.floor(
    Math.random() * 1e9,
  ).toString(36)}`

export const hostRecords = (db: Db): PendingTransaction[] =>
  db
    .queryCollection<DbObjectKind.PendingTransaction, PendingTransaction, DbQueryPlanType.Objects>(
      DbQueryPlanType.Objects,
      DbObjectKind.PendingTransaction,
      (record) => record.type === HOST_RECORD_TYPE,
    )
    .sort((left, right) => left.createdAt - right.createdAt)

export const hostRecordPayload = (record: PendingTransaction | undefined): HostRecordPayload | undefined => {
  const payload = record?.context as HostRecordPayload | undefined
  return payload && typeof payload === "object" && typeof payload.kind === "string" ? payload : undefined
}

export const writeHostRecord = (db: Db, id: string, payload: HostRecordPayload, createdAt: number) => {
  db.replace({
    kind: DbObjectKind.PendingTransaction,
    id,
    type: HOST_RECORD_TYPE,
    // Parked for the realtime client: it restores only `pending` rows.
    status: "failed",
    context: payload,
    createdAt,
  })
}

export const deleteHostRecord = (db: Db, id: string) => {
  const ref = db.ref(DbObjectKind.PendingTransaction, id)
  if (db.get(ref)) db.delete(ref)
}

/**
 * The transaction as the realtime client runs it for a host record: no
 * optimistic step (committed with the record), no outbox row, and the
 * record removed with the result or the failure.
 */
export const hostSend = (
  inner: Transaction,
  recordId: string,
  hooks: { afterApply?: (result: RpcResult["result"] | undefined, db: Db) => void } = {},
): Transaction => ({
  method: inner.method,
  kind: inner.kind,
  context: inner.context,
  input: (context) => inner.input(context),
  apply: (result, db) => {
    inner.apply(result, db)
    hooks.afterApply?.(result, db)
    deleteHostRecord(db, recordId)
  },
  failed: (error: TransactionError, db: Db, auth: AuthStore) => {
    inner.failed?.(error, db, auth)
    // An ambiguous or stopped outcome keeps the record: a restart resends.
    if (error.kind === "rpc-error" || error.kind === "invalid" || error.kind === "dependency-failed") {
      deleteHostRecord(db, recordId)
    }
  },
  describe: () => `host:${inner.method}`,
})

/**
 * Commit a record with the transaction's prepared state and optimistic rows,
 * then return the transaction to send.
 */
export const commitHostRecord = async (
  db: Db,
  auth: AuthStore,
  transaction: Transaction,
  payload: Omit<HostRecordPayload, "context">,
  now: number,
): Promise<string> => {
  const id = newHostRecordId(payload.kind, now)
  await db.commit(() => {
    transaction.prepare?.(db, auth)
    writeHostRecord(db, id, { ...payload, context: transaction.context }, now)
    transaction.optimistic?.(db, auth)
  })
  return id
}

export type HostRecordDecoder = (payload: HostRecordPayload) => Transaction | undefined

/**
 * After a restart: re-apply each record's optimistic step and send it again.
 * A record its decoder does not know (a newer build's) is left alone.
 */
export const resumeHostRecords = async (
  options: {
    db: Db
    auth: AuthStore
    realtime: RealtimeClient
    decode: HostRecordDecoder
    /** Records another owner runs (media sends). */
    skip?: (payload: HostRecordPayload) => boolean
    onError: (error: unknown) => void
  },
) => {
  const { db, auth, realtime } = options
  for (const record of hostRecords(db)) {
    const payload = hostRecordPayload(record)
    if (!payload || options.skip?.(payload)) continue
    const transaction = options.decode(payload)
    if (!transaction) continue
    try {
      await db.commit(() => transaction.optimistic?.(db, auth))
    } catch (error) {
      options.onError(error)
      continue
    }
    realtime.execute(hostSend(transaction, record.id)).catch(options.onError)
  }
}
