import { describe, expect, it } from "vitest"
import { AuthStore, type AuthSession, type AuthSessionPersistence } from "@inline/auth/core"
import type { UserID } from "@inline/ids"
import { manualTime } from "@inline/reactive"
import { navigationCommandIds } from "../commands/navigation"
import { AppModel } from "./app-model"
import { coreResource, harness, microtasks, uid, type Harness } from "./test-support"

/** Storage shared by the tabs of one browser: a change in one tab notifies the others. */
const sharedStorage = () => {
  let session: AuthSession | null = null
  const tabs = new Set<() => void>()
  const tab = (): AuthSessionPersistence => {
    let listener: (() => void) | undefined
    const notifyOthers = () => {
      for (const notify of tabs) if (notify !== listener) notify()
    }
    return {
      load: async () => ({ status: "ready", session }),
      save: async (next) => {
        session = next
        notifyOthers()
      },
      clear: async () => {
        session = null
        notifyOthers()
      },
      subscribe: (fn) => {
        listener = fn
        tabs.add(fn)
        return () => tabs.delete(fn)
      },
    }
  }
  return { tab, seed: (next: AuthSession) => void (session = next) }
}

type SignIn = { id: number; disposed: boolean; dispose(): void }

const setup = async (options: { seed?: AuthSession } = {}) => {
  const storage = sharedStorage()
  if (options.seed) storage.seed(options.seed)
  const authStore = new AuthStore({ storage: storage.tab() })
  const time = manualTime()
  const cores: Harness[] = []
  const signIns: SignIn[] = []
  const erased: UserID[] = []
  let releaseErase: (() => void) | undefined
  let holdErase = false
  const app = new AppModel<SignIn>({
    authStore,
    platform: { os: "mac", surface: "browser" },
    createSignIn: () => {
      const model: SignIn = {
        id: signIns.length + 1,
        disposed: false,
        dispose() {
          this.disposed = true
        },
      }
      signIns.push(model)
      return model
    },
    session: {
      clock: time,
      connect: () => {
        const h = harness()
        cores.push(h)
        return h.connection()
      },
    },
    eraseAccountData: async (userId) => {
      erased.push(userId)
      if (holdErase) await new Promise<void>((resolve) => (releaseErase = resolve))
    },
  })
  const phase = () => app.phase.peek().kind
  return {
    storage,
    authStore,
    app,
    cores,
    signIns,
    erased,
    phase,
    holdErase: () => void (holdErase = true),
    releaseErase: () => releaseErase?.(),
    hydrate: async () => {
      await authStore.ready
      await microtasks()
    },
  }
}

const expectClosed = (core: Harness) => {
  expect(core.openSubs()).toEqual([])
  expect(core.endpoint.closed()).toBe(true)
  expect(core.endpoint.commands("session").at(-1)).toEqual({ kind: "session", action: "signOut" })
}

describe("AppModel", () => {
  it("boots until the stored session is read, then shows sign-in", async () => {
    const s = await setup()
    expect(s.phase()).toBe("booting")
    await s.hydrate()
    expect(s.phase()).toBe("signedOut")
    expect(s.signIns).toHaveLength(1)
  })

  it("starts a session from a stored session at boot", async () => {
    const s = await setup({ seed: { userId: uid(4), token: "t4" } })
    await s.hydrate()
    expect(s.phase()).toBe("signedIn")
    expect(s.signIns).toHaveLength(0)
    expect(s.app.session.peek()?.userId).toBe(uid(4))
    expect(s.cores[0]!.endpoint.commands("session")).toEqual([
      { kind: "session", action: "start", session: { userId: uid(4), token: "t4" } },
    ])
  })

  it("signs in: disposes the sign-in model and opens the account", async () => {
    const s = await setup()
    await s.hydrate()
    await s.authStore.login({ userId: uid(4), token: "t4" })
    expect(s.phase()).toBe("signedIn")
    expect(s.signIns[0]!.disposed).toBe(true)
    // The keyboard resolves the session's commands.
    const resolution = s.app.keyboard.resolve({
      key: "k",
      code: "KeyK",
      altKey: false,
      ctrlKey: false,
      metaKey: true,
      shiftKey: false,
    })
    expect(resolution.kind === "command" ? resolution.command.id : resolution.kind).toBe(navigationCommandIds.quickSearch)
  })

  it("signs out here: tears the session down, erases, then shows sign-in", async () => {
    const s = await setup({ seed: { userId: uid(4), token: "t4" } })
    await s.hydrate()
    const session = s.app.session.peek()!
    session.openChat("9" as never)
    const done = s.app.signOut()
    expect(s.phase()).toBe("signingOut")
    await done
    await s.app.idle()
    expect(s.phase()).toBe("signedOut")
    expect(s.erased).toEqual([uid(4)])
    expect(session.disposed).toBe(true)
    expectClosed(s.cores[0]!)
    expect(s.app.registry.get(navigationCommandIds.nextChat)).toBeUndefined()
  })

  it("follows a sign-out in another tab", async () => {
    const s = await setup({ seed: { userId: uid(4), token: "t4" } })
    await s.hydrate()
    const otherTab = new AuthStore({ storage: s.storage.tab() })
    await otherTab.ready
    expect(otherTab.isLoggedIn()).toBe(true)
    await otherTab.logout()
    await microtasks(20)
    await s.app.idle()
    expect(s.phase()).toBe("signedOut")
    expect(s.erased).toEqual([uid(4)])
    expectClosed(s.cores[0]!)
  })

  it("signs out when the core reports the session revoked", async () => {
    const s = await setup({ seed: { userId: uid(4), token: "t4" } })
    await s.hydrate()
    const core = s.cores[0]!
    const coreSub = core.sub((query) => query.kind === "core")
    core.endpoint.patch({
      resources: [{ sub: coreSub, value: coreResource({ phase: "signedOut", connection: "sessionRevoked" }) }],
    })
    await core.flush()
    await microtasks()
    await s.app.idle()
    expect(s.authStore.isLoggedIn()).toBe(false)
    expect(s.phase()).toBe("signedOut")
    expect(s.erased).toEqual([uid(4)])
    expectClosed(core)
  })

  it("waits for the erase before starting the next account", async () => {
    const s = await setup({ seed: { userId: uid(4), token: "t4" } })
    await s.hydrate()
    s.holdErase()
    await s.app.signOut()
    await microtasks()
    // Signed in again (as someone else) before the erase finished.
    await s.authStore.login({ userId: uid(5), token: "t5" })
    expect(s.phase()).toBe("signingOut")
    expect(s.cores).toHaveLength(1)
    s.releaseErase()
    await s.app.idle()
    expect(s.phase()).toBe("signedIn")
    expect(s.app.session.peek()?.userId).toBe(uid(5))
    expect(s.cores).toHaveLength(2)
  })

  it("disposes the session without erasing when the app closes", async () => {
    const s = await setup({ seed: { userId: uid(4), token: "t4" } })
    await s.hydrate()
    s.app.dispose()
    expect(s.erased).toEqual([])
    expect(s.cores[0]!.openSubs()).toEqual([])
    expect(s.cores[0]!.endpoint.closed()).toBe(true)
  })
})
