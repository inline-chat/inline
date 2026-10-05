import {
  DbObjectKind,
  GetChatsTransaction,
  type Db,
} from "@inline/client/core"
import type { RpcResult } from "@inline-chat/protocol/core"

const navigationKinds = new Set([
  DbObjectKind.User,
  DbObjectKind.Space,
  DbObjectKind.Chat,
  DbObjectKind.Dialog,
  DbObjectKind.Message,
])

/** getChats has no snapshot watermark; never overwrite changes made in flight. */
export class NavigationRefresh extends GetChatsTransaction {
  discarded = false
  private changed = false
  private detach?: () => void

  constructor(private readonly current: () => boolean) { super() }

  beforeExecute(db: Db) {
    this.dispose()
    this.changed = false
    this.detach = db.subscribeToResidentChanges((batch) => {
      if (batch.changes.some((change) => navigationKinds.has(change.kind))) this.changed = true
    })
  }

  override apply(result: RpcResult["result"] | undefined, db: Db) {
    if (!this.current() || this.changed) {
      this.discarded = true
      return
    }
    super.apply(result, db)
  }

  dispose() {
    this.detach?.()
    this.detach = undefined
  }
}
