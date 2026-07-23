import type { ChatID, MessageID } from "@inline/ids"
import {
  DbObjectKind,
  type DbModels,
} from "./models"
import type { MessageWindowCursor } from "./message-window"
import type {
  InlinePersistenceCollection,
  InlinePersistenceOperation,
  InlinePersistenceStore,
} from "./persistence"

export type InlinePersistenceSelectionSnapshot =
  | { phase: "idle" }
  | { phase: "opening-primary" }
  | { phase: "primary" }
  | { phase: "opening-fallback"; primaryError: unknown }
  | { phase: "fallback"; primaryError: unknown }
  | { phase: "failed"; error: unknown }

export type InlineStartupPersistenceOptions = {
  primary: () => InlinePersistenceStore
  preparePrimary?: (primary: InlinePersistenceStore) => Promise<void>
  fallback: () => InlinePersistenceStore | null
  prepareFallback?: (fallback: InlinePersistenceStore) => Promise<void>
  canFallback: (error: unknown) => boolean
}

export class InlinePersistencePrimaryCleanupError extends Error {
  constructor(
    readonly primaryError: unknown,
    readonly cleanupError: unknown,
  ) {
    super(
      "Inline persistence primary failed to open and could not close cleanly",
      { cause: cleanupError },
    )
    this.name = "InlinePersistencePrimaryCleanupError"
  }
}

export class InlinePersistenceFallbackUnavailableError extends Error {
  constructor(readonly primaryError: unknown) {
    super(
      "Inline persistence fallback is unavailable",
      { cause: primaryError },
    )
    this.name = "InlinePersistenceFallbackUnavailableError"
  }
}

export class InlinePersistenceFallbackOpenError extends Error {
  constructor(
    readonly primaryError: unknown,
    readonly fallbackError: unknown,
  ) {
    super(
      "Inline persistence primary and fallback both failed to open",
      { cause: fallbackError },
    )
    this.name = "InlinePersistenceFallbackOpenError"
  }
}

export class InlinePersistenceCapabilityError extends Error {
  constructor(capability: string, kind: DbObjectKind) {
    super(
      `Inline persistence ${kind} collection does not implement ${capability}`,
    )
    this.name = "InlinePersistenceCapabilityError"
  }
}

class InlineStartupPersistenceCollection<K extends DbObjectKind>
  implements InlinePersistenceCollection<DbModels[K]>
{
  constructor(
    private readonly store: InlineStartupPersistenceStore,
    private readonly kind: K,
  ) {}

  private async collection() {
    const store = await this.store.selectedStore()
    return store.collection(this.kind)
  }

  async init() {
    await (await this.collection()).init()
  }

  async get(id: DbModels[K]["id"]) {
    return (await this.collection()).get(id)
  }

  async getMany(ids: DbModels[K]["id"][]) {
    const collection = await this.collection()
    if (collection.getMany) return collection.getMany(ids)
    const objects: DbModels[K][] = []
    for (const id of ids) {
      const object = await collection.get(id)
      if (object !== undefined) objects.push(object)
    }
    return objects
  }

  async getAll() {
    return (await this.collection()).getAll()
  }

  async getDeferredUpdatesByTargetKeys(targetKeys: string[]) {
    const collection = await this.collection()
    if (!collection.getDeferredUpdatesByTargetKeys) {
      throw new InlinePersistenceCapabilityError(
        "getDeferredUpdatesByTargetKeys",
        this.kind,
      )
    }
    return collection.getDeferredUpdatesByTargetKeys(targetKeys)
  }

  async getMessageWindowByChatId(
    chatId: ChatID,
    limit: number,
    before?: MessageWindowCursor,
    after?: MessageWindowCursor,
  ) {
    const collection = await this.collection()
    if (!collection.getMessageWindowByChatId) {
      throw new InlinePersistenceCapabilityError(
        "getMessageWindowByChatId",
        this.kind,
      )
    }
    return collection.getMessageWindowByChatId(
      chatId,
      limit,
      before,
      after,
    )
  }

  async getMessageWindowAroundMessageId(
    chatId: ChatID,
    messageId: MessageID,
    beforeLimit: number,
    afterLimit: number,
  ) {
    const collection = await this.collection()
    if (!collection.getMessageWindowAroundMessageId) {
      throw new InlinePersistenceCapabilityError(
        "getMessageWindowAroundMessageId",
        this.kind,
      )
    }
    return collection.getMessageWindowAroundMessageId(
      chatId,
      messageId,
      beforeLimit,
      afterLimit,
    )
  }

  async deleteAllByChatId(chatId: ChatID) {
    const collection = await this.collection()
    if (!collection.deleteAllByChatId) {
      throw new InlinePersistenceCapabilityError(
        "deleteAllByChatId",
        this.kind,
      )
    }
    await collection.deleteAllByChatId(chatId)
  }

  async put(object: DbModels[K]) {
    await (await this.collection()).put(object)
  }

  async delete(id: DbModels[K]["id"]) {
    await (await this.collection()).delete(id)
  }
}

