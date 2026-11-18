/**
 * Settings intents: account settings and per-dialog state.
 *
 * Durable through the realtime outbox (its registry restores them):
 * `setDialogFollow` (`update_dialog_follow_mode`), `setDialogPinned`
 * (`update_dialog_order`), `markUnread` (`mark_as_unread`).
 *
 * Durable through host records (`durable.ts`), because their transactions
 * are new and the outbox registry does not know them: `updateUserSettings`,
 * `setDialogNotifications`, `setDialogArchived`, `readAll`.
 *
 * Every one is replay-safe on the server (a target state or a max), retried
 * after a lost acknowledgement or a dropped connection, and `accepted` only
 * after the commit that holds it and its optimistic rows.
 */
import type { IntentResult, TxId, UserSettingsPatch as ProtocolSettingsPatch } from "@inline/core-protocol"
import type { Intent } from "@inline/core-protocol"
import type { AuthStore } from "../auth"
import type { Db } from "../database"
import type { NotificationMode } from "../database/models"
import type { RealtimeClient } from "../realtime/realtime"
import {
  markAsUnread,
  updateDialogFollowMode,
  updateDialogOrder,
  updateUserSettings,
  TransactionFailure,
  type Transaction,
} from "../realtime/transactions"
import { readDialog, ReadDialogTransaction } from "../realtime/transactions/read-dialog"
import {
  updateDialogArchived,
  UpdateDialogArchivedTransaction,
  type UpdateDialogArchivedContext,
} from "../realtime/transactions/update-dialog-archived"
import {
  updateDialogNotificationSettings,
  UpdateDialogNotificationSettingsTransaction,
  type UpdateDialogNotificationSettingsContext,
} from "../realtime/transactions/update-dialog-notification-settings"
import {
  UpdateUserSettingsTransaction,
  type UpdateUserSettingsContext,
} from "../realtime/transactions/update-user-settings"
import type { UserSettingsPatch } from "../realtime/updates/settings"
import { commitHostRecord, hostSend, type HostRecordPayload } from "./durable"
import { hasErrorNamed } from "./errors"
import { inputPeerForChat } from "./peers"

export type SettingsIntent = Extract<
  Intent,
  {
    kind:
      | "updateUserSettings"
      | "setDialogNotifications"
      | "setDialogFollow"
      | "setDialogPinned"
      | "setDialogArchived"
      | "markUnread"
      | "readAll"
  }
>

export const SETTINGS_INTENTS = new Set<Intent["kind"]>([
  "updateUserSettings",
  "setDialogNotifications",
  "setDialogFollow",
  "setDialogPinned",
  "setDialogArchived",
  "markUnread",
  "readAll",
])

export type SettingsAccount = {
  readonly db: Db
  readonly auth: AuthStore
  readonly realtime: RealtimeClient
}

type Report = (result: IntentResult) => void

const ACCOUNT_MODES = new Set<NotificationMode>(["all", "none", "mentions", "importantOnly", "onlyMentions"])

const isBool = (value: unknown) => value === undefined || typeof value === "boolean"
const isText = (value: unknown, max = 4096) =>
  value === undefined || (typeof value === "string" && value.length <= max)

/** A settings patch from the protocol, checked field by field; undefined when malformed. */
export const settingsPatch = (patch: ProtocolSettingsPatch | undefined): UserSettingsPatch | undefined => {
  if (patch == null || typeof patch !== "object") return undefined
  const out: UserSettingsPatch = {}
  const { notifications, privacy, compose, messageGestures } = patch
  if (notifications !== undefined) {
    if (notifications == null || typeof notifications !== "object") return undefined
    if (notifications.mode !== undefined && !ACCOUNT_MODES.has(notifications.mode)) return undefined
    if (
      !isBool(notifications.silent) ||
      !isBool(notifications.zenModeRequiresMention) ||
      !isBool(notifications.zenModeUsesDefaultRules) ||
      !isBool(notifications.disableDmNotifications) ||
      !isText(notifications.zenModeCustomRules, 16_384)
    ) {
      return undefined
    }
    out.notifications = { ...notifications }
  }
  if (privacy !== undefined) {
    if (privacy == null || !isBool(privacy.shareTimeZone) || !isBool(privacy.appearInGlobalSearch)) return undefined
    out.privacy = {
      ...(privacy.shareTimeZone !== undefined ? { shareTimeZone: privacy.shareTimeZone } : {}),
      ...(privacy.appearInGlobalSearch !== undefined ? { appearInGlobalSearch: privacy.appearInGlobalSearch } : {}),
    }
  }
  if (compose !== undefined) {
    if (compose == null || !isBool(compose.replacePastedLinksWithTitles)) return undefined
    out.compose = { ...compose }
  }
  if (messageGestures !== undefined) {
    if (
      messageGestures == null ||
      !isText(messageGestures.doubleTapAction, 64) ||
      !isText(messageGestures.holdAction, 64) ||
      !isText(messageGestures.swipeToReplyDirection, 64)
    ) {
      return undefined
    }
    out.messageGestures = { ...messageGestures }
  }
  return Object.keys(out).length > 0 ? out : undefined
}

