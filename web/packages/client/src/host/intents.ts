/**
 * Intents mapped onto the existing transactions.
 *
 * Replay-safe intents (`sendText`, `markRead`, `setDialogOpen`) run through
 * the realtime client's durable outbox with an acceptance callback: it fires
 * after the intent and its optimistic rows have committed (invariant 2),
 * which is `accepted`. The transaction's own result gives the final status:
 * it resolves after the server result has committed (`confirmed`) and
 * rejects with the failure kind otherwise (`rejected`, or `uncertain` for an
 * ambiguous or abandoned outcome, never shown as failed).
 *
 * Intents the server cannot take twice safely (`editText`, `deleteMessages`,
 * `react`) never enter the durable outbox and are not restored after a
 * restart. They need a connection (offline they are `rejected` with
 * `offline`, before anything is shown), are sent once, and a request in
 * flight when the connection drops settles `uncertain`.
 * - `react` keeps its optimistic overlay on the message row (the reaction
 *   transactions' `reactionIntents`, committed with the row but never
 *   written to disk); `accepted` follows that commit.
 * - `editText` and `deleteMessages` show through the host's display overlay
 *   (`overlay.ts`): `accepted` once it is installed, since nothing durable
 *   changes on this device until the server answers. Edits of one message
 *   are sent one at a time, in order (invariant 4).
 */
import type {
  MessageActionResponseUi,
  MessageFormValue,
  RpcResult,
} from "@inline-chat/protocol/core"
import {
  ACTION_ANSWER_TIMEOUT_MS,
  isClientKey,
  receivedMessageRowId,
  rowKey,
  sentMessageRowId,
  type ActionAnswer,
  type FormSubmissionValue,
  type Intent,
  type IntentRejection,
  type IntentResult,
  type IntentStatus,
  type RowKey,
  type TxId,
} from "@inline/core-protocol"
import {
  messageId as makeMessageId,
  type ChatID,
  type MessageID,
  type UserID,
} from "@inline/ids"
import type { Db } from "../database"
import {
  DbObjectKind,
  messageKey,
  MessageSendingStatus,
  type Message,
  type MessageKey,
} from "../database/models"
import { DbQueryPlanType } from "../database/types"
import type { RealtimeClient } from "../realtime/realtime"
import {
  addReaction,
  deleteMessages,
  deleteReaction,
  editMessage,
  invokeMessageAction,
  readMessages,
  sendMessage,
  updateDialogOpen,
  TransactionFailure,
  type Transaction,
  type TransactionError,
} from "../realtime/transactions"
import { submitMessageForm } from "../realtime/transactions/submit-message-form"
import { entitiesToProtocol, isValidEntityList } from "../queries/rows"
import { isPositiveId } from "../queries/validate"
import type { AuthStore } from "../auth"
import type { ComposeActionKind } from "@inline/core-protocol"
import { consumeDraft, saveDraft } from "./drafts"
import { PARTICIPANT_INTENTS, runParticipantIntent, type ParticipantIntent } from "./participants"
import { SEND_TX_RECORD, newHostRecordId, writeHostRecord } from "./durable"
import { runSettingsIntent, SETTINGS_INTENTS, type SettingsIntent } from "./settings-intents"
import { hasErrorNamed } from "./errors"
import type { MessageIdentity } from "./message-identity"
import type { PendingOverlay } from "./overlay"
import { inputPeerForChat } from "./peers"

export type IntentAccount = {
  readonly auth: AuthStore
  readonly db: Db
  readonly realtime: RealtimeClient
  readonly identity: MessageIdentity
  readonly userId: UserID
  readonly overlay: PendingOverlay
  /** Queries reading these messages must recompute (an overlay changed). */
  displayChanged(keys: readonly string[]): void
  /** Evaluate `check` now and after every committed batch until it returns true. */
  watch(check: () => boolean): () => void
  serialize<T>(chain: string, task: () => Promise<T>): Promise<T>
  retrySync(): void
  /** The server refused a participant change: fetch the chat's roster again. */
  refreshRoster?(chatId: ChatID): void
  /**
   * A `sendText`'s transaction ID is committed with its outbox entry
   * (`MessageRow.tx`); the account drops the record once the send leaves the
   * outbox.
   */
  rememberSendTx?(clientKey: string, tx: TxId, recordId: string): void
  /** Media sends, attachments and compose activity; absent without a media core. */
  readonly sends?: MediaSendIntents
  setComposeAction?(chatId: ChatID, action: ComposeActionKind | null): void
}

