import { AuthStore, type AuthSession } from "@inline/auth/core"
import { createSignInApi, createSignInModel, type SignInModel } from "@inline/auth/flows"
import type { DialogRow } from "@inline/core-protocol"
import type { ChatID, DialogID, UserID } from "@inline/ids"
import { createFakePlatform } from "@inline/platform/testing"
import { effect, manualTime } from "@inline/reactive"
import { createMemoryHistory, type MemoryHistory } from "@inline/view"
import { describe, expect, it } from "vitest"
import { createSessionHistory } from "./history-session"
import { createBootMetrics, perfNames } from "./perf"
import { AppRuntime, layoutStorageKey, type CoreRole } from "./runtime"
import {
  coreHarness,
  fakePerformance,
  manualPaints,
  memoryStorage,
  microtasks,
  sharedAuthStorage,
  signInFetch,
  type CoreHarness,
} from "./test-fixtures"

const uid = (n: number) => String(n) as UserID

type Tab = ReturnType<typeof openTab>

/** One browser tab: a runtime over its own auth store on the shared storage. */
const openTab = (
  storage: ReturnType<typeof sharedAuthStorage>,
  options: { path?: string; time?: ReturnType<typeof manualTime>; attach?: boolean; core?: Record<string, unknown>; sessionHistory?: boolean } = {},
) => {
  const time = options.time ?? manualTime()
  const authStore = new AuthStore({ storage: storage.tab() })
  const fake = createFakePlatform()
  const cores: CoreHarness[] = []
  const erased: UserID[] = []
  const local = memoryStorage()
  const perf = fakePerformance()
  const paints = manualPaints()
  const metrics = createBootMetrics({ performance: perf, afterPaint: paints.afterPaint })
  const history: MemoryHistory = createMemoryHistory(options.path ?? "/")
  let sessions = 0
  // As `boot.ts` wraps the browser's: entries from before a sign-out read as `/`.
  const appHistory = options.sessionHistory ? createSessionHistory(history, { newSession: () => `s${++sessions}` }) : history
  const roleListeners = new Set<(role: CoreRole) => void>()
  const attached: string[] = []
  const api = createSignInApi({
    fetch: signInFetch(),
    apiBaseUrl: "https://api.test/v1",
    device: { deviceId: "d1", deviceName: "Test" },
  })
  const runtime = new AppRuntime<SignInModel>({
    authStore,
    createSignIn: (deps) => createSignInModel({ api, authStore, clock: time, signOut: deps.signOut }),
    connect: () => {
      const harness = coreHarness(time, {
        ...options.core,
        role: "leader",
        onRole: (listener: (role: CoreRole) => void) => {
          roleListeners.add(listener)
          return () => roleListeners.delete(listener)
        },
      })
      cores.push(harness)
      return harness.connection
    },
    platform: fake.platform,
    keyboardPlatform: { os: "mac", surface: "browser" },
    clock: time,
    metrics,
    storage: local,
    buildId: "b1",
    history: () => appHistory,
    eraseAccountData: async (userId) => void erased.push(userId),
    ...(options.attach
      ? {
          attachSession: {
            ownsBadge: true,
            attach: (session) => {
              attached.push(`attach:${session.userId}`)
              return () => void attached.push(`detach:${session.userId}`)
            },
          },
        }
      : {}),
  })
  return {
    time,
    authStore,
    fake,
    cores,
    erased,
    local,
    perf,
    paints,
    metrics,
    history,
    runtime,
    roleListeners,
    attached,
    phase: () => runtime.app.phase.peek().kind,
    /** Let the auth store read its storage and the core's patches apply. */
    settle: async () => {
      await authStore.ready
      await microtasks()
      time.frame()
      await microtasks()
    },
  }
}

const signedIn = (session: AuthSession = { userId: uid(7), token: "t7" }) => {
  const storage = sharedAuthStorage()
  storage.seed(session)
  return storage
}

const expectClosed = (core: CoreHarness) => {
  expect(core.openSubs()).toEqual([])
  expect(core.endpoint.closed()).toBe(true)
}

