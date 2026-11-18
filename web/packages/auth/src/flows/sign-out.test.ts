import { describe, expect, it } from "vitest"
import { userId, type UserID } from "@inline/ids"
import { AuthStore, type AuthSession } from "../core"
import type { AuthSessionPersistence, AuthSessionPersistenceLoadResult } from "../persistence"
import { MemoryAuthSessionPersistence } from "../persistence"
import type { ApiResult, SignInApi } from "./api"
import { signOut, watchAccountEnd } from "./sign-out"
import { SECRET_TOKEN, VirtualClock, flushMicrotasks } from "./test-support"

const session: AuthSession = { token: SECRET_TOKEN, userId: userId(42) }

/**
 * Two tabs over one origin: a shared record and a broadcast that, like
 * BroadcastChannel, reaches every tab but the writer.
 */
class SharedOrigin {
  record: AuthSession | null = null
  private readonly tabs = new Set<{ notify: () => void }>()

  tab(): AuthSessionPersistence {
    const self = { notify: () => undefined as void }
    const broadcast = () => {
      for (const tab of this.tabs) if (tab !== self) tab.notify()
    }
    return {
      load: async (): Promise<AuthSessionPersistenceLoadResult> => ({
        status: "ready",
        session: this.record,
      }),
      save: async (next) => {
        this.record = next
        broadcast()
      },
      clear: async () => {
        this.record = null
        broadcast()
      },
      subscribe: (listener) => {
        self.notify = listener
        this.tabs.add(self)
        return () => {
          this.tabs.delete(self)
        }
      },
    }
  }
}

const loggedInStore = async (persistence: AuthSessionPersistence = new MemoryAuthSessionPersistence()) => {
  const store = new AuthStore({ storage: persistence })
  await store.ready
  await store.login(session)
  return store
}

const logoutApi = (
  reply: () => Promise<ApiResult<void>>,
  log: string[],
): Pick<SignInApi, "logout"> => ({
  logout: (token) => {
    log.push(`revoke:${token === SECRET_TOKEN ? "token" : "other"}`)
    return reply()
  },
})

describe("signOut", () => {
  it("revokes, then clears the session, then erases the account's data", async () => {
    const log: string[] = []
    const store = await loggedInStore()
    store.subscribe((state) => {
      if (state.token == null && !log.includes("logout")) log.push("logout")
    })
    const result = await signOut({
      authStore: store,
      api: logoutApi(async () => ({ ok: true, value: undefined }), log),
      eraseAccountData: async (id) => {
        log.push(`erase:${id}`)
      },
    })
    expect(log).toEqual(["revoke:token", "logout", "erase:42"])
    expect(result).toEqual({ userId: "42", revoke: "ok", erase: "ok", storage: "ready" })
    expect(store.isLoggedIn()).toBe(false)
  })

  it("signs out locally when the server cannot be reached or erasing fails", async () => {
    const store = await loggedInStore()
    const result = await signOut({
      authStore: store,
      api: logoutApi(async () => ({ ok: false, error: { kind: "network" } }), []),
      eraseAccountData: async () => {
        throw new Error("disk")
      },
    })
    expect(result).toMatchObject({ revoke: "failed", erase: "failed", storage: "ready" })
    expect(store.isLoggedIn()).toBe(false)
  })

  it("counts a session the server already rejects as revoked", async () => {
    const store = await loggedInStore()
    const result = await signOut({
      authStore: store,
      api: logoutApi(async () => ({ ok: false, error: { kind: "server", status: 401, code: "UNAUTHORIZED" } }), []),
    })
    expect(result.revoke).toBe("ok")
    expect(result.erase).toBe("skipped")
  })

  it("stops waiting for the server after the revoke timeout", async () => {
    const clock = new VirtualClock()
    const store = await loggedInStore()
    const signing = signOut({
      authStore: store,
      api: logoutApi(() => new Promise(() => undefined), []),
      clock,
      revokeTimeoutMs: 3_000,
    })
    await clock.advance(2_999)
    expect(store.isLoggedIn()).toBe(true)
    await clock.advance(1)
    expect(await signing).toMatchObject({ revoke: "failed" })
    expect(store.isLoggedIn()).toBe(false)
  })

  it("joins a sign-out that is already running", async () => {
    const log: string[] = []
    const store = await loggedInStore()
    let release!: () => void
    const api = logoutApi(
      () =>
        new Promise((resolve) => {
          release = () => resolve({ ok: true, value: undefined })
        }),
      log,
    )
    const first = signOut({ authStore: store, api })
    const second = signOut({ authStore: store, api })
    expect(second).toBe(first)
    release()
    await first
    expect(log).toEqual(["revoke:token"])
  })
})

describe("watchAccountEnd", () => {
  it("tells another tab its account ended when this tab signs out", async () => {
    const origin = new SharedOrigin()
    const tabA = await loggedInStore(origin.tab())
    const tabB = new AuthStore({ storage: origin.tab() })
    await tabB.ready
    expect(tabB.getState().currentUserId).toBe("42")

    const endedInB: UserID[] = []
    const endedInA: UserID[] = []
    const stopB = watchAccountEnd(tabB, (id) => endedInB.push(id))
    const stopA = watchAccountEnd(tabA, (id) => endedInA.push(id))

    const erased: UserID[] = []
    await signOut({ authStore: tabA, eraseAccountData: async (id) => void erased.push(id) })
    await flushMicrotasks()

    expect(tabB.isLoggedIn()).toBe(false)
    expect(endedInB).toEqual(["42"])
    expect(endedInA).toEqual(["42"])
    expect(erased).toEqual(["42"])
    stopA()
    stopB()
  })

  it("reports a switch to another user and stays quiet otherwise", async () => {
    const store = await loggedInStore()
    const ended: UserID[] = []
    const stop = watchAccountEnd(store, (id) => ended.push(id))
    await store.login({ token: "other-token", userId: userId(43) })
    await store.login({ token: "other-token-2", userId: userId(43) })
    expect(ended).toEqual(["42"])
    stop()
    await store.logout()
    expect(ended).toEqual(["42"])
  })
})