/** What the attachment coordinator (`attachments.ts`) does for intents. */
export type MediaSendIntents = {
  run(
    tx: TxId,
    intent: Extract<Intent, { kind: "attachFile" | "discardAttachment" | "sendMedia" }>,
    report: IntentReport,
    now: number,
  ): Promise<void>
  /** A send from this device with an attachment, by client key: retry it. Undefined when it is not one. */
  retry(tx: TxId, chatId: ChatID, clientKey: string, report: IntentReport): Promise<void> | undefined
  /**
   * Cancel a media send by client key: `cancelled` (removed, uploads
   * cancelled), `landed` (it reached the server: delete it there), or
   * undefined when it is not a media send.
   */
  cancel(chatId: ChatID, clientKey: string): Promise<"cancelled" | MessageID | "unknown"> | undefined
}

export type IntentReport = (result: IntentResult) => void

/** How long a delete waits for a send already on the wire to land before it gives up. */
export const CANCEL_LANDING_TIMEOUT_MS = 120_000

/** At most this many messages in one delete. */
const MAX_DELETE = 100

const result = (
  tx: TxId,
  status: IntentStatus,
  extra: { reason?: IntentRejection; rows?: RowKey[]; answer?: ActionAnswer } = {},
): IntentResult => ({ tx, status, ...extra })

const outcomeOfFailure = (
  kind: TransactionError["kind"],
): { status: IntentStatus; reason?: IntentRejection } => {
  switch (kind) {
    case "rpc-error":
      return { status: "rejected", reason: "server" }
    case "invalid":
    case "dependency-failed":
      return { status: "rejected", reason: "invalid" }
    case "not-connected":
      // Only transient intents fail this way, and only before they are sent.
      return { status: "rejected", reason: "offline" }
    case "ambiguous-result":
    case "timeout":
    case "stopped":
      return { status: "uncertain" }
  }
}

const failureKind = (error: unknown): TransactionError["kind"] =>
  error instanceof TransactionFailure ? error.kind : "ambiguous-result"

const settledResult = (tx: TxId, error: unknown, rows: RowKey[] | undefined): IntentResult => {
  const outcome = outcomeOfFailure(failureKind(error))
  return result(tx, outcome.status, {
    ...(outcome.reason ? { reason: outcome.reason } : {}),
    ...(rows ? { rows } : {}),
  })
}

/**
 * Run a transaction and report acceptance after its commit, then its
 * outcome.
 */
const executeAccepted = async (
  realtime: RealtimeClient,
  transaction: Transaction,
  tx: TxId,
  rows: RowKey[] | undefined,
  report: IntentReport,
) => {
  const withRows = rows ? { rows } : {}
  let accepted = false
  try {
    await realtime.execute(transaction, {
      onAccepted: () => {
        accepted = true
        report(result(tx, "accepted", withRows))
      },
    })
    report(result(tx, accepted ? "confirmed" : "rejected", accepted ? withRows : { reason: "invalid" }))
  } catch (error) {
    if (!accepted) {
      report(rejectionFor(tx, error))
      return
    }
    report(settledResult(tx, error, rows))
  }
}

/** Learn the server ID of a send while its result is applied, before any batch is published. */
const onApply = (
  transaction: Transaction,
  hook: (rpcResult: RpcResult["result"] | undefined) => void,
) => {
  const apply = transaction.apply.bind(transaction)
  transaction.apply = (rpcResult, db) => {
    hook(rpcResult)
    apply(rpcResult, db)
  }
}

export type RunIntentOptions = {
  account: IntentAccount
  tx: TxId
  intent: Intent
  report: IntentReport
  /** Milliseconds since the epoch. */
  now: number
}

const SUPPORTED = new Set<Intent["kind"]>([
  "sendText",
  "editText",
  "deleteMessages",
  "react",
  "markRead",
  "saveDraft",
  "setDialogOpen",
  "retrySync",
  "invokeAction",
  "submitForm",
  ...SETTINGS_INTENTS,
  "attachFile",
  "discardAttachment",
  "sendMedia",
  "retrySend",
  "composeAction",
  ...PARTICIPANT_INTENTS,
])

