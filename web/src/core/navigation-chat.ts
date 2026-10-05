import { DbObjectKind, GetChatTransaction, type Db } from "@inline/client/core"
import type { RpcResult } from "@inline-chat/protocol/core"
import { spaceId, type ChatID, type SpaceID } from "@inline/ids"

/** A route fetch must not restore a chat removed while its response was in flight. */
export class NavigationChat extends GetChatTransaction {
  discarded = false
  private changed = false
  private changedSpaces = new Set<SpaceID>()
  private detach?: () => void

  constructor(
    context: GetChatTransaction["context"],
    private readonly chatId: ChatID,
    private readonly current: () => boolean
  ) {
    super(context)
  }

  beforeExecute(db: Db) {
    this.dispose()
    this.changed = false
    this.changedSpaces.clear()
    this.detach = db.subscribeToResidentChanges((batch) => {
      for (const change of batch.changes) {
        if (change.kind === DbObjectKind.Space) this.changedSpaces.add(spaceId(change.id))
      }
      if (
        batch.changes.some(
          (change) => change.kind === DbObjectKind.Chat && change.id === this.chatId
        )
      )
        this.changed = true
    })
  }

  override apply(result: RpcResult["result"] | undefined, db: Db) {
    const resultSpace = result?.oneofKind === "getChat" ? result.getChat.chat?.spaceId : undefined
    // Older child-chat encoders omit inherited spaceId. If the owning scope is
    // unknown, a fresh route request must resolve access after any Space change.
    const unscopedChild =
      result?.oneofKind === "getChat" &&
      result.getChat.chat?.parentChatId != null &&
      resultSpace == null
    if (
      !this.current() ||
      this.changed ||
      (resultSpace != null && this.changedSpaces.has(spaceId(resultSpace))) ||
      (unscopedChild && this.changedSpaces.size > 0)
    ) {
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
