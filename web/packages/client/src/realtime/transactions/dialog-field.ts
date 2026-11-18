import type { InputPeer } from "@inline-chat/protocol/core"
import type { Db } from "../../database"
import type { Dialog } from "../../database/models"
import { dialogForPeer } from "./dialog-for-peer"

/**
 * A single optimistic dialog field: set it, and on failure put the previous
 * value back only while the dialog still shows the optimistic one (a later
 * server update wins). Shared by the host's dialog setting transactions.
 */
export type DialogFieldContext<K extends keyof Dialog> = {
  peerId: InputPeer
  /** The stored value before the optimistic change; `null` when the dialog was not stored. */
  previous?: { value: Dialog[K] | undefined } | null
}

export const prepareDialogField = <K extends keyof Dialog>(
  db: Db,
  context: DialogFieldContext<K>,
  field: K,
) => {
  if (context.previous !== undefined) return
  const dialog = dialogForPeer(db, context.peerId)
  context.previous = dialog ? { value: dialog[field] } : null
}

export const setDialogField = <K extends keyof Dialog>(
  db: Db,
  peerId: InputPeer,
  field: K,
  value: Dialog[K] | undefined,
) => {
  const dialog = dialogForPeer(db, peerId)
  if (!dialog || dialog[field] === value) return
  const next = { ...dialog }
  if (value === undefined) delete next[field]
  else next[field] = value
  db.replace(next)
}

export const rollbackDialogField = <K extends keyof Dialog>(
  db: Db,
  context: DialogFieldContext<K>,
  field: K,
  optimistic: Dialog[K] | undefined,
) => {
  const dialog = dialogForPeer(db, context.peerId)
  if (!dialog || !context.previous || dialog[field] !== optimistic) return
  setDialogField(db, context.peerId, field, context.previous.value)
}