describe("the gate", () => {
  it("cold boot signed out: booting until the store is read, then sign-in, with no core", async () => {
    const tab = openTab(sharedAuthStorage())
    expect(tab.phase()).toBe("booting")
    await tab.settle()
    expect(tab.phase()).toBe("signedOut")
    expect(tab.cores).toHaveLength(0)
    expect(tab.runtime.signedOutReason.peek()).toBeUndefined()
    expect(tab.metrics.has("gate")).toBe(true)
    expect(tab.perf.marks).toContain(perfNames.gate)
  })

  it("cold boot signed in: never shows sign-in, connects, and opens the address bar's chat", async () => {
    const tab = openTab(signedIn(), { path: "/c/12" })
    const seen: string[] = []
    const stop = effect(() => void seen.push(tab.runtime.app.phase.get().kind))
    await tab.settle()
    stop()
    expect(tab.phase()).toBe("signedIn")
    expect(seen).toEqual(["booting", "signedIn"])
    expect(tab.cores).toHaveLength(1)
    expect(tab.cores[0]!.endpoint.commands("session")).toEqual([
      { kind: "session", action: "start", session: { userId: uid(7), token: "t7" } },
    ])
    const session = tab.runtime.app.session.peek()!
    expect(session.workspace.focusedDestination.peek()).toEqual({ kind: "chat", chatId: "12" as ChatID })
    expect(tab.runtime.role.peek()).toBe("leader")
  })

  it("sign-in completing starts the session for the signed-in user", async () => {
    const tab = openTab(sharedAuthStorage())
    await tab.settle()
    const phase = tab.runtime.app.phase.peek()
    if (phase.kind !== "signedOut") throw new Error("expected sign-in")
    phase.signIn.chooseEmail()
    await phase.signIn.submitEmail("ada@example.com")
    await phase.signIn.submitCode("123456")
    await tab.settle()
    expect(tab.phase()).toBe("signedIn")
    expect(tab.runtime.app.session.peek()?.userId).toBe(uid(42))
    expect(tab.cores).toHaveLength(1)
  })

  it("sign-out here returns to sign-in without a notice, closes the core and erases the account", async () => {
    const tab = openTab(signedIn())
    await tab.settle()
    tab.local.setItem(layoutStorageKey(uid(7)), "{}")
    await tab.runtime.signOut()
    await tab.runtime.idle()
    await tab.settle()
    expect(tab.phase()).toBe("signedOut")
    expect(tab.runtime.signedOutReason.peek()).toBeUndefined()
    expectClosed(tab.cores[0]!)
    expect(tab.cores[0]!.endpoint.commands("session").at(-1)).toEqual({ kind: "session", action: "signOut" })
    expect(tab.erased).toEqual([uid(7)])
    expect(tab.local.getItem(layoutStorageKey(uid(7)))).toBeNull()
    expect(tab.local.getItem(`inline:workspace:${uid(7)}`)).toBeNull()
    expect(tab.runtime.role.peek()).toBeUndefined()
  })

  it("sign-out puts the address bar back at the root, so the next account does not open the last one's chat", async () => {
    const tab = openTab(signedIn(), { path: "/c/12/m/85" })
    await tab.settle()
    expect(tab.history.current().path).toBe("/c/12/m/85")
    await tab.runtime.signOut()
    await tab.runtime.idle()
    await tab.settle()
    expect(tab.phase()).toBe("signedOut")
    expect(tab.history.current().path).toBe("/")
    expect(tab.local.getItem(`inline:workspace:${uid(7)}`)).toBeNull()
    expect(tab.runtime.eraseIncomplete.peek()).toBe(false)
    // The next account starts on its own workspace, not on chat 12.
    const phase = tab.runtime.app.phase.peek()
    if (phase.kind !== "signedOut") throw new Error("expected sign-in")
    phase.signIn.chooseEmail()
    await phase.signIn.submitEmail("ada@example.com")
    await phase.signIn.submitCode("123456")
    await tab.settle()
    const next = tab.runtime.app.session.peek()!
    expect(next.userId).toBe(uid(42))
    expect(next.workspace.focusedDestination.peek()).toEqual({ kind: "empty" })
    expect(tab.history.current().path).toBe("/")
  })

  it("after sign-out, Back never reaches the ended account's chats: every older entry reads as `/`", async () => {
    const tab = openTab(signedIn(), { path: "/c/12/m/85", sessionHistory: true })
    await tab.settle()
    const first = tab.runtime.app.session.peek()!
    first.workspace.open({ kind: "chat", chatId: "13" as ChatID })
    expect(tab.history.current().path).toBe("/c/13")
    const before = tab.history.entries().length
    await tab.runtime.signOut()
    await tab.runtime.idle()
    await tab.settle()
    expect(tab.history.current().path).toBe("/")
    // Signed out: Back to the old account's entry shows `/`, not its chat.
    tab.history.back()
    expect(tab.history.current().path).toBe("/")
    tab.history.forward()
    // The next account.
    const phase = tab.runtime.app.phase.peek()
    if (phase.kind !== "signedOut") throw new Error("expected sign-in")
    phase.signIn.chooseEmail()
    await phase.signIn.submitEmail("ada@example.com")
    await phase.signIn.submitCode("123456")
    await tab.settle()
    const next = tab.runtime.app.session.peek()!
    next.workspace.open({ kind: "chat", chatId: "40" as ChatID })
    expect(tab.history.current().path).toBe("/c/40")
    // Back through the new account's own entry, then into the old account's: `/`, and the workspace stays its own.
    tab.history.back()
    tab.history.back()
    expect(tab.history.index()).toBeLessThan(before)
    expect(tab.history.current().path).toBe("/")
    expect(next.workspace.focusedDestination.peek()).not.toEqual({ kind: "chat", chatId: "13" })
    expect(next.workspace.focusedDestination.peek()).not.toMatchObject({ chatId: "12" })
    // Forward again reaches the new account's chat.
    while (tab.history.index() < tab.history.entries().length - 1) tab.history.forward()
    expect(next.workspace.focusedDestination.peek()).toEqual({ kind: "chat", chatId: "40" })
  })

  it("a sign-out whose erase failed says data may remain until the next start; the next sign-in clears it", async () => {
    const tab = openTab(signedIn(), { core: { eraseFails: true } })
    await tab.settle()
    // The core was seen running the session, so the session waits for its report.
    tab.cores[0]!.core({})
    await tab.settle()
    await tab.runtime.signOut()
    await tab.runtime.idle()
    await tab.settle()
    expect(tab.phase()).toBe("signedOut")
    expect(tab.runtime.eraseIncomplete.peek()).toBe(true)
    const phase = tab.runtime.app.phase.peek()
    if (phase.kind !== "signedOut") throw new Error("expected sign-in")
    phase.signIn.chooseEmail()
    await phase.signIn.submitEmail("ada@example.com")
    await phase.signIn.submitCode("123456")
    await tab.settle()
    expect(tab.phase()).toBe("signedIn")
    expect(tab.runtime.eraseIncomplete.peek()).toBe(false)
  })

  it("a sign-out the core never confirms ends after the wait and says data may remain", async () => {
    const tab = openTab(signedIn(), { core: { answerSignOut: false } })
    await tab.settle()
    tab.cores[0]!.core({})
    await tab.settle()
    await tab.runtime.signOut()
    await tab.settle()
    expect(tab.phase()).toBe("signingOut")
    tab.time.advance(10_000)
    await tab.runtime.idle()
    await tab.settle()
    expect(tab.phase()).toBe("signedOut")
    expect(tab.runtime.eraseIncomplete.peek()).toBe(true)
    tab.runtime.dismissSignedOutReason()
    expect(tab.runtime.eraseIncomplete.peek()).toBe(false)
  })

  it("sign-out in another tab ends this tab's account and says so", async () => {
    const storage = signedIn()
    const a = openTab(storage)
    const b = openTab(storage)
    await a.settle()
    await b.settle()
    expect(a.phase()).toBe("signedIn")
    await b.runtime.signOut()
    await b.runtime.idle()
    await a.settle()
    await a.runtime.idle()
    await a.settle()
    expect(a.phase()).toBe("signedOut")
    expect(a.runtime.signedOutReason.peek()).toBe("elsewhere")
    expect(b.runtime.signedOutReason.peek()).toBeUndefined()
    expectClosed(a.cores[0]!)
    expect(a.erased).toEqual([uid(7)])
  })

  it("revocation reported by the core signs out and says the session was ended", async () => {
    const tab = openTab(signedIn())
    await tab.settle()
    tab.cores[0]!.core({ connection: "sessionRevoked" })
    await tab.settle()
    await tab.runtime.idle()
    await tab.settle()
    expect(tab.phase()).toBe("signedOut")
    expect(tab.runtime.signedOutReason.peek()).toBe("revoked")
    expect(tab.authStore.getState().token).toBeNull()
    expectClosed(tab.cores[0]!)
  })

  it("a new sign-in clears the signed-out notice", async () => {
    const tab = openTab(signedIn())
    await tab.settle()
    tab.cores[0]!.core({ connection: "sessionRevoked" })
    await tab.settle()
    await tab.runtime.idle()
    await tab.settle()
    expect(tab.runtime.signedOutReason.peek()).toBe("revoked")
    await tab.authStore.login({ userId: uid(8), token: "t8" })
    await tab.settle()
    expect(tab.phase()).toBe("signedIn")
    expect(tab.runtime.signedOutReason.peek()).toBeUndefined()
  })
})

