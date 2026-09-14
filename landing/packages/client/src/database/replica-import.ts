import {
  DbObjectKind,
  type DbModel,
} from "./models"
import type { InlinePersistenceStore } from "./persistence"

export const INLINE_INDEXED_DB_IMPORT_MARKER =
  "legacy-indexeddb-v6-to-sqlite-v1"
export const INLINE_SQLITE_AUTHORITY_MARKER =
  "sqlite-authoritative-v1"

/**
 * Cursors are copied last. A partially imported SQLite file is never selected,
 * but this order also keeps an interrupted file conservative when inspected.
 */
export const INLINE_REPLICA_IMPORT_KINDS = [
  DbObjectKind.User,
  DbObjectKind.Space,
  DbObjectKind.Chat,
  DbObjectKind.Dialog,
  DbObjectKind.Message,
  DbObjectKind.DeferredUpdate,
  DbObjectKind.PendingTransaction,
  DbObjectKind.ReservedChatID,
  DbObjectKind.MessageDraft,
  DbObjectKind.SyncBucketState,
  DbObjectKind.SyncGlobalState,
] as const

export type InlineReplicaImportProgress = {
  kind: DbObjectKind
  importedForKind: number
  importedTotal: number
}

export type InlineReplicaImportResult = {
  status: "imported" | "already-imported"
  importedTotal: number
  importedByKind: Partial<Record<DbObjectKind, number>>
}

export class InlineReplicaImportError extends Error {
  constructor(message: string, options?: ErrorOptions) {
    super(message, options)
    this.name = "InlineReplicaImportError"
  }
}

export class InlinePersistenceReplicaPromotedError extends Error {
  constructor() {
    super(
      "Inline IndexedDB fallback is stale because SQLite is authoritative",
    )
    this.name = "InlinePersistenceReplicaPromotedError"
  }
}

type InlineReplicaMetadataStore = InlinePersistenceStore & Required<
  Pick<
    InlinePersistenceStore,
    "getReplicaMetadata" | "setReplicaMetadata"
  >
>

const requireReplicaMetadata: (
  store: InlinePersistenceStore,
) => asserts store is InlineReplicaMetadataStore = (store) => {
  if (!store.getReplicaMetadata || !store.setReplicaMetadata) {
    throw new InlineReplicaImportError(
      "Inline replica store does not support cutover metadata",
    )
  }
}

export const assertInlineLegacyFallbackAllowed = async (
  store: InlinePersistenceStore,
): Promise<void> => {
  requireReplicaMetadata(store)
  if (
    await store.getReplicaMetadata(
      INLINE_SQLITE_AUTHORITY_MARKER,
    ) === "complete"
  ) {
    throw new InlinePersistenceReplicaPromotedError()
  }
}

export const importIndexedDbReplicaIntoSqlite = async (options: {
  source: InlinePersistenceStore
  target: InlineReplicaMetadataStore
  batchSize?: number
  onProgress?: (progress: InlineReplicaImportProgress) => void
}): Promise<InlineReplicaImportResult> => {
  const batchSize = options.batchSize ?? 500
  if (!Number.isSafeInteger(batchSize) || batchSize <= 0) {
    throw new InlineReplicaImportError(
      `Invalid Inline replica import batch size ${batchSize}`,
    )
  }
  if (!options.source.scan) {
    throw new InlineReplicaImportError(
      "Inline replica import source does not support bounded scans",
    )
  }
  requireReplicaMetadata(options.source)

  await options.target.open()
  if (
    await options.target.getReplicaMetadata(
      INLINE_INDEXED_DB_IMPORT_MARKER,
    ) === "complete"
  ) {
    await options.source.open()
    try {
      // Backfill the authority fence for stores imported before the fence was
      // introduced, and repair it if browser data was partially restored.
      await options.source.setReplicaMetadata(
        INLINE_SQLITE_AUTHORITY_MARKER,
        "complete",
      )
      return {
        status: "already-imported",
        importedTotal: 0,
        importedByKind: {},
      }
    } finally {
      await options.source.close()
    }
  }

  const importedByKind: Partial<Record<DbObjectKind, number>> = {}
  let importedTotal = 0
  await options.source.open()
  try {
    for (const kind of INLINE_REPLICA_IMPORT_KINDS) {
      let afterId: DbModel["id"] | undefined
      let done = false
      let importedForKind = 0
      while (!done) {
        const page = await options.source.scan(
          kind,
          afterId as never,
          batchSize,
        )
        if (page.objects.length > batchSize) {
          throw new InlineReplicaImportError(
            `Inline ${kind} import page exceeded its batch size`,
          )
        }
        if (!page.done && page.nextId === undefined) {
          throw new InlineReplicaImportError(
            `Inline ${kind} import page omitted its continuation`,
          )
        }
        if (page.objects.length === 0 && !page.done) {
          throw new InlineReplicaImportError(
            `Inline ${kind} import made no progress`,
          )
        }

        if (page.objects.length > 0) {
          await options.target.write(
            page.objects.map((object) => ({
              type: "put" as const,
              object,
            })),
          )
          importedForKind += page.objects.length
          importedTotal += page.objects.length
          importedByKind[kind] = importedForKind
          options.onProgress?.({
            kind,
            importedForKind,
            importedTotal,
          })
        }
        afterId = page.nextId
        done = page.done
      }
    }

    // Fence the old replica first. A crash between these writes may replay the
    // idempotent import, but can never expose stale IndexedDB as a fallback.
    await options.source.setReplicaMetadata(
      INLINE_SQLITE_AUTHORITY_MARKER,
      "complete",
    )
    await options.target.setReplicaMetadata(
      INLINE_INDEXED_DB_IMPORT_MARKER,
      "complete",
    )
    return { status: "imported", importedTotal, importedByKind }
  } catch (cause) {
    throw cause instanceof InlineReplicaImportError
      ? cause
      : new InlineReplicaImportError(
          "Inline IndexedDB replica import failed",
          { cause },
        )
  } finally {
    await options.source.close()
  }
}
