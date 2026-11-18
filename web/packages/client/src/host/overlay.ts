/**
 * Display overlays for intents that are not safe to replay (edit, delete).
 *
 * The replica keeps the confirmed state; this keeps the intents in flight on
 * top of it, in memory, in the order they were made. A query reads messages
 * through `OverlayView`, so what a UI sees is recomputed from the confirmed
 * base and the open intents every time either changes. Settling an intent
 * removes it and the display is recomputed: nothing is ever "undone"
 * (invariant 4).
 *
 * - An edit replaces the text and entities; the newest open edit wins. When
 *   the oldest edit confirms, the base already carries its text and the next
 *   one still shows; when an edit fails, the display falls back to the newest
 *   remaining edit or to the base.
 * - A delete hides the message until it settles. A confirmed delete removes
 *   the row from the replica first (the server's update commits before the
 *   result resolves), so the row never reappears; a failed or uncertain one
 *   shows the base again.
 *
 * Overlays are session state: they are not persisted and do not survive a
 * restart, like the intents themselves (they are not replay-safe).
 */
import type { MessageEntities } from "@inline-chat/protocol/core"
import type { TxId } from "@inline/core-protocol"
import { DbObjectKind, type DbModels, type Message } from "../database/models"
import type { ReplicaView, ViewKind } from "../queries/view"

export type PendingEdit = {
  tx: TxId
  text: string
  entities?: MessageEntities
  /** Seconds since the epoch: the optimistic edit date. */
  date: number
}

export class PendingOverlay {
  private readonly edits = new Map<string, PendingEdit[]>()
  private readonly hidden = new Map<string, Set<TxId>>()

  get size() {
    return this.edits.size + this.hidden.size
  }

  addEdit(key: string, edit: PendingEdit) {
    const list = this.edits.get(key) ?? []
    list.push(edit)
    this.edits.set(key, list)
  }

  removeEdit(key: string, tx: TxId) {
    const list = this.edits.get(key)
    if (!list) return
    const next = list.filter((edit) => edit.tx !== tx)
    if (next.length > 0) this.edits.set(key, next)
    else this.edits.delete(key)
  }

  /** Open edits of a message, oldest first. */
  editsOf(key: string): readonly PendingEdit[] {
    return this.edits.get(key) ?? []
  }

  hide(key: string, tx: TxId) {
    const holders = this.hidden.get(key) ?? new Set()
    holders.add(tx)
    this.hidden.set(key, holders)
  }

  unhide(key: string, tx: TxId) {
    const holders = this.hidden.get(key)
    if (!holders) return
    holders.delete(tx)
    if (holders.size === 0) this.hidden.delete(key)
  }

  isHidden(key: string) {
    return this.hidden.has(key)
  }

  /** The message as displayed: undefined when hidden, else with the newest open edit. */
  apply(message: Message): Message | undefined {
    if (this.hidden.has(message.id)) return undefined
    const edit = this.edits.get(message.id)?.at(-1)
    if (!edit) return message
    const { entities: _entities, ...rest } = message
    return {
      ...rest,
      message: edit.text,
      ...(edit.entities ? { entities: edit.entities } : {}),
      editDate: edit.date,
    }
  }

  clear() {
    this.edits.clear()
    this.hidden.clear()
  }
}

/** The committed view with the overlay applied to messages. */
export class OverlayView implements ReplicaView {
  constructor(
    private readonly base: ReplicaView,
    private readonly overlay: PendingOverlay,
  ) {}

  get<K extends ViewKind>(kind: K, id: string): DbModels[K] | undefined {
    const value = this.base.get(kind, id)
    if (kind !== DbObjectKind.Message || value == null || this.overlay.size === 0) return value
    return this.overlay.apply(value as Message) as DbModels[K] | undefined
  }

  all<K extends ViewKind>(kind: K): DbModels[K][] {
    const values = this.base.all(kind)
    if (kind !== DbObjectKind.Message || this.overlay.size === 0) return values
    return values.flatMap((value) => {
      const shown = this.overlay.apply(value as Message)
      return shown ? [shown as DbModels[K]] : []
    })
  }
}
