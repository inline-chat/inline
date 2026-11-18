/**
 * Participant intents: `addChatParticipants` and `removeChatParticipant`.
 *
 * Both are durable through host records (`durable.ts`): their transactions
 * are new and the realtime outbox's registry (owned elsewhere) does not know
 * them. One record per person or group, all committed in one transaction with
 * their optimistic rows (invariant 2), then `accepted`; each is sent when
 * connected, retried after a lost acknowledgement or a dropped connection,
 * and sent again by the next core after a restart. The server adds
 * idempotently; a removal retried after its acknowledgement was lost is
 * refused ("not a participant"), which settles `rejected` although the
 * person is gone (documented in the contract).
 *
 * A refusal marks the chat's roster incomplete and fetches it again, so the
 * list converges on the server's instead of guessing a rollback.
 */
import type { Intent, IntentResult, TxId } from "@inline/core-protocol"
import type { ChatID, UserID } from "@inline/ids"
import type { AuthStore } from "../auth"
import type { Db } from "../database"
import {
  chatParticipantGroupKey,
  chatParticipantKey,
  DbObjectKind,
  type UserGroupID,
} from "../database/models"
import { isPositiveId } from "../queries/validate"
import type { RealtimeClient } from "../realtime/realtime"
import { TransactionFailure, type Transaction } from "../realtime/transactions"
import {
  AddChatParticipantTransaction,
  type AddChatParticipantContext,
} from "../realtime/transactions/add-chat-participant"
import {
  RemoveChatParticipantTransaction,
  type RemoveChatParticipantContext,
} from "../realtime/transactions/remove-chat-participant"
import {
  hostRecordPayload,
  hostRecords,
  hostSend,
  newHostRecordId,
  writeHostRecord,
  type HostRecordPayload,
} from "./durable"
import { hasErrorNamed } from "./errors"

export type ParticipantIntent = Extract<Intent, { kind: "addChatParticipants" | "removeChatParticipant" }>

export const PARTICIPANT_INTENTS = new Set<Intent["kind"]>(["addChatParticipants", "removeChatParticipant"])

/** At most this many people and groups in one `addChatParticipants`. */
export const MAX_PARTICIPANTS_PER_INTENT = 50

export type ParticipantAccount = {
  readonly db: Db
  readonly auth: AuthStore
  readonly realtime: RealtimeClient
  /** The server refused a change to this chat's roster: fetch it again. */
  refreshRoster?(chatId: ChatID): void
  /** Evaluate `check` now and after every committed batch until it returns true. */
  watch?(check: () => boolean): () => void
}

type Report = (result: IntentResult) => void

const ADD = "addParticipant"
const REMOVE = "removeParticipant"

/** Rebuild a participant record's transaction after a restart. */
export const decodeParticipantRecord = (payload: HostRecordPayload): Transaction | undefined => {
  switch (payload.kind) {
    case ADD:
      return new AddChatParticipantTransaction(payload.context as AddChatParticipantContext)
    case REMOVE:
      return new RemoveChatParticipantTransaction(payload.context as RemoveChatParticipantContext)
    default:
      return undefined
  }
}

const failureKind = (error: unknown) => (error instanceof TransactionFailure ? error.kind : "ambiguous-result")