const COMPOSE_ACTIONS = new Set<string>([
  "typing",
  "uploadingPhoto",
  "uploadingDocument",
  "uploadingVideo",
  "recordingVoice",
  "working",
])

/**
 * Run one intent to its final result, reporting `accepted` on the way. The
 * promise settles when the outcome is known (a send waits for the server).
 * Never throws: every failure is reported as a result.
 */
export const runIntent = async (options: RunIntentOptions): Promise<void> => {
  const { account, tx, intent, report } = options
  if (intent == null || typeof intent !== "object") {
    report(result(tx, "rejected", { reason: "invalid" }))
    return
  }
  if (!SUPPORTED.has(intent.kind)) {
    report(result(tx, "rejected", { reason: "unsupported" }))
    return
  }
  if (intent.kind === "retrySync") {
    account.retrySync()
    report(result(tx, "confirmed"))
    return
  }
  if (intent.kind === "updateUserSettings") {
    return await runSettingsIntent(account, tx, intent, report, options.now)
  }
  if (intent.kind === "attachFile" || intent.kind === "discardAttachment") {
    if (!account.sends) {
      report(result(tx, "rejected", { reason: "unsupported" }))
      return
    }
    return await account.sends.run(tx, intent, report, options.now)
  }
  if (intent.kind === "mediaHints") {
    // Handled by the host, which knows the context; nothing reaches here.
    report(result(tx, "confirmed"))
    return
  }
  if (!isPositiveId(intent.chatId)) {
    report(result(tx, "rejected", { reason: "invalid" }))
    return
  }
  if (SETTINGS_INTENTS.has(intent.kind)) {
    return await runSettingsIntent(account, tx, intent as SettingsIntent, report, options.now)
  }
  if (PARTICIPANT_INTENTS.has(intent.kind)) {
    return await runParticipantIntent(account, tx, intent as ParticipantIntent, report, options.now)
  }

  switch (intent.kind) {
    case "saveDraft":
      return await runSaveDraft(account, tx, intent, report, options.now)
    case "editText":
      return await runEdit(account, tx, intent, report, options.now)
    case "deleteMessages":
      return await runDelete(account, tx, intent, report)
    case "react":
      return await runReact(account, tx, intent, report)
    case "sendText":
      return await runSend(account, tx, intent, report, options.now)
    case "markRead":
    case "setDialogOpen":
      return await runDialogIntent(account, tx, intent, report)
    case "invokeAction":
    case "submitForm":
      return await runMessageAction(account, tx, intent, report)
    case "sendMedia":
      if (!account.sends) {
        report(result(tx, "rejected", { reason: "unsupported" }))
        return
      }
      return await account.sends.run(tx, intent, report, options.now)
    case "retrySend":
      return await runRetrySend(account, tx, intent, report)
    case "composeAction": {
      if (intent.action !== null && !COMPOSE_ACTIONS.has(intent.action)) {
        report(result(tx, "rejected", { reason: "invalid" }))
        return
      }
      account.setComposeAction?.(intent.chatId, intent.action)
      report(result(tx, "confirmed"))
      return
    }
  }
}

/** Send again a failed send from this device: a media send through its coordinator, a text send through the outbox. */
const runRetrySend = async (
  account: IntentAccount,
  tx: TxId,
  intent: Extract<Intent, { kind: "retrySend" }>,
  report: IntentReport,
) => {
  if (!isClientKey(intent.clientKey)) {
    report(result(tx, "rejected", { reason: "invalid" }))
    return
  }
  const media = account.sends?.retry(tx, intent.chatId, intent.clientKey, report)
  if (media) return await media
  const local = localSend(account.db, BigInt(intent.clientKey))
  if (!local || local.chatId !== intent.chatId || local.status !== MessageSendingStatus.Failed) {
    report(result(tx, "rejected", { reason: "invalid" }))
    return
  }
  const rows: RowKey[] = [rowKey("message", sentMessageRowId(intent.chatId, intent.clientKey))]
  report(result(tx, "accepted", { rows }))
  try {
    await account.realtime.resendMessage(intent.chatId, local.messageId)
    report(result(tx, "confirmed", { rows }))
  } catch (error) {
    report(settledResult(tx, error, rows))
  }
}

