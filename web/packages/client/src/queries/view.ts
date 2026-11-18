/**
 * The committed view the materializer reads. It is built only from
 * `Db.residentSnapshot()` and the batches of `Db.subscribeToResidentChanges`,
 * which `Db` delivers after their storage transaction commits, carrying the
 * committed values. Live memory can be ahead of it (an accepted write that has
 * not committed yet); this view never is, so a patch built from it never shows
 * a row that is not on disk (invariant 1).
 */
import type { DbResidentChangeBatch, DbResidentSnapshot } from "../database"
import { DbObjectKind, type DbModel, type DbModels } from "../database/models"

export const VIEW_KINDS = [
  DbObjectKind.User,
  DbObjectKind.Space,
  DbObjectKind.Chat,
  DbObjectKind.Dialog,
  DbObjectKind.Message,
  DbObjectKind.MessageDraft,
  DbObjectKind.HistoryCoverage,
  DbObjectKind.SpaceMember,
  DbObjectKind.ChatParticipant,
  DbObjectKind.ChatParticipantGroup,
  DbObjectKind.UserGroup,
  DbObjectKind.DialogFolder,
  DbObjectKind.UserSettings,
] as const

export type ViewKind = (typeof VIEW_KINDS)[number]

const viewKinds = new Set<DbObjectKind>(VIEW_KINDS)

export interface ReplicaView {
  get<K extends ViewKind>(kind: K, id: string): DbModels[K] | undefined
  all<K extends ViewKind>(kind: K): DbModels[K][]
}

export class CommittedView implements ReplicaView {
  private readonly byKind = new Map<DbObjectKind, Map<string, DbModel>>(
    VIEW_KINDS.map((kind) => [kind, new Map()]),
  )
  revision = 0

  /** Replace the view with a snapshot; later batches at or below its revision are skipped. */
  load(snapshot: DbResidentSnapshot) {
    for (const objects of this.byKind.values()) objects.clear()
    for (const object of snapshot.objects) {
      this.byKind.get(object.kind)?.set(String(object.id), object)
    }
    this.revision = snapshot.revision
  }

  /** Apply a committed batch. Repeated values are harmless. */
  apply(batch: DbResidentChangeBatch) {
    if (batch.revision <= this.revision) return
    this.revision = batch.revision
    for (const change of batch.changes) {
      if (!viewKinds.has(change.kind)) continue
      const objects = this.byKind.get(change.kind)!
      if (change.object) objects.set(String(change.id), change.object)
      else objects.delete(String(change.id))
    }
  }

  get<K extends ViewKind>(kind: K, id: string): DbModels[K] | undefined {
    return this.byKind.get(kind)?.get(id) as DbModels[K] | undefined
  }

  all<K extends ViewKind>(kind: K): DbModels[K][] {
    return Array.from(this.byKind.get(kind)?.values() ?? []) as DbModels[K][]
  }
}
