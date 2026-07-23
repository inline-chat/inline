import type { InputPeer } from "@inline-chat/protocol/core"
import type { Db } from "../../database"
import type { Dialog } from "../../database/models"
import { dialogForPeer } from "./dialog-for-peer"

export type DialogIntentId = number
export type DialogIntentField =
  | "open"
  | "order"
  | "archived"
  | "chatListHidden"
  | "pinned"
  | "pinnedOrder"
  | "followMode"
export type DialogIntentSnapshot = Partial<
  Pick<Dialog, DialogIntentField>
>

let nextIntentId = Date.now()
const latestIntentByDatabase = new WeakMap<
  Db,
  Map<string, Map<DialogIntentField, DialogIntentId>>
>()

const peerIdentity = (peer: InputPeer) => {
  if (peer.type.oneofKind === "user") return `user:${peer.type.user.userId}`
  if (peer.type.oneofKind === "chat") return `chat:${peer.type.chat.chatId}`
  return "invalid"
}

const intentsFor = (db: Db) => {
  let intents = latestIntentByDatabase.get(db)
  if (!intents) {
    intents = new Map()
    latestIntentByDatabase.set(db, intents)
  }
  return intents
}

/** Orders every full-dialog mutation, even when the RPC methods differ. */
export const nextDialogIntentId = (): DialogIntentId => ++nextIntentId

export const registerDialogIntent = (
  db: Db,
  peer: InputPeer,
  intentId: DialogIntentId,
  fields: readonly DialogIntentField[],
) => {
  const intents = intentsFor(db)
  const identity = peerIdentity(peer)
  const fieldIntents = intents.get(identity) ?? new Map()
  for (const field of fields) fieldIntents.set(field, intentId)
  intents.set(identity, fieldIntents)
}

export const snapshotDialogIntent = (
  dialog: Dialog,
  fields: readonly DialogIntentField[],
): DialogIntentSnapshot =>
  Object.fromEntries(fields.map((field) => [field, dialog[field]]))

export const hasOtherDialogIntent = (
  db: Db,
  peer: InputPeer,
  intentId: DialogIntentId,
) => {
  const fields = intentsFor(db).get(peerIdentity(peer))
  return fields != null && Array.from(fields.values()).some((id) => id !== intentId)
}

const completeFields = (
  db: Db,
  peer: InputPeer,
  intentId: DialogIntentId,
  fields: readonly DialogIntentField[],
) => {
  const intents = intentsFor(db)
  const identity = peerIdentity(peer)
  const fieldIntents = intents.get(identity)
  if (!fieldIntents) return
  for (const field of fields) {
    if (fieldIntents.get(field) === intentId) fieldIntents.delete(field)
  }
  if (fieldIntents.size === 0) intents.delete(identity)
}

/** Applies a full server dialog without erasing another pending optimistic intent. */
export const applyDialogIntentResult = (
  db: Db,
  peer: InputPeer,
  intentId: DialogIntentId,
  fields: readonly DialogIntentField[],
  apply: () => void,
) => {
  const before = dialogForPeer(db, peer)
  apply()
  const after = dialogForPeer(db, peer)
  const fieldIntents = intentsFor(db).get(peerIdentity(peer))
  if (before && after && fieldIntents) {
    const protectedState: DialogIntentSnapshot = {}
    for (const [field, owner] of fieldIntents) {
      if (owner !== intentId) {
        Object.assign(protectedState, { [field]: before[field] })
      }
    }
    if (Object.keys(protectedState).length > 0) {
      db.replace({ ...after, ...protectedState })
    }
  }
  completeFields(db, peer, intentId, fields)
}

/** Rolls back only fields still showing this exact optimistic recipe. */
export const failDialogIntent = (
  db: Db,
  peer: InputPeer,
  intentId: DialogIntentId,
  fields: readonly DialogIntentField[],
  previous: DialogIntentSnapshot | null | undefined,
  optimistic: DialogIntentSnapshot | undefined,
) => {
  const dialog = dialogForPeer(db, peer)
  const fieldIntents = intentsFor(db).get(peerIdentity(peer))
  if (!dialog || !fieldIntents || previous == null || !optimistic) {
    completeFields(db, peer, intentId, fields)
    return
  }
  const rollback: DialogIntentSnapshot = {}
  for (const field of fields) {
    if (
      fieldIntents.get(field) === intentId &&
      dialog[field] === optimistic[field]
    ) {
      Object.assign(rollback, { [field]: previous[field] })
    }
  }
  if (Object.keys(rollback).length > 0) {
    db.replace({ ...dialog, ...rollback })
  }
  completeFields(db, peer, intentId, fields)
}