// ---------------------------------------------------------------------------
// Drafts, sends and dialog intents (durable)

const runSaveDraft = async (
  account: IntentAccount,
  tx: TxId,
  intent: Extract<Intent, { kind: "saveDraft" }>,
  report: IntentReport,
  now: number,
) => {
  if (
    typeof intent.text !== "string" ||
    !Number.isSafeInteger(intent.revision) ||
    (intent.entities != null && !isValidEntityList(intent.entities))
  ) {
    report(result(tx, "rejected", { reason: "invalid" }))
    return
  }
  try {
    await saveDraft(
      account.db,
      {
        chatId: intent.chatId,
        text: intent.text,
        revision: intent.revision,
        ...(intent.entities ? { entities: intent.entities } : {}),
      },
      now,
    )
  } catch (error) {
    report(rejectionFor(tx, error))
    return
  }
  // Drafts are local-only: durable on this device is final.
  const rows: RowKey[] = [rowKey("draft", intent.chatId)]
  report(result(tx, "accepted", { rows }))
  report(result(tx, "confirmed", { rows }))
}

const runSend = async (
  account: IntentAccount,
  tx: TxId,
  intent: Extract<Intent, { kind: "sendText" }>,
  report: IntentReport,
  now: number,
) => {
  if (
    !isClientKey(intent.clientKey) ||
    typeof intent.text !== "string" ||
    (intent.text.trim().length === 0 && !intent.entities?.length) ||
    (intent.entities != null && !isValidEntityList(intent.entities)) ||
    (intent.replyToMessageId != null && !isPositiveId(intent.replyToMessageId)) ||
    (intent.date != null && (!Number.isSafeInteger(intent.date) || intent.date < 0)) ||
    (intent.draftRevision != null && !Number.isSafeInteger(intent.draftRevision))
  ) {
    report(result(tx, "rejected", { reason: "invalid" }))
    return
  }
  const randomId = BigInt(intent.clientKey)
  const rows: RowKey[] = [rowKey("message", sentMessageRowId(intent.chatId, intent.clientKey))]
  if (localSend(account.db, randomId)) {
    // A retry of a send already accepted here or by an earlier core (a
    // handoff, a lost reply, a restart): it is in the outbox. Follow it to
    // its outcome instead of sending it twice.
    report(result(tx, "accepted", { rows }))
    report(await followLocalSend(account, intent.clientKey, randomId, tx, rows))
    return
  }
  const entities = entitiesToProtocol(intent.entities)
  const transaction = sendMessage({
    chatId: intent.chatId,
    peerId: inputPeerForChat(account.db, intent.chatId),
    text: intent.text,
    randomId,
    temporarySendDate: intent.date ?? Math.floor(now / 1000),
    ...(entities ? { entities } : {}),
    ...(intent.replyToMessageId ? { replyToMsgId: intent.replyToMessageId } : {}),
  })
  const chatId = intent.chatId
  const clientKey = intent.clientKey
  onApply(transaction, (rpcResult) => {
    const serverId = assignedMessageId(rpcResult, randomId)
    if (serverId) account.identity.register(messageKey(chatId, serverId), clientKey)
  })
  // The draft revision and the UI's transaction ID commit with the outbox
  // entry and the optimistic row: one commit (invariant 2).
  const draftRevision = intent.draftRevision
  const txRecord = account.rememberSendTx ? newHostRecordId(SEND_TX_RECORD, now) : undefined
  const optimistic = transaction.optimistic?.bind(transaction)
  transaction.optimistic = (db, auth) => {
    optimistic?.(db, auth)
    if (draftRevision != null) consumeDraft(db, chatId, draftRevision)
    if (txRecord) {
      writeHostRecord(db, txRecord, { kind: SEND_TX_RECORD, tx, context: { chatId, clientKey } }, now)
      // Known before the commit is published, so the first committed row carries it.
      account.rememberSendTx?.(clientKey, tx, txRecord)
    }
  }
  if (draftRevision != null) rows.push(rowKey("draft", chatId))
  await executeAccepted(account.realtime, transaction, tx, rows, report)
}

