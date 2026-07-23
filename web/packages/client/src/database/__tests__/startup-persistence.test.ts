import { userId } from "@inline/ids"
import { describe, expect, it, vi } from "vitest"
import {
  InlinePersistenceFallbackOpenError,
  InlinePersistenceFallbackUnavailableError,
  InlinePersistencePrimaryCleanupError,
  InlineStartupPersistenceStore,
} from "../InlineStartupPersistenceStore"
import {
  DbObjectKind,
  type DbModels,
} from "../models"
import type {
  InlinePersistenceCollection,
  InlinePersistenceStore,
} from "../persistence"
import {
  InlineSqliteUnavailableError,
  isInlineSqliteStartupFallbackSafe,
} from "../sqlite/openers"

const user = {
  kind: DbObjectKind.User,
  id: userId(7),
  firstName: "Dena",
} as const

const createStore = (options: {
  open?: () => Promise<void>
  close?: () => Promise<void>
  write?: InlinePersistenceStore["write"]
  storedUser?: DbModels[DbObjectKind.User]
}) => {
  const open = vi.fn(options.open ?? (async () => {}))
  const close = vi.fn(options.close ?? (async () => {}))
  const write = vi.fn(options.write ?? (async () => {}))
  const collection: InlinePersistenceCollection<
    DbModels[DbObjectKind.User]
  > = {
    init: async () => {},
    get: async (id) =>
      id === options.storedUser?.id
        ? options.storedUser
        : undefined,
    getMany: async (ids) =>
      ids.includes(options.storedUser?.id ?? userId(-1)) &&
      options.storedUser
        ? [options.storedUser]
        : [],
    getAll: async () => options.storedUser ? [options.storedUser] : [],
    put: async () => {},
    delete: async () => {},
  }
  const store: InlinePersistenceStore = {
    open,
    close,
    write,
    collection: <K extends DbObjectKind>() =>
      collection as unknown as InlinePersistenceCollection<DbModels[K]>,
  }
  return { store, open, close, write }
}