describe("per-session wiring", () => {
  const dialog = (n: number, unreadCount = 0): DialogRow => ({
    kind: "dialog",
    id: String(n) as DialogID,
    chatId: String(n) as ChatID,
    peerUserId: String(100 + n) as UserID,
    pinned: false,
    archived: false,
    open: true,
    unreadCount,
    unreadMark: false,
  })

  it("marks core ready and the first sidebar rows after paint", async () => {
    const tab = openTab(signedIn())
    await tab.settle()
    const core = tab.cores[0]!
    core.core({ phase: "ready" })
    await tab.settle()
    expect(tab.metrics.has("coreReady")).toBe(true)
    core.list((query) => query.kind === "sidebar" && query.mode === "inbox", [dialog(1)])
    await tab.settle()
    expect(tab.metrics.has("sidebarRows")).toBe(false)
    tab.paints.paint()
    expect(tab.metrics.has("sidebarRows")).toBe(true)
    expect(tab.metrics.measures().map((measure) => measure.name)).toEqual([
      perfNames.gate,
      perfNames.coreReady,
      perfNames.sidebarRows,
    ])
  })

  it("keeps the badge on the session's prominent unread count and clears it on sign-out", async () => {
    const tab = openTab(signedIn())
    await tab.settle()
    tab.cores[0]!.list((query) => query.kind === "sidebar" && query.mode === "all", [dialog(1, 3), dialog(2, 1)])
    await tab.settle()
    tab.fake.clock.advance(1_000)
    expect(tab.fake.badge.applied.at(-1)).toBe(2)
    await tab.runtime.signOut()
    await tab.runtime.idle()
    expect(tab.fake.badge.applied.at(-1)).toBe(0)
  })

  it("flushes drafts and the workspace on page hide", async () => {
    const tab = openTab(signedIn())
    await tab.settle()
    let flushed = 0
    tab.runtime.unsavedWork.onFlush(() => void (flushed += 1))
    tab.local.removeItem(`inline:workspace:${uid(7)}`)
    tab.fake.lifecycle.pageHide(false)
    expect(flushed).toBe(1)
    expect(tab.local.getItem(`inline:workspace:${uid(7)}`)).not.toBeNull()
  })

  it("runs the session hook for each session and undoes it when the session ends", async () => {
    const storage = signedIn()
    const tab = openTab(storage, { attach: true })
    await tab.settle()
    expect(tab.attached).toEqual(["attach:7"])
    await tab.runtime.signOut()
    await tab.runtime.idle()
    expect(tab.attached).toEqual(["attach:7", "detach:7"])
    // The hook owns the badge: the runtime never touched it.
    expect(tab.fake.badge.applied).toEqual([])
  })

  it("follows the link role of the connection", async () => {
    const tab = openTab(signedIn())
    await tab.settle()
    for (const listener of tab.roleListeners) listener("follower")
    expect(tab.runtime.role.peek()).toBe("follower")
  })

  it("routes type-to-focus and focus restore to the attached shell", async () => {
    const tab = openTab(signedIn())
    await tab.settle()
    const calls: string[] = []
    const detach = tab.runtime.attachShell({
      focusRegion: (region) => void calls.push(`region:${region}`),
      typeToFocus: () => void calls.push("type"),
      restoreFocus: () => void calls.push("restore"),
    })
    tab.runtime.app.keyboard.handleKeyDown({
      key: "a",
      code: "KeyA",
      ctrlKey: false,
      metaKey: false,
      altKey: false,
      shiftKey: false,
      target: null,
    })
    tab.runtime.restoreFocus()
    detach()
    tab.runtime.restoreFocus()
    expect(calls).toEqual(["type", "restore"])
  })
})

export type { Tab }