/**
 * The outcome of a send that is already in the outbox, from the replica:
 * it landed (the server assigned an ID: `confirmed`), failed (`rejected`), or
 * vanished without landing (`uncertain`).
 */
const followLocalSend = (
  account: IntentAccount,
  clientKey: string,
  randomId: bigint,
  tx: TxId,
  rows: RowKey[],
): Promise<IntentResult> =>
  new Promise((resolve) => {
    account.watch(() => {
      if (account.identity.serverKeyFor(clientKey)) {
        resolve(result(tx, "confirmed", { rows }))
        return true
      }
      const local = localSend(account.db, randomId)
      if (!local) {
        resolve(result(tx, "uncertain", { rows }))
        return true
      }
      if (local.status === MessageSendingStatus.Failed) {
        resolve(result(tx, "rejected", { reason: "server", rows }))
        return true
      }
      return false
    })
  })

const runDialogIntent = async (
  account: IntentAccount,
  tx: TxId,
  intent: Extract<Intent, { kind: "markRead" | "setDialogOpen" }>,
  report: IntentReport,
) => {
  const peerId = inputPeerForChat(account.db, intent.chatId)
  let transaction: Transaction
  if (intent.kind === "markRead") {
    if (!isPositiveId(intent.maxId)) {
      report(result(tx, "rejected", { reason: "invalid" }))
      return
    }
    transaction = readMessages({ peerId, maxId: intent.maxId })
  } else {
    if (typeof intent.open !== "boolean") {
      report(result(tx, "rejected", { reason: "invalid" }))
      return
    }
    transaction = updateDialogOpen({ peerId, open: intent.open })
  }
  await executeAccepted(account.realtime, transaction, tx, undefined, report)
}

// ---------------------------------------------------------------------------
// Edit, delete, react (transient: not replay-safe on the server)

const offline = (account: IntentAccount) => account.realtime.connectionState !== "connected"

/** The row key a message has in the UI (by client key for a send from this device). */
const messageRowKey = (account: IntentAccount, chatId: ChatID, id: MessageID): RowKey => {
  const key = messageKey(chatId, id)
  const stored = account.db.get(account.db.ref(DbObjectKind.Message, key))
  const clientKey = stored ? account.identity.clientKeyFor(stored) : undefined
  return rowKey(
    "message",
    clientKey ? sentMessageRowId(chatId, clientKey) : receivedMessageRowId(chatId, id),
  )
}

const runEdit = async (
  account: IntentAccount,
  tx: TxId,
  intent: Extract<Intent, { kind: "editText" }>,
  report: IntentReport,
  now: number,
) => {
  if (
    !isPositiveId(intent.messageId) ||
    typeof intent.text !== "string" ||
    (intent.text.trim().length === 0 && !intent.entities?.length) ||
    (intent.entities != null && !isValidEntityList(intent.entities))
  ) {
    report(result(tx, "rejected", { reason: "invalid" }))
    return
  }
  if (offline(account)) {
    report(result(tx, "rejected", { reason: "offline" }))
    return
  }
  const { chatId, messageId } = intent
  const key = messageKey(chatId, messageId)
  const rows = [messageRowKey(account, chatId, messageId)]
  const entities = entitiesToProtocol(intent.entities)
  account.overlay.addEdit(key, {
    tx,
    text: intent.text,
    ...(entities ? { entities } : {}),
    date: Math.floor(now / 1000),
  })
  account.displayChanged([key])
  report(result(tx, "accepted", { rows }))
  try {
    // One edit of a message on the wire at a time, in the order they were made.
    await account.serialize(`edit:${key}`, () =>
      account.realtime.execute(
        editMessage({
          chatId,
          messageId,
          peerId: inputPeerForChat(account.db, chatId),
          text: intent.text,
          ...(entities ? { entities } : {}),
        }),
      ),
    )
    // The server's update has committed (the result resolves after its
    // commit), so the base already shows this text when the overlay goes.
    report(result(tx, "confirmed", { rows }))
  } catch (error) {
    report(settledResult(tx, error, rows))
  } finally {
    account.overlay.removeEdit(key, tx)
    account.displayChanged([key])
  }
}