export const runParticipantIntent = async (
  account: ParticipantAccount,
  tx: TxId,
  intent: ParticipantIntent,
  report: Report,
  now: number,
): Promise<void> => {
  const invalid = () => report({ tx, status: "rejected", reason: "invalid" })
  const chatId = intent.chatId
  const date = Math.floor(now / 1000)
  const records: Array<{ kind: string; transaction: Transaction }> = []
  if (intent.kind === "addChatParticipants") {
    const userIds: unknown = intent.userIds ?? []
    const groupIds: unknown = intent.groupIds ?? []
    if (
      !Array.isArray(userIds) ||
      !Array.isArray(groupIds) ||
      !userIds.every(isPositiveId) ||
      !groupIds.every(isPositiveId) ||
      userIds.length + groupIds.length === 0 ||
      userIds.length + groupIds.length > MAX_PARTICIPANTS_PER_INTENT
    ) {
      return invalid()
    }
    for (const userId of new Set(userIds as UserID[])) {
      records.push({ kind: ADD, transaction: new AddChatParticipantTransaction({ chatId, date, userId }) })
    }
    for (const groupId of new Set(groupIds as UserGroupID[])) {
      records.push({ kind: ADD, transaction: new AddChatParticipantTransaction({ chatId, date, groupId }) })
    }
  } else {
    const { userId, groupId } = intent
    if ((userId == null) === (groupId == null)) return invalid()
    if (userId != null && !isPositiveId(userId)) return invalid()
    if (groupId != null && !isPositiveId(groupId)) return invalid()
    records.push({
      kind: REMOVE,
      transaction: new RemoveChatParticipantTransaction(
        userId != null ? { chatId, userId } : { chatId, groupId: groupId as UserGroupID },
      ),
    })
  }

  const { db, auth, realtime } = account
  // The same transaction committed by an earlier core (a re-post after a
  // restart or a handoff): follow its records instead of applying it again.
  const earlier = hostRecords(db).filter((record) => {
    const payload = hostRecordPayload(record)
    return payload?.tx === tx && (payload.kind === ADD || payload.kind === REMOVE)
  })
  if (earlier.length > 0) {
    report({ tx, status: "accepted" })
    report(await followEarlier(account, tx, earlier.map((record) => record.id), records))
    return
  }
  const ids = records.map((record) => newHostRecordId(record.kind, now))
  try {
    await db.commit(() => {
      records.forEach((record, index) => {
        record.transaction.prepare?.(db, auth)
        writeHostRecord(db, ids[index]!, { kind: record.kind, tx, context: record.transaction.context }, now)
        record.transaction.optimistic?.(db, auth)
      })
    })
  } catch (error) {
    report({
      tx,
      status: "rejected",
      reason: hasErrorNamed(error, "QuotaExceededError") ? "storageFull" : "invalid",
    })
    return
  }
  report({ tx, status: "accepted" })

  const outcomes = await Promise.all(
    records.map((record, index) =>
      realtime.execute(hostSend(record.transaction, ids[index]!)).then(
        () => "ok" as const,
        (error: unknown) => failureKind(error),
      ),
    ),
  )
  if (outcomes.some((outcome) => outcome === "rpc-error" || outcome === "invalid" || outcome === "dependency-failed")) {
    account.refreshRoster?.(chatId)
  }
  if (outcomes.every((outcome) => outcome === "ok")) {
    report({ tx, status: "confirmed" })
  } else if (outcomes.some((outcome) => outcome === "rpc-error")) {
    report({ tx, status: "rejected", reason: "server" })
  } else if (outcomes.some((outcome) => outcome === "invalid" || outcome === "dependency-failed")) {
    report({ tx, status: "rejected", reason: "invalid" })
  } else {
    // Ambiguous or stopped: the records stay and the next core resends them.
    report({ tx, status: "uncertain" })
  }
}

/**
 * The outcome of records an earlier core committed for this transaction,
 * from the replica: once they are gone (sent, or refused), `confirmed` when
 * every grant is in the state the intent asked for, else `rejected`.
 */
const followEarlier = (
  account: ParticipantAccount,
  tx: TxId,
  recordIds: readonly string[],
  records: ReadonlyArray<{ kind: string; transaction: Transaction }>,
): Promise<IntentResult> =>
  new Promise((resolve) => {
    const { db } = account
    const settled = () => {
      if (recordIds.some((id) => db.get(db.ref(DbObjectKind.PendingTransaction, id)) != null)) return false
      const reached = records.every(({ kind, transaction }) => {
        const context = transaction.context as { chatId: ChatID; userId?: UserID; groupId?: UserGroupID }
        const present =
          context.userId != null
            ? db.get(db.ref(DbObjectKind.ChatParticipant, chatParticipantKey(context.chatId, context.userId))) != null
            : db.get(
                db.ref(DbObjectKind.ChatParticipantGroup, chatParticipantGroupKey(context.chatId, context.groupId!)),
              ) != null
        return kind === ADD ? present : !present
      })
      resolve(reached ? { tx, status: "confirmed" } : { tx, status: "rejected", reason: "server" })
      return true
    }
    if (account.watch) account.watch(settled)
    else if (!settled()) resolve({ tx, status: "uncertain" })
  })