/**
 * Selects one account replica at startup and never switches it after open.
 *
 * The classifier must accept only errors which prove that the primary never
 * became usable. A later read/write error is always returned from the already
 * selected store; it can never redirect the account to a divergent replica.
 */
export class InlineStartupPersistenceStore
  implements InlinePersistenceStore
{
  private selectionPromise: Promise<InlinePersistenceStore> | null = null
  private readonly collections = new Map<
    DbObjectKind,
    InlinePersistenceCollection<any>
  >()
  private snapshot: InlinePersistenceSelectionSnapshot = {
    phase: "idle",
  }

  constructor(private readonly options: InlineStartupPersistenceOptions) {}

  getSelectionSnapshot(): InlinePersistenceSelectionSnapshot {
    return this.snapshot
  }

  async open(): Promise<void> {
    await this.selectedStore()
  }

  collection<K extends DbObjectKind>(kind: K) {
    let collection = this.collections.get(kind)
    if (!collection) {
      collection = new InlineStartupPersistenceCollection(this, kind)
      this.collections.set(kind, collection)
    }
    return collection as InlinePersistenceCollection<DbModels[K]>
  }

  async write(operations: readonly InlinePersistenceOperation[]) {
    await (await this.selectedStore()).write(operations)
  }

  async close() {
    const selection = this.selectionPromise
    this.selectionPromise = null
    if (selection) {
      const store = await selection.catch(() => undefined)
      await store?.close()
    }
    this.snapshot = { phase: "idle" }
  }

  selectedStore(): Promise<InlinePersistenceStore> {
    if (!this.selectionPromise) {
      this.selectionPromise = this.selectStore()
    }
    return this.selectionPromise
  }

  private async selectStore(): Promise<InlinePersistenceStore> {
    const primary = this.options.primary()
    let primaryOpened = false
    this.snapshot = { phase: "opening-primary" }
    try {
      await primary.open()
      primaryOpened = true
      await this.options.preparePrimary?.(primary)
      this.snapshot = { phase: "primary" }
      return primary
    } catch (primaryError) {
      try {
        await primary.close()
      } catch (cleanupError) {
        const error = new InlinePersistencePrimaryCleanupError(
          primaryError,
          cleanupError,
        )
        this.snapshot = { phase: "failed", error }
        throw error
      }

      if (
        primaryOpened ||
        !this.options.canFallback(primaryError)
      ) {
        this.snapshot = { phase: "failed", error: primaryError }
        throw primaryError
      }

      this.snapshot = {
        phase: "opening-fallback",
        primaryError,
      }
      const fallback = this.options.fallback()
      if (!fallback) {
        const error = new InlinePersistenceFallbackUnavailableError(
          primaryError,
        )
        this.snapshot = { phase: "failed", error }
        throw error
      }
      try {
        await fallback.open()
        await this.options.prepareFallback?.(fallback)
        this.snapshot = { phase: "fallback", primaryError }
        return fallback
      } catch (fallbackError) {
        await fallback.close().catch(() => undefined)
        const error = new InlinePersistenceFallbackOpenError(
          primaryError,
          fallbackError,
        )
        this.snapshot = { phase: "failed", error }
        throw error
      }
    }
  }
}
