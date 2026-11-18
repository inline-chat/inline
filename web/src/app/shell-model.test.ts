import type { UserID } from "@inline/ids"
import { manualTime, signal } from "@inline/reactive"
import { createManualClock, ToastQueue } from "@inline/ui"
import { navigationCommandIds } from "@inline/view"
import { AccountSession } from "@inline/view/features"
import { describe, expect, it } from "vitest"
import { layoutStorageKey, type ShellHooks } from "./runtime"
import type { QuickSearchWiring } from "../features/quick-search/wiring"
import { SIDEBAR_PANE, ShellModel } from "./shell-model"
import { coreHarness, memoryStorage, microtasks } from "./test-fixtures"

const setup = (stored?: string) => {
  const time = manualTime()
  const harness = coreHarness(time)
  const userId = "7" as UserID
  const session = new AccountSession({ userId, token: "t", connect: () => harness.connection, clock: time })
  const storage = memoryStorage()
  if (stored !== undefined) storage.setItem(layoutStorageKey(userId), stored)
  let shellHooks: ShellHooks | undefined
  const runtime = {
    storage,
    attachShell: (hooks: ShellHooks) => {
      shellHooks = hooks
      return () => void (shellHooks = undefined)
    },
  }
  const frames: (() => void)[] = []
  const shell = new ShellModel({
    runtime,
    session,
    toasts: new ToastQueue({ clock: createManualClock() }),
    nextFrame: (fn) => void frames.push(fn),
  })
  return { session, storage, shell, userId, hooks: () => shellHooks, frames }
}

const composer = (calls: string[], name: string) => ({
  focus: () => {
    calls.push(name)
    return true
  },
  focused: signal(false),
})

