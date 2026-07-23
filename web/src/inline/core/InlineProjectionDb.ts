import {
  Db,
  DbQueryPlanType,
  type DbModel,
  type DbResidentChange,
  type MessageKey,
  type LocalMessageWindowAroundOptions,
  type MessageWindowOptions,
} from "@inline/client/core"
import type { ChatID } from "@inline/ids"
import {
  INLINE_CORE_RENDERER_KINDS,
  type InlineCoreProjection,
  type InlineCoreProjectionChanges,
} from "./InlineCoreProtocol"

export type InlineProjectionDbOptions = {
  hydrateMessageWindow: (
    chatId: ChatID,
    options: MessageWindowOptions,
  ) => Promise<number>
  loadLocalWindowAroundMessage: (
    chatId: ChatID,
    options: LocalMessageWindowAroundOptions,
  ) => Promise<boolean>
  requestResync: () => void
}

/**
 * Read projection used by renderer views. It never opens account persistence;
 * ordered snapshots/patches come from the sole core owner.
 */
export class InlineProjectionDb extends Db {
  private projectionRevision = 0
  private messageWindowKeys = new Set<MessageKey>()
  private readonly remoteHydrateMessageWindow: (
    chatId: ChatID,
    options: MessageWindowOptions,
  ) => Promise<number>
  private readonly remoteLoadLocalWindowAroundMessage: (
    chatId: ChatID,
    options: LocalMessageWindowAroundOptions,
  ) => Promise<boolean>
  private readonly requestResync: () => void

  constructor(options: InlineProjectionDbOptions) {
    super({
      autoHydrate: false,
      persistence: false,
    })
    this.remoteHydrateMessageWindow =
      options.hydrateMessageWindow
    this.remoteLoadLocalWindowAroundMessage =
      options.loadLocalWindowAroundMessage
    this.requestResync = options.requestResync
  }

  override hydrateMessageWindow(
    chatId: ChatID,
    options: MessageWindowOptions,
  ) {
    return this.remoteHydrateMessageWindow(chatId, options)
  }

  override loadLocalWindowAroundMessage(
    chatId: ChatID,
    options: LocalMessageWindowAroundOptions,
  ) {
    return this.remoteLoadLocalWindowAroundMessage(
      chatId,
      options,
    )
  }

  override isMessageInHistoryWindow(
    _chatId: ChatID,
    key: MessageKey,
  ) {
    return this.messageWindowKeys.has(key)
  }

  applyProjection(projection: InlineCoreProjection) {
    this.messageWindowKeys = new Set(
      projection.messageWindowKeys,
    )
    this.batch(() => {
      for (const kind of INLINE_CORE_RENDERER_KINDS) {
        const current = this.queryCollection(
          DbQueryPlanType.Objects,
          kind,
        )
        for (const object of current) {
          this.deleteObject(object)
        }
      }
      for (const object of projection.objects) {
        if (
          INLINE_CORE_RENDERER_KINDS.includes(
            object.kind as never,
          )
        ) {
          this.replaceObject(object)
        }
      }
    })
    this.projectionRevision = projection.revision
  }

  applyChanges(batch: InlineCoreProjectionChanges) {
    if (batch.revision <= this.projectionRevision) return true
    if (batch.revision !== this.projectionRevision + 1) {
      this.requestResync()
      return false
    }

    this.messageWindowKeys = new Set(batch.messageWindowKeys)
    this.batch(() => {
      for (const change of batch.changes) {
        this.applyChange(change)
      }
    })
    this.projectionRevision = batch.revision
    return true
  }

  getProjectionRevision() {
    return this.projectionRevision
  }

  private applyChange(change: DbResidentChange) {
    if (
      !INLINE_CORE_RENDERER_KINDS.includes(
        change.kind as never,
      )
    ) {
      return
    }
    if (change.object) {
      this.replaceObject(change.object)
      return
    }
    this.delete(
      this.ref(change.kind, change.id as never),
    )
  }

  private replaceObject(object: DbModel) {
    this.replace(object)
  }

  private deleteObject(object: DbModel) {
    this.delete(this.ref(object.kind, object.id as never))
  }
}