/** Rebuild a host record's transaction after a restart. */
export const decodeSettingsRecord = (payload: HostRecordPayload): Transaction | undefined => {
  const context = payload.context as never
  switch (payload.kind) {
    case "userSettings":
      return new UpdateUserSettingsTransaction(context as UpdateUserSettingsContext)
    case "dialogNotifications":
      return new UpdateDialogNotificationSettingsTransaction(context as UpdateDialogNotificationSettingsContext)
    case "dialogArchived":
      return new UpdateDialogArchivedTransaction(context as UpdateDialogArchivedContext)
    case "readAll":
      return new ReadDialogTransaction(context)
    default:
      return undefined
  }
}

const failureKind = (error: unknown) => (error instanceof TransactionFailure ? error.kind : "ambiguous-result")

const rejected = (tx: TxId, error: unknown): IntentResult => {
  if (hasErrorNamed(error, "QuotaExceededError")) return { tx, status: "rejected", reason: "storageFull" }
  return { tx, status: "rejected", reason: "invalid" }
}

const outcome = (tx: TxId, error: unknown): IntentResult => {
  switch (failureKind(error)) {
    case "rpc-error":
      return { tx, status: "rejected", reason: "server" }
    case "invalid":
    case "dependency-failed":
      return { tx, status: "rejected", reason: "invalid" }
    default:
      return { tx, status: "uncertain" }
  }
}

/** Commit a host record and its optimistic rows (`accepted`), then send. */
const runHostDurable = async (
  account: SettingsAccount,
  tx: TxId,
  kind: string,
  transaction: Transaction,
  report: Report,
  now: number,
) => {
  let recordId: string
  try {
    recordId = await commitHostRecord(account.db, account.auth, transaction, { kind, tx }, now)
  } catch (error) {
    report(rejected(tx, error))
    return
  }
  report({ tx, status: "accepted" })
  try {
    await account.realtime.execute(hostSend(transaction, recordId))
    report({ tx, status: "confirmed" })
  } catch (error) {
    report(outcome(tx, error))
  }
}

/** Through the realtime outbox: `accepted` after its commit. */
const runOutbox = async (account: SettingsAccount, tx: TxId, transaction: Transaction, report: Report) => {
  let accepted = false
  try {
    await account.realtime.execute(transaction, {
      onAccepted: () => {
        accepted = true
        report({ tx, status: "accepted" })
      },
    })
    report({ tx, status: "confirmed" })
  } catch (error) {
    report(accepted ? outcome(tx, error) : rejected(tx, error))
  }
}

export const runSettingsIntent = async (
  account: SettingsAccount,
  tx: TxId,
  intent: SettingsIntent,
  report: Report,
  now: number,
): Promise<void> => {
  const invalid = () => report({ tx, status: "rejected", reason: "invalid" })
  if (intent.kind === "updateUserSettings") {
    const patch = settingsPatch(intent.patch)
    if (!patch) return invalid()
    return runHostDurable(account, tx, "userSettings", updateUserSettings(patch), report, now)
  }
  const peerId = inputPeerForChat(account.db, intent.chatId)
  switch (intent.kind) {
    case "setDialogNotifications": {
      if (!["all", "mentions", "none", "default"].includes(intent.mode)) return invalid()
      const mode = intent.mode === "default" ? undefined : intent.mode
      return runHostDurable(
        account,
        tx,
        "dialogNotifications",
        updateDialogNotificationSettings({ peerId, ...(mode ? { mode } : {}) }),
        report,
        now,
      )
    }
    case "setDialogArchived":
      if (typeof intent.archived !== "boolean") return invalid()
      return runHostDurable(
        account,
        tx,
        "dialogArchived",
        updateDialogArchived({ peerId, archived: intent.archived }),
        report,
        now,
      )
    case "readAll":
      return runHostDurable(account, tx, "readAll", readDialog({ peerId }), report, now)
    case "setDialogFollow":
      if (!["relevance", "following", "unfollowed"].includes(intent.mode)) return invalid()
      return runOutbox(account, tx, updateDialogFollowMode({ peerId, selection: intent.mode }), report)
    case "setDialogPinned":
      if (typeof intent.pinned !== "boolean") return invalid()
      return runOutbox(account, tx, updateDialogOrder({ peerId, pinned: intent.pinned }), report)
    case "markUnread":
      return runOutbox(account, tx, markAsUnread({ peerId }), report)
  }
}
