import {
  AuthStore,
  DbObjectKind,
  TransactionErrors,
  TransactionFailure,
  type DbModels,
  type InlinePersistenceCollection,
  type InlinePersistenceStore,
} from "@inline/client/core"
import { userId } from "@inline/ids"
import { afterEach, describe, expect, it, vi } from "vitest"
import {
  InlineAccountCore,
  type InlineAccountCoreOptions,
} from "./InlineAccountCore"

const createPersistenceStore = (
  open: () => Promise<void> = async () => undefined,
): InlinePersistenceStore => {
  const collection = {
    init: async () => undefined,
    get: async () => undefined,
    getMany: async () => [],
    getAll: async () => [],
    put: async () => undefined,
    delete: async () => undefined,
  }

  return {
    open,
    close: async () => undefined,
    write: async () => undefined,
    collection: <K extends DbObjectKind>() =>
      collection as InlinePersistenceCollection<DbModels[K]>,
  }
}

const createCore = async (
  store: InlinePersistenceStore | null,
  options: Partial<InlineAccountCoreOptions> = {},
) => {
  const accountId = userId(7)
  const auth = new AuthStore({ persistence: "memory" })
  await auth.login({ token: "token", userId: accountId })
  return new InlineAccountCore(accountId, {
    auth,
    observeBrowserLifecycle: false,
    persistenceStore: store,
    ...options,
  })
}

