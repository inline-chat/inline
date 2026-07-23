import {
  AuthStore,
  DbObjectKind,
  type DbModels,
  type InlinePersistenceCollection,
  type InlinePersistenceStore,
} from "@inline/client/core"
import { userId } from "@inline/ids"
import { afterEach, describe, expect, it, vi } from "vitest"
import { InlineAccountCore } from "./InlineAccountCore"

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

const createCore = async (store: InlinePersistenceStore) => {
  const accountId = userId(7)
  const auth = new AuthStore({ persistence: "memory" })
  await auth.login({ token: "token", userId: accountId })
  return new InlineAccountCore(accountId, {
    auth,
    observeBrowserLifecycle: false,
    persistenceStore: store,
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
})