const runReact = async (
  account: IntentAccount,
  tx: TxId,
  intent: Extract<Intent, { kind: "react" }>,
  report: IntentReport,
) => {
  if (
    !isPositiveId(intent.messageId) ||
    typeof intent.emoji !== "string" ||
    intent.emoji.length === 0 ||
    intent.emoji.length > 64 ||
    (intent.action !== "add" && intent.action !== "remove")
  ) {
    report(result(tx, "rejected", { reason: "invalid" }))
    return
  }
  const context = {
    chatId: intent.chatId,
    messageId: intent.messageId,
    emoji: intent.emoji,
    peerId: inputPeerForChat(account.db, intent.chatId),
  }
  const rows = [messageRowKey(account, intent.chatId, intent.messageId)]
  // Not in the outbox: the realtime client refuses it offline, sends it
  // once, and reports one in flight across a reconnect as ambiguous.
  await executeAccepted(
    account.realtime,
    intent.action === "add" ? addReaction(context) : deleteReaction(context),
    tx,
    rows,
    report,
  )
}

// ---------------------------------------------------------------------------
// Bot buttons and forms (transient: a bot interaction is not replay-safe)

const isActionId = (value: unknown): value is string =>
  typeof value === "string" && value.trim().length > 0 && value.length <= 256

const formValue = (value: unknown): MessageFormValue | undefined => {
  if (value == null || typeof value !== "object") return undefined
  const { fieldId, value: answer } = value as FormSubmissionValue
  if (typeof fieldId !== "string" || fieldId.length === 0 || answer == null) return undefined
  const base = { fieldId, redacted: false }
  switch (answer.kind) {
    case "text":
      return typeof answer.text === "string" ? { ...base, value: { oneofKind: "text", text: answer.text } } : undefined
    case "toggle":
      return typeof answer.value === "boolean"
        ? { ...base, value: { oneofKind: "toggle", toggle: answer.value } }
        : undefined
    case "number":
      return Number.isFinite(answer.value)
        ? { ...base, value: { oneofKind: "number", number: answer.value } }
        : undefined
    case "selection":
      return Array.isArray(answer.optionIds) &&
        answer.optionIds.every((id) => typeof id === "string") &&
        (answer.otherText == null || typeof answer.otherText === "string")
        ? {
            ...base,
            value: {
              oneofKind: "selection",
              selection: {
                optionIds: [...answer.optionIds],
                ...(answer.otherText != null ? { otherText: answer.otherText } : {}),
              },
            },
          }
        : undefined
    default:
      return undefined
  }
}

const actionAnswer = (ui: MessageActionResponseUi | undefined): ActionAnswer | undefined => {
  const kind = ui?.kind
  if (kind?.oneofKind === "toast") return { kind: "toast", text: kind.toast.text }
  if (kind?.oneofKind === "alert") {
    return {
      kind: "alert",
      text: kind.alert.text,
      ...(kind.alert.title ? { title: kind.alert.title } : {}),
    }
  }
  return undefined
}

const runMessageAction = async (
  account: IntentAccount,
  tx: TxId,
  intent: Extract<Intent, { kind: "invokeAction" | "submitForm" }>,
  report: IntentReport,
) => {
  if (!isPositiveId(intent.messageId)) {
    report(result(tx, "rejected", { reason: "invalid" }))
    return
  }
  const peerId = inputPeerForChat(account.db, intent.chatId)
  let transaction: Transaction
  if (intent.kind === "invokeAction") {
    if (!isActionId(intent.actionId)) {
      report(result(tx, "rejected", { reason: "invalid" }))
      return
    }
    transaction = invokeMessageAction({
      chatId: intent.chatId,
      messageId: intent.messageId,
      peerId,
      actionId: intent.actionId,
    })
  } else {
    const values = Array.isArray(intent.values) ? intent.values.map(formValue) : [undefined]
    if (!isActionId(intent.formId) || values.some((value) => value === undefined)) {
      report(result(tx, "rejected", { reason: "invalid" }))
      return
    }
    transaction = submitMessageForm({
      chatId: intent.chatId,
      messageId: intent.messageId,
      peerId,
      formId: intent.formId.trim(),
      form: { values: values as MessageFormValue[] },
    })
  }
  const rows = [messageRowKey(account, intent.chatId, intent.messageId)]
  let accepted = false
  try {
    const outcome = await account.realtime.execute(transaction, {
      onAccepted: () => {
        accepted = true
        report(result(tx, "accepted", { rows }))
      },
    })
    const interactionId =
      outcome?.oneofKind === "invokeMessageAction" ? outcome.invokeMessageAction.interactionId : 0n
    const answer =
      interactionId > 0n
        ? actionAnswer(
            (
              await account.realtime.waitForMessageActionAnswer(interactionId, {
                timeoutMs: ACTION_ANSWER_TIMEOUT_MS,
              })
            )?.ui,
          )
        : undefined
    report(result(tx, "confirmed", { rows, ...(answer ? { answer } : {}) }))
  } catch (error) {
    report(accepted ? settledResult(tx, error, rows) : rejectionFor(tx, error))
  }
}