describe("InlineAccountCore failure states", () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("blocks the product when the local replica cannot open", async () => {
    const core = await createCore(
      createPersistenceStore(async () => {
        throw new Error("replica unavailable")
      }),
    )
    const realtimeStart = vi.spyOn(core.realtime, "start")

    await core.start()

    expect(core.getSnapshot()).toMatchObject({
      phase: "error",
      cacheReady: false,
      blockingFailure: {
        code: "storage-unavailable",
        message: "replica unavailable",
        recoveryAction: "reload",
      },
    })
    expect(core.getSnapshot().syncIssue).toBeUndefined()
    expect(realtimeStart).not.toHaveBeenCalled()
    await core.stop()
  })

  it("blocks instead of silently starting with memory-only storage", async () => {
    const core = await createCore(null)
    const realtimeStart = vi.spyOn(core.realtime, "start")

    await core.start()

    expect(core.getSnapshot()).toMatchObject({
      phase: "error",
      cacheReady: false,
      blockingFailure: {
        code: "storage-unavailable",
        message: "Inline requires durable browser storage to start.",
        recoveryAction: "reload",
      },
    })
    expect(realtimeStart).not.toHaveBeenCalled()
    await core.stop()
  })

  it("opens neither storage nor realtime when another tab owns the account", async () => {
    const open = vi.fn(async () => undefined)
    const core = await createCore(createPersistenceStore(open), {
      acquireAccountOwnership: async () => null,
    })
    const realtimeStart = vi.spyOn(core.realtime, "start")

    await core.start()

    expect(core.getSnapshot()).toMatchObject({
      phase: "error",
      cacheReady: false,
      blockingFailure: {
        code: "owner-unavailable",
        message: "Inline is already open in another tab.",
      },
    })
    expect(open).not.toHaveBeenCalled()
    expect(realtimeStart).not.toHaveBeenCalled()
    await core.stop()
  })

  it("releases account ownership only after persistence closes", async () => {
    const events: string[] = []
    const store = createPersistenceStore()
    store.close = async () => {
      events.push("storage-closed")
    }
    const core = await createCore(store, {
      acquireAccountOwnership: async () => ({
        release: async () => {
          events.push("ownership-released")
        },
      }),
    })
    vi.spyOn(core.realtime, "start").mockResolvedValue()
    vi.spyOn(core.realtime, "query").mockResolvedValue(undefined)

    await core.start()
    await core.stop()

    expect(events).toEqual([
      "storage-closed",
      "ownership-released",
    ])
  })

  it("retains account ownership when persistence cannot close safely", async () => {
    const store = createPersistenceStore()
    const open = vi.spyOn(store, "open")
    store.close = async () => {
      throw new Error("replica close failed")
    }
    const release = vi.fn(async () => undefined)
    const core = await createCore(store, {
      acquireAccountOwnership: async () => ({ release }),
    })
    vi.spyOn(core.realtime, "start").mockResolvedValue()
    vi.spyOn(core.realtime, "query").mockResolvedValue(undefined)

    await core.start()
    await expect(core.stop()).rejects.toThrow("replica close failed")

    expect(release).not.toHaveBeenCalled()
    expect(core.getSnapshot()).toMatchObject({
      phase: "error",
      blockingFailure: {
        code: "storage-unavailable",
        recoveryAction: "reload",
      },
    })
    await expect(core.start()).rejects.toThrow(
      "Reload before reopening this account",
    )
    expect(open).toHaveBeenCalledOnce()
  })

  it("cannot finish realtime startup after core shutdown begins", async () => {
    let signalRestoreStarted!: () => void
    const restoreStarted = new Promise<void>((resolve) => {
      signalRestoreStarted = resolve
    })
    let finishRestore!: () => void
    const restoreFinished = new Promise<void>((resolve) => {
      finishRestore = resolve
    })
    const store = createPersistenceStore()
    const baseCollection = store.collection
    store.collection = <K extends DbObjectKind>(kind: K) => {
      const collection = baseCollection(kind)
      if (kind !== DbObjectKind.PendingTransaction) return collection
      return {
        ...collection,
        getAll: async () => {
          signalRestoreStarted()
          await restoreFinished
          return []
        },
      } as InlinePersistenceCollection<DbModels[K]>
    }
    const core = await createCore(store)
    const connectionStart = vi.spyOn(
      core.realtime.connection,
      "start",
    )

    const starting = core.start()
    await restoreStarted
    const stopping = core.stop()
    finishRestore()

    await expect(starting).resolves.toBeUndefined()
    await expect(stopping).resolves.toBeUndefined()
    expect(connectionStart).not.toHaveBeenCalled()
    expect(core.realtime.connection.state).toBe("stopped")
    expect(core.getSnapshot().phase).toBe("stopped")
  })

  it("closes persistence even when realtime teardown fails", async () => {
    const store = createPersistenceStore()
    const close = vi.spyOn(store, "close")
    const core = await createCore(store)
    vi.spyOn(core.realtime, "stop").mockRejectedValue(
      new Error("transport teardown failed"),
    )

    await expect(core.stop()).rejects.toThrow(
      "transport teardown failed",
    )
    expect(close).toHaveBeenCalledOnce()
    expect(core.getSnapshot().phase).toBe("stopped")
  })

  it("keeps cached product state usable when initial sync is unavailable", async () => {
    const core = await createCore(createPersistenceStore())
    vi.spyOn(core.realtime, "start").mockResolvedValue()
    vi.spyOn(core.realtime, "query").mockRejectedValue(
      new Error("network unavailable"),
    )

    await core.start()

    expect(core.getSnapshot()).toMatchObject({
      phase: "cacheReady",
      cacheReady: true,
      syncIssue: {
        code: "initial-sync-unavailable",
        message: "network unavailable",
      },
    })
    expect(core.getSnapshot().blockingFailure).toBeUndefined()
    await core.stop()
  })

  it("treats an explicit stop during initial sync as normal cancellation", async () => {
    const core = await createCore(createPersistenceStore())
    vi.spyOn(core.realtime, "start").mockResolvedValue()
    vi.spyOn(core.realtime, "query").mockRejectedValue(
      new TransactionFailure(TransactionErrors.stopped()),
    )

    await core.start()

    expect(core.getSnapshot()).toMatchObject({
      phase: "cacheReady",
      cacheReady: true,
      connectionState: "idle",
    })
    expect(core.getSnapshot().syncIssue).toBeUndefined()
    expect(core.getSnapshot().blockingFailure).toBeUndefined()
    await core.stop()
  })
})