describe("InlineStartupPersistenceStore", () => {
  it("selects the fallback once for a classified startup capability failure", async () => {
    const primaryError = new InlineSqliteUnavailableError(
      "opfs-unsupported",
    )
    const primary = createStore({
      open: async () => {
        throw primaryError
      },
    })
    const fallback = createStore({ storedUser: user })
    const fallbackFactory = vi.fn(() => fallback.store)
    const store = new InlineStartupPersistenceStore({
      primary: () => primary.store,
      fallback: fallbackFactory,
      canFallback: isInlineSqliteStartupFallbackSafe,
    })

    await Promise.all([
      store.open(),
      store.collection(DbObjectKind.User).init(),
    ])
    await expect(
      store.collection(DbObjectKind.User).get(user.id),
    ).resolves.toEqual(user)
    await store.write([{ type: "put", object: user }])

    expect(primary.open).toHaveBeenCalledTimes(1)
    expect(primary.close).toHaveBeenCalledTimes(1)
    expect(fallbackFactory).toHaveBeenCalledTimes(1)
    expect(fallback.open).toHaveBeenCalledTimes(1)
    expect(fallback.write).toHaveBeenCalledTimes(1)
    expect(store.getSelectionSnapshot()).toEqual({
      phase: "fallback",
      primaryError,
    })
  })

  it("fails closed for migration, corruption, and unknown startup errors", async () => {
    const primaryError = new Error("migration failed")
    const primary = createStore({
      open: async () => {
        throw primaryError
      },
    })
    const fallbackFactory = vi.fn(() => createStore({}).store)
    const store = new InlineStartupPersistenceStore({
      primary: () => primary.store,
      fallback: fallbackFactory,
      canFallback: isInlineSqliteStartupFallbackSafe,
    })

    await expect(store.open()).rejects.toBe(primaryError)
    expect(primary.close).toHaveBeenCalledOnce()
    expect(fallbackFactory).not.toHaveBeenCalled()
    expect(store.getSelectionSnapshot()).toEqual({
      phase: "failed",
      error: primaryError,
    })
  })

  it("never switches replicas after the primary has opened", async () => {
    const writeError = new InlineSqliteUnavailableError(
      "opfs-permission-denied",
    )
    const primary = createStore({
      write: async () => {
        throw writeError
      },
    })
    const fallbackFactory = vi.fn(() => createStore({}).store)
    const store = new InlineStartupPersistenceStore({
      primary: () => primary.store,
      fallback: fallbackFactory,
      canFallback: isInlineSqliteStartupFallbackSafe,
    })

    await store.open()
    await expect(
      store.write([{ type: "put", object: user }]),
    ).rejects.toBe(writeError)
    expect(fallbackFactory).not.toHaveBeenCalled()
    expect(store.getSelectionSnapshot()).toEqual({ phase: "primary" })
  })

  it("fails closed when replica preparation fails after primary open", async () => {
    const preparationError = new InlineSqliteUnavailableError(
      "opfs-permission-denied",
    )
    const primary = createStore({})
    const fallbackFactory = vi.fn(() => createStore({}).store)
    const store = new InlineStartupPersistenceStore({
      primary: () => primary.store,
      preparePrimary: async () => {
        throw preparationError
      },
      fallback: fallbackFactory,
      canFallback: isInlineSqliteStartupFallbackSafe,
    })

    await expect(store.open()).rejects.toBe(preparationError)
    expect(primary.close).toHaveBeenCalledOnce()
    expect(fallbackFactory).not.toHaveBeenCalled()
  })

  it("refuses fallback when the failed primary cannot close", async () => {
    const primaryError = new InlineSqliteUnavailableError(
      "opfs-permission-denied",
    )
    const cleanupError = new Error("handle remains open")
    const primary = createStore({
      open: async () => {
        throw primaryError
      },
      close: async () => {
        throw cleanupError
      },
    })
    const fallbackFactory = vi.fn(() => createStore({}).store)
    const store = new InlineStartupPersistenceStore({
      primary: () => primary.store,
      fallback: fallbackFactory,
      canFallback: isInlineSqliteStartupFallbackSafe,
    })

    const error = await store.open().catch((cause) => cause)
    expect(error).toBeInstanceOf(
      InlinePersistencePrimaryCleanupError,
    )
    expect(error).toMatchObject({ primaryError, cleanupError })
    expect(fallbackFactory).not.toHaveBeenCalled()
  })

  it("keeps both startup failures when the fallback cannot open", async () => {
    const primaryError = new InlineSqliteUnavailableError(
      "opfs-unsupported",
    )
    const fallbackError = new Error("IndexedDB denied")
    const primary = createStore({
      open: async () => {
        throw primaryError
      },
    })
    const fallback = createStore({
      open: async () => {
        throw fallbackError
      },
    })
    const store = new InlineStartupPersistenceStore({
      primary: () => primary.store,
      fallback: () => fallback.store,
      canFallback: isInlineSqliteStartupFallbackSafe,
    })

    const error = await store.open().catch((cause) => cause)
    expect(error).toBeInstanceOf(InlinePersistenceFallbackOpenError)
    expect(error).toMatchObject({ primaryError, fallbackError })
    expect(fallback.close).toHaveBeenCalledOnce()
  })

  it("closes and refuses a fallback which fails replica preparation", async () => {
    const primaryError = new InlineSqliteUnavailableError(
      "opfs-unsupported",
    )
    const promotedError = new Error("SQLite is authoritative")
    const primary = createStore({
      open: async () => {
        throw primaryError
      },
    })
    const fallback = createStore({ storedUser: user })
    const store = new InlineStartupPersistenceStore({
      primary: () => primary.store,
      fallback: () => fallback.store,
      prepareFallback: async () => {
        throw promotedError
      },
      canFallback: isInlineSqliteStartupFallbackSafe,
    })

    const error = await store.open().catch((cause) => cause)
    expect(error).toBeInstanceOf(InlinePersistenceFallbackOpenError)
    expect(error).toMatchObject({ primaryError, fallbackError: promotedError })
    expect(fallback.open).toHaveBeenCalledOnce()
    expect(fallback.close).toHaveBeenCalledOnce()
    expect(store.getSelectionSnapshot()).toEqual({ phase: "failed", error })
  })

  it("reports when no fallback adapter exists", async () => {
    const primaryError = new InlineSqliteUnavailableError(
      "opfs-unsupported",
    )
    const primary = createStore({
      open: async () => {
        throw primaryError
      },
    })
    const store = new InlineStartupPersistenceStore({
      primary: () => primary.store,
      fallback: () => null,
      canFallback: isInlineSqliteStartupFallbackSafe,
    })

    await expect(store.open()).rejects.toMatchObject({
      name: InlinePersistenceFallbackUnavailableError.name,
      primaryError,
    })
  })

  it("only classifies pre-database capability and permission failures as safe", () => {
    expect(
      isInlineSqliteStartupFallbackSafe(
        new InlineSqliteUnavailableError("worker-required"),
      ),
    ).toBe(true)
    expect(
      isInlineSqliteStartupFallbackSafe(
        new InlineSqliteUnavailableError("opfs-unsupported"),
      ),
    ).toBe(true)
    expect(
      isInlineSqliteStartupFallbackSafe(
        new InlineSqliteUnavailableError("opfs-permission-denied"),
      ),
    ).toBe(true)
    expect(
      isInlineSqliteStartupFallbackSafe(
        new InlineSqliteUnavailableError(
          "wasm-initialization-failed",
        ),
      ),
    ).toBe(false)
    expect(
      isInlineSqliteStartupFallbackSafe(
        new InlineSqliteUnavailableError(
          "opfs-initialization-failed",
        ),
      ),
    ).toBe(false)
    expect(isInlineSqliteStartupFallbackSafe(new Error("IO"))).toBe(false)
  })
})