describe("ShellModel", () => {
  it("starts with the Mac sidebar width and keeps resizes and collapse per account", () => {
    const s = setup()
    expect(s.shell.split.size(SIDEBAR_PANE).peek()).toBe(240)
    s.shell.split.setSize(SIDEBAR_PANE, 300)
    s.shell.toggleSidebar()
    expect(s.shell.sidebarCollapsed.peek()).toBe(true)
    const stored = s.storage.getItem(layoutStorageKey(s.userId))
    expect(JSON.parse(stored!)).toEqual({ v: 1, split: { sizes: { sidebar: 300 }, collapsed: ["sidebar"] } })

    const again = setup(stored!)
    expect(again.shell.split.size(SIDEBAR_PANE).peek()).toBe(0)
    expect(again.shell.sidebarCollapsed.peek()).toBe(true)
    again.shell.toggleSidebar()
    expect(again.shell.split.size(SIDEBAR_PANE).peek()).toBe(300)
  })

  it("ignores an unreadable stored layout", () => {
    const s = setup("not json")
    expect(s.shell.split.size(SIDEBAR_PANE).peek()).toBe(240)
    const t = setup(JSON.stringify({ v: 99, split: { sizes: { sidebar: 10 } } }))
    expect(t.shell.split.size(SIDEBAR_PANE).peek()).toBe(240)
  })

  it("wires the session's commands to the shell: toggle sidebar, focus composer, quick search", () => {
    const s = setup()
    const calls: string[] = []
    s.shell.registerComposer(s.session.workspace.focusedPaneId.peek(), composer(calls, "composer"))
    s.session.registry.run(navigationCommandIds.toggleSidebar)
    expect(s.shell.sidebarCollapsed.peek()).toBe(true)
    s.session.registry.run(navigationCommandIds.focusComposer)
    expect(calls).toEqual(["composer"])
    s.session.registry.run(navigationCommandIds.quickSearch)
    expect(s.shell.toasts.toasts.peek().map((toast) => toast.id)).toEqual(["quick-search"])
  })

  it("focuses the focused pane's composer for type to focus and restore, and only that pane's", () => {
    const s = setup()
    const calls: string[] = []
    const first = s.session.workspace.focusedPaneId.peek()
    const unregister = s.shell.registerComposer(first, composer(calls, "first"))
    s.shell.registerComposer("other-pane", composer(calls, "other"))
    s.hooks()?.typeToFocus()
    s.hooks()?.restoreFocus()
    expect(calls).toEqual(["first", "first"])
    unregister()
    s.shell.registerTimeline(first, () => {
      calls.push("timeline")
      return true
    })
    s.hooks()?.restoreFocus()
    expect(calls).toEqual(["first", "first", "timeline"])
  })

  it("shows a collapsed sidebar before focusing it", () => {
    const s = setup()
    s.shell.toggleSidebar()
    expect(s.shell.focusSidebar()).toBe(true)
    expect(s.shell.sidebarCollapsed.peek()).toBe(false)
    expect(s.frames).toHaveLength(1)
  })

  const quickSearchShell = (load: () => Promise<(session: AccountSession) => QuickSearchWiring>) => {
    const time = manualTime()
    const harness = coreHarness(time)
    const session = new AccountSession({ userId: "7" as UserID, token: "t", connect: () => harness.connection, clock: time })
    const frames: (() => void)[] = []
    const shell = new ShellModel({
      runtime: { storage: memoryStorage(), attachShell: () => () => {} },
      session,
      toasts: new ToastQueue({ clock: createManualClock() }),
      nextFrame: (fn) => void frames.push(fn),
      quickSearch: load,
    })
    return { session, shell, frames }
  }

  it("loads Quick Search on the first Mod+K, opens it on the next frame, and disposes it with the shell", async () => {
    const calls: string[] = []
    const wiring = { open: () => void calls.push("open"), dispose: () => void calls.push("dispose") }
    let loads = 0
    const s = quickSearchShell(async () => {
      loads += 1
      return () => wiring as unknown as QuickSearchWiring
    })
    expect(s.shell.quickSearch.peek()).toBeUndefined()
    s.session.registry.run(navigationCommandIds.quickSearch)
    await microtasks()
    // Wired (the palette mounts), opened only once the frame after that commit runs.
    expect(s.shell.quickSearch.peek()).toBe(wiring)
    expect(calls).toEqual([])
    for (const frame of s.frames.splice(0)) frame()
    expect(calls).toEqual(["open"])
    // Loaded now: the next Mod+K opens at once, without another load.
    s.session.registry.run(navigationCommandIds.quickSearch)
    expect(calls).toEqual(["open", "open"])
    expect(loads).toBe(1)
    expect(s.shell.toasts.toasts.peek()).toEqual([])
    s.shell.dispose()
    expect(calls).toEqual(["open", "open", "dispose"])
  })

  it("a preload wires Quick Search without opening it", async () => {
    const calls: string[] = []
    const wiring = { open: () => void calls.push("open"), dispose: () => void calls.push("dispose") }
    const s = quickSearchShell(async () => () => wiring as unknown as QuickSearchWiring)
    await s.shell.loadQuickSearch()
    expect(s.shell.quickSearch.peek()).toBe(wiring)
    expect(calls).toEqual([])
    s.session.registry.run(navigationCommandIds.quickSearch)
    expect(calls).toEqual(["open"])
  })

  it("says so when Quick Search fails to load, and loads again on the next try", async () => {
    let fail = true
    const wiring = { open: () => {}, dispose: () => {} }
    const s = quickSearchShell(async () => {
      if (fail) throw new Error("offline")
      return () => wiring as unknown as QuickSearchWiring
    })
    s.session.registry.run(navigationCommandIds.quickSearch)
    await microtasks()
    expect(s.shell.toasts.toasts.peek().map((toast) => toast.title)).toEqual(["Quick search couldn't load"])
    fail = false
    s.session.registry.run(navigationCommandIds.quickSearch)
    await microtasks()
    expect(s.shell.quickSearch.peek()).toBe(wiring)
  })

  it("does not wire Quick Search after the shell is disposed", async () => {
    let resolve: ((wire: (session: AccountSession) => QuickSearchWiring) => void) | undefined
    const s = quickSearchShell(() => new Promise((done) => (resolve = done)))
    s.session.registry.run(navigationCommandIds.quickSearch)
    s.shell.dispose()
    let wired = false
    resolve?.(() => {
      wired = true
      return { open: () => {}, dispose: () => {} } as unknown as QuickSearchWiring
    })
    await microtasks()
    expect(wired).toBe(false)
    expect(s.shell.quickSearch.peek()).toBeUndefined()
  })

  it("detaches its hooks on dispose", () => {
    const s = setup()
    expect(s.hooks()).toBeDefined()
    s.shell.dispose()
    expect(s.hooks()).toBeUndefined()
    // The session's toggle no longer reaches the disposed shell.
    s.session.registry.run(navigationCommandIds.toggleSidebar)
    expect(s.shell.sidebarCollapsed.peek()).toBe(false)
  })
})