type DeleteTarget =
  | { kind: "server"; messageId: MessageID }
  | { kind: "media"; clientKey: string; outcome: Promise<"cancelled" | MessageID | "unknown"> }
  | { kind: "local"; message: Message; clientKey: string }

const runDelete = async (
  account: IntentAccount,
  tx: TxId,
  intent: Extract<Intent, { kind: "deleteMessages" }>,
  report: IntentReport,
) => {
  const messageIds: unknown = intent.messageIds ?? []
  const clientKeys: unknown = intent.clientKeys ?? []
  if (
    !Array.isArray(messageIds) ||
    !Array.isArray(clientKeys) ||
    !messageIds.every(isPositiveId) ||
    !clientKeys.every(isClientKey) ||
    messageIds.length + clientKeys.length === 0 ||
    messageIds.length + clientKeys.length > MAX_DELETE
  ) {
    report(result(tx, "rejected", { reason: "invalid" }))
    return
  }
  const chatId = intent.chatId
  const targets: DeleteTarget[] = []
  const serverIds = new Set<MessageID>(messageIds as MessageID[])
  for (const clientKey of clientKeys as string[]) {
    const media = account.sends?.cancel(chatId, clientKey)
    if (media) {
      targets.push({ kind: "media", clientKey, outcome: media })
      continue
    }
    const local = localSend(account.db, BigInt(clientKey))
    if (local && local.chatId === chatId) {
      targets.push({ kind: "local", message: local, clientKey })
      continue
    }
    const landed = account.identity.serverKeyFor(clientKey)
    if (landed && landed.startsWith(`${chatId}:`)) {
      serverIds.add(makeMessageId(landed.slice(landed.indexOf(":") + 1)))
    }
    // Otherwise it is not on this device any more: nothing to delete here.
  }
  for (const messageId of serverIds) targets.push({ kind: "server", messageId })
  if (targets.length === 0) {
    report(result(tx, "confirmed"))
    return
  }
  // A send still in the outbox is cancelled locally, online or not.
  if (targets.some((target) => target.kind === "server") && offline(account)) {
    report(result(tx, "rejected", { reason: "offline" }))
    return
  }

  const hidden = new Set<MessageKey>()
  const hide = (key: MessageKey) => {
    hidden.add(key)
    account.overlay.hide(key, tx)
  }
  const rows: RowKey[] = []
  for (const target of targets) {
    if (target.kind === "server") {
      hide(messageKey(chatId, target.messageId))
      rows.push(messageRowKey(account, chatId, target.messageId))
    } else if (target.kind === "local") {
      hide(target.message.id)
      rows.push(rowKey("message", sentMessageRowId(chatId, target.clientKey)))
    } else {
      rows.push(rowKey("message", sentMessageRowId(chatId, target.clientKey)))
    }
  }
  account.displayChanged(Array.from(hidden))
  report(result(tx, "accepted", { rows }))

  let uncertain = false
  try {
    const toDelete = targets.flatMap((target) =>
      target.kind === "server" ? [target.messageId] : [],
    )
    for (const target of targets) {
      if (target.kind === "media") {
        const landed = await target.outcome
        if (landed === "unknown") uncertain = true
        else if (landed !== "cancelled") toDelete.push(landed)
        continue
      }
      if (target.kind !== "local") continue
      const landed = await cancelSend(account, chatId, target, hide)
      if (landed === "unknown") uncertain = true
      else if (landed !== "cancelled") toDelete.push(landed)
    }
    if (toDelete.length > 0) {
      await account.realtime.execute(
        deleteMessages({
          chatId,
          messageIds: toDelete,
          peerId: inputPeerForChat(account.db, chatId),
        }),
      )
    }
    report(result(tx, uncertain ? "uncertain" : "confirmed", { rows }))
  } catch (error) {
    report(settledResult(tx, error, rows))
  } finally {
    for (const key of hidden) account.overlay.unhide(key, tx)
    account.displayChanged(Array.from(hidden))
  }
}

