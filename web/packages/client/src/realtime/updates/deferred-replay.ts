import { Update, UserGroup } from "@inline-chat/protocol/core"
import type { Db } from "../../database"
import { DbObjectKind, type DeferredUpdate } from "../../database/models"
import { DbQueryPlanType } from "../../database/types"
import { applyUpdates, deferredUpdateRecord } from "./apply-updates"
import { putUserGroup } from "./membership"

/**
 * Update kinds that were stored raw before schema version 4 and are now
 * projected into models. A replica that still holds raw rows of these kinds
 * replays them once, oldest first, into the new models
 * (`replayProjectedDeferredUpdates`).
 */
export const PROJECTED_DEFERRED_UPDATE_TYPES = [
  "joinSpace",
  "spaceMemberAdd",
  "spaceMemberUpdate",
  "spaceMemberDelete",
  "participantAdd",
  "participantDelete",
  "participantGroupAdd",
  "participantGroupDelete",
  "userAddedToChat",
  "userRemovedFromChat",
  "dialogNotificationSettings",
  "dialogTranslation",
  "dialogFolder",
  "unreadActivity",
  "updateUserSettings",
  "spaceSettings",
  "spaceProfile",
  "sidecarUserGroup",
] as const

export type DeferredReplayReport = { applied: number; retained: number }

const compareRows = (left: DeferredUpdate, right: DeferredUpdate) => {
  const leftDate = left.date ?? 0
  const rightDate = right.date ?? 0
  if (leftDate !== rightDate) return leftDate - rightDate
  if (left.bucketId === right.bucketId) {
    const order = (left.seq ?? 0) - (right.seq ?? 0)
    if (order !== 0) return order
  }
  return left.id < right.id ? -1 : left.id > right.id ? 1 : 0
}

/**
 * Replay raw rows of newly projected kinds into their models (invariant 7:
 * they were kept for exactly this). Each row commits on its own, so one that
 * fails to apply rolls back alone and stays stored; a payload that does not
 * decode stays stored too. A row whose update the projection still keeps
 * raw (a malformed payload) is kept under its original identity.
 *
 * Rows are applied in event order: by date, then by sequence within a bucket.
 */
export const replayProjectedDeferredUpdates = async (
  db: Db,
  types: readonly string[] = PROJECTED_DEFERRED_UPDATE_TYPES,
): Promise<DeferredReplayReport> => {
  const wanted = new Set(types)
  await db.hydrateDeferredUpdatesByTypes([...wanted])
  const rows = db
    .queryCollection(
      DbQueryPlanType.Objects,
      DbObjectKind.DeferredUpdate,
      (row) => wanted.has(row.updateType),
    )
    .sort(compareRows)
  const report: DeferredReplayReport = { applied: 0, retained: 0 }

  for (const row of rows) {
    if (row.payloadType === "UserGroup") {
      let group: UserGroup
      try {
        group = UserGroup.fromBinary(row.payload)
      } catch {
        report.retained += 1
        continue
      }
      try {
        await db.commit(() => {
          putUserGroup(db, group)
          db.delete(db.ref(DbObjectKind.DeferredUpdate, row.id))
        })
        report.applied += 1
      } catch {
        report.retained += 1
      }
      continue
    }

    let update: Update
    try {
      update = Update.fromBinary(row.payload)
    } catch {
      report.retained += 1
      continue
    }
    if (update.update.oneofKind !== row.updateType) {
      report.retained += 1
      continue
    }
    let kept = false
    try {
      await db.commit(() => {
        const result = applyUpdates(db, [update], "syncCatchup")
        if (result.deferred > 0) {
          // Still raw: keep the original row, not a second copy.
          kept = true
          const copy = deferredUpdateRecord(update).id
          if (copy !== row.id) {
            db.delete(db.ref(DbObjectKind.DeferredUpdate, copy))
          }
          return
        }
        db.delete(db.ref(DbObjectKind.DeferredUpdate, row.id))
      })
    } catch {
      kept = true
    }
    if (kept) report.retained += 1
    else report.applied += 1
  }
  return report
}
