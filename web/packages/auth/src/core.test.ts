import {
  IDBFactory,
  IDBKeyRange,
  IDBObjectStore,
} from "fake-indexeddb"
import { afterEach, describe, expect, it, vi } from "vitest"
import { userId } from "@inline/ids"
import { AuthStore } from "./core"
import {
  BrowserAuthSessionPersistence,
  type AuthSessionPersistence,
  type AuthSessionPersistenceLoadResult,
} from "./persistence"

const installBrowserStorage = () => {
  const values = new Map<string, string>()
  const localStorage = {
    getItem: vi.fn((key: string) => values.get(key) ?? null),
    setItem: vi.fn((key: string, value: string) => {
      values.set(key, value)
    }),
    removeItem: vi.fn((key: string) => {
      values.delete(key)
    }),
  }
  vi.stubGlobal("indexedDB", new IDBFactory())
  vi.stubGlobal("IDBKeyRange", IDBKeyRange)
  vi.stubGlobal("BroadcastChannel", undefined)
  vi.stubGlobal("window", { localStorage })
  return { values, localStorage }
}

const deferred = <T>() => {
  let resolve!: (value: T) => void
  const promise = new Promise<T>((next) => {
    resolve = next
  })
  return { promise, resolve }
}

const putRawBrowserSession = async (value: unknown) => {
  const database = await new Promise<IDBDatabase>((resolve, reject) => {
    const request = indexedDB.open("inline-auth-session", 1)
    request.onupgradeneeded = () => {
      if (!request.result.objectStoreNames.contains("sessions")) {
        request.result.createObjectStore("sessions", {
          keyPath: "key",
        })
      }
    }
    request.onsuccess = () => resolve(request.result)
    request.onerror = () => reject(request.error)
  })
  await new Promise<void>((resolve, reject) => {
    const transaction = database.transaction("sessions", "readwrite")
    transaction.objectStore("sessions").put(value)
    transaction.oncomplete = () => resolve()
    transaction.onerror = () => reject(transaction.error)
  })
  database.close()
}

class TestBroadcastChannel {
  static readonly instances = new Set<TestBroadcastChannel>()
  static readonly messages: unknown[] = []
  private readonly listeners = new Set<() => void>()

  constructor(readonly name: string) {
    TestBroadcastChannel.instances.add(this)
  }

  postMessage(message: unknown) {
    TestBroadcastChannel.messages.push(message)
    for (const instance of TestBroadcastChannel.instances) {
      if (instance !== this && instance.name === this.name) {
        for (const listener of instance.listeners) listener()
      }
    }
  }

  addEventListener(_type: "message", listener: () => void) {
    this.listeners.add(listener)
  }

  removeEventListener(_type: "message", listener: () => void) {
    this.listeners.delete(listener)
  }
}