/**
 * Cancel a send from this device. A send still in the outbox (queued, or
 * failed) is removed with its row in one commit, so the server never sees
 * it. A send already on the wire cannot be recalled: wait for it to land
 * (keeping its server row hidden) and return its server ID to delete, as
 * the Mac app's `CancelledSends` does.
 */
const cancelSend = async (
  account: IntentAccount,
  chatId: ChatID,
  target: Extract<DeleteTarget, { kind: "local" }>,
  hide: (key: MessageKey) => void,
): Promise<"cancelled" | "unknown" | MessageID> => {
  if (await account.realtime.cancelPendingMessage(chatId, target.message.messageId)) {
    return "cancelled"
  }
  const randomId = BigInt(target.clientKey)
  const landing = await new Promise<"failed" | "gone" | MessageKey | undefined>((resolve) => {
    let timer: ReturnType<typeof setTimeout> | undefined
    const stop = account.watch(() => {
      const landed = account.identity.serverKeyFor(target.clientKey)
      let outcome: "failed" | "gone" | MessageKey | undefined
      if (landed) {
        // Hide the server row before the batch that brings it is published.
        hide(landed)
        outcome = landed
      } else {
        const local = localSend(account.db, randomId)
        if (!local) outcome = "gone"
        else if (local.status === MessageSendingStatus.Failed) outcome = "failed"
      }
      if (outcome === undefined) return false
      if (timer) clearTimeout(timer)
      resolve(outcome)
      return true
    })
    timer = setTimeout(() => {
      stop()
      resolve(undefined)
    }, CANCEL_LANDING_TIMEOUT_MS)
  })
  if (landing === undefined || landing === "gone") return "unknown"
  if (landing === "failed") {
    // The send failed: removing it locally is the whole delete.
    return (await account.realtime.cancelPendingMessage(chatId, target.message.messageId))
      ? "cancelled"
      : "unknown"
  }
  return makeMessageId(landing.slice(landing.indexOf(":") + 1))
}

// ---------------------------------------------------------------------------

const rejectionFor = (tx: TxId, error: unknown): IntentResult => {
  if (hasErrorNamed(error, "QuotaExceededError")) {
    return result(tx, "rejected", { reason: "storageFull" })
  }
  if (error instanceof TransactionFailure && error.kind === "stopped") {
    return result(tx, "rejected", { reason: "unavailable" })
  }
  if (error instanceof TransactionFailure && error.kind === "not-connected") {
    return result(tx, "rejected", { reason: "offline" })
  }
  return result(tx, "rejected", { reason: "invalid" })
}

/** The resident local send with this random ID (stored under its temporary key until it lands). */
const localSend = (db: Db, randomId: bigint): Message | undefined =>
  db
    .queryCollection<DbObjectKind.Message, Message, DbQueryPlanType.Objects>(
      DbQueryPlanType.Objects,
      DbObjectKind.Message,
      (message) => message.randomId === randomId,
    )
    .at(0)

/** The server ID the result assigned to the send with this random ID. */
const assignedMessageId = (
  rpcResult: RpcResult["result"] | undefined,
  randomId: bigint,
): MessageID | undefined => {
  if (rpcResult?.oneofKind !== "sendMessage") return undefined
  for (const update of rpcResult.sendMessage.updates) {
    if (
      update.update.oneofKind === "updateMessageId" &&
      update.update.updateMessageId.randomId === randomId
    ) {
      return makeMessageId(update.update.updateMessageId.messageId)
    }
  }
  return undefined
}