describe("AuthStore persistence boundary", () => {
  afterEach(() => {
    TestBroadcastChannel.instances.clear()
    TestBroadcastChannel.messages.length = 0
    vi.restoreAllMocks()
    vi.unstubAllGlobals()
  })

  it("keeps desktop sessions in memory when browser persistence is disabled", async () => {
    const storage = {
      getItem: vi.fn(() => null),
      setItem: vi.fn(),
      removeItem: vi.fn(),
    }
    vi.stubGlobal("window", { localStorage: storage })

    const auth = new AuthStore()
    await auth.login({
      token: "sensitive-token",
      userId: userId(7),
    })
    await auth.logout()

    expect(auth.getState().hasHydrated).toBe(true)
    expect(storage.getItem).not.toHaveBeenCalled()
    expect(storage.setItem).not.toHaveBeenCalled()
    expect(storage.removeItem).not.toHaveBeenCalled()
  })

  it("does not retain a BroadcastChannel while rendering on the server", async () => {
    const channel = vi.fn()
    vi.stubGlobal("BroadcastChannel", channel)

    const auth = new AuthStore({
      storage: new BrowserAuthSessionPersistence(
        "server-render-session",
      ),
    })
    await auth.ready

    expect(channel).not.toHaveBeenCalled()
  })

  it("atomically migrates a lossless legacy session out of localStorage", async () => {
    const { values } = installBrowserStorage()
    values.set("inline-web-session:token", "token")
    values.set(
      "inline-web-session:user-id",
      "9007199254740993",
    )

    const auth = new AuthStore({
      storage: new BrowserAuthSessionPersistence(
        "inline-web-session",
      ),
    })
    await auth.ready

    expect(auth.getState()).toMatchObject({
      status: "authenticated",
      storageStatus: "ready",
      token: "token",
      currentUserId: "9007199254740993",
      hasHydrated: true,
    })
    expect(values.has("inline-web-session:token")).toBe(false)
    expect(values.has("inline-web-session:user-id")).toBe(false)

    const reloaded = new AuthStore({
      storage: new BrowserAuthSessionPersistence(
        "inline-web-session",
      ),
    })
    await reloaded.ready
    expect(reloaded.getState()).toMatchObject({
      token: "token",
      currentUserId: "9007199254740993",
    })
  })

  it("does not expose or retain a torn token-only legacy session", async () => {
    const { values } = installBrowserStorage()
    values.set("inline-web-session:token", "token")

    const auth = new AuthStore({
      storage: new BrowserAuthSessionPersistence(
        "inline-web-session",
      ),
    })
    await auth.ready

    expect(auth.isLoggedIn()).toBe(false)
    expect(auth.getState().token).toBeNull()
    expect(auth.getState().currentUserId).toBeNull()
    expect(values.has("inline-web-session:token")).toBe(false)
  })

  it("repairs a corrupt v1 record from a valid legacy session before requiring reauthentication", async () => {
    const { values } = installBrowserStorage()
    const key = `repair-${crypto.randomUUID()}`
    values.set(`${key}:token`, "legacy-token")
    values.set(`${key}:user-id`, "7")
    await putRawBrowserSession({
      key,
      version: 1,
      token: "",
      userId: "7",
    })

    const auth = new AuthStore({
      storage: new BrowserAuthSessionPersistence(key),
    })
    await auth.ready
    expect(auth.getState()).toMatchObject({
      status: "authenticated",
      storageStatus: "ready",
      token: "legacy-token",
      currentUserId: userId(7),
    })
    expect(values.has(`${key}:token`)).toBe(false)
    expect(values.has(`${key}:user-id`)).toBe(false)
  })

  it("does not let a late hydration overwrite a newer login", async () => {
    const load = deferred<AuthSessionPersistenceLoadResult>()
    const storage: AuthSessionPersistence = {
      load: () => load.promise,
      save: vi.fn(async () => undefined),
      clear: vi.fn(async () => undefined),
    }
    const auth = new AuthStore({ storage })
    const login = auth.login({ token: "new-token", userId: userId(7) })
    load.resolve({ status: "ready", session: null })
    await Promise.all([auth.ready, login])

    expect(auth.getState()).toMatchObject({
      status: "authenticated",
      storageStatus: "ready",
      token: "new-token",
      currentUserId: userId(7),
      hasHydrated: true,
    })
  })

  it("keeps usable in-memory credentials while reporting a persistence failure", async () => {
    const storage: AuthSessionPersistence = {
      load: vi.fn(async () => ({
        status: "ready" as const,
        session: null,
      })),
      save: vi.fn(async () => {
        throw new Error("storage unavailable")
      }),
      clear: vi.fn(async () => undefined),
    }
    const auth = new AuthStore({ storage })
    await auth.ready
    await expect(
      auth.login({ token: "memory-token", userId: userId(7) }),
    ).resolves.toBeUndefined()
    expect(auth.getState()).toMatchObject({
      status: "authenticated",
      storageStatus: "unavailable",
      token: "memory-token",
    })
  })

  it("uses a logout tombstone to prevent stale-session resurrection after delete failure", async () => {
    const { values } = installBrowserStorage()
    const key = `logout-${crypto.randomUUID()}`
    const auth = new AuthStore({
      storage: new BrowserAuthSessionPersistence(key),
    })
    await auth.ready
    await auth.login({ token: "token", userId: userId(7) })

    const deleteSpy = vi
      .spyOn(IDBObjectStore.prototype, "delete")
      .mockImplementationOnce(() => {
        throw new Error("forced delete failure")
      })
    await auth.logout()
    expect(auth.getState()).toMatchObject({
      status: "unauthenticated",
      storageStatus: "unavailable",
      token: null,
    })
    expect(values.get(`${key}:logout-pending`)).toBe("1")
    deleteSpy.mockRestore()

    const reloaded = new AuthStore({
      storage: new BrowserAuthSessionPersistence(key),
    })
    await reloaded.ready
    expect(reloaded.getState()).toMatchObject({
      status: "unauthenticated",
      token: null,
      currentUserId: null,
    })
    expect(values.has(`${key}:logout-pending`)).toBe(false)
  })

  it("isolates exact sessions by account-store key", async () => {
    installBrowserStorage()
    const first = new AuthStore({
      storage: new BrowserAuthSessionPersistence("account-one"),
    })
    const second = new AuthStore({
      storage: new BrowserAuthSessionPersistence("account-two"),
    })
    await Promise.all([first.ready, second.ready])
    await first.login({ token: "one", userId: userId(1) })
    await second.login({ token: "two", userId: userId(2) })

    const firstReloaded = new AuthStore({
      storage: new BrowserAuthSessionPersistence("account-one"),
    })
    const secondReloaded = new AuthStore({
      storage: new BrowserAuthSessionPersistence("account-two"),
    })
    await Promise.all([firstReloaded.ready, secondReloaded.ready])
    expect(firstReloaded.getState()).toMatchObject({
      token: "one",
      currentUserId: userId(1),
    })
    expect(secondReloaded.getState()).toMatchObject({
      token: "two",
      currentUserId: userId(2),
    })
  })

  it("refreshes sibling tabs without broadcasting credential material", async () => {
    installBrowserStorage()
    vi.stubGlobal("BroadcastChannel", TestBroadcastChannel)
    const key = `tabs-${crypto.randomUUID()}`
    const first = new AuthStore({
      storage: new BrowserAuthSessionPersistence(key),
    })
    const second = new AuthStore({
      storage: new BrowserAuthSessionPersistence(key),
    })
    await Promise.all([first.ready, second.ready])

    await first.login({ token: "secret-token", userId: userId(7) })
    await vi.waitFor(() => {
      expect(second.getState()).toMatchObject({
        token: "secret-token",
        currentUserId: userId(7),
      })
    })
    expect(JSON.stringify(TestBroadcastChannel.messages)).not.toContain(
      "secret-token",
    )

    await first.logout()
    await vi.waitFor(() => {
      expect(second.isLoggedIn()).toBe(false)
    })
  })

  it("surfaces corrupt persistence as reauthentication without exposing a token", async () => {
    const storage: AuthSessionPersistence = {
      load: vi.fn(async () => ({
        status: "corrupt" as const,
        userIdHint: userId(7),
      })),
      save: vi.fn(async () => undefined),
      clear: vi.fn(async () => undefined),
    }
    const auth = new AuthStore({ storage })
    await auth.ready
    expect(auth.getState()).toEqual({
      status: "reauthRequired",
      storageStatus: "corrupt",
      token: null,
      currentUserId: null,
      userIdHint: userId(7),
      hasHydrated: true,
    })
  })
})
