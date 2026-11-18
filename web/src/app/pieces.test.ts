import type { ChatID, MessageID, UserID } from "@inline/ids"
import { CommandRegistry, type Destination } from "@inline/view"
import { describe, expect, it } from "vitest"
import { buildDiagnostics } from "./diagnostics"
import { regionOf } from "./focus"
import { destinationDescription, paneViewKind } from "./pane-registry"
import { createBootMetrics, perfNames } from "./perf"
import { statusScreenText, statusSurface } from "./status"
import { fakePerformance, manualPaints } from "./test-fixtures"
import { UnsavedWork } from "./unsaved-work"
import { readDemoParams } from "./demo-params"
import { FALLBACK_DEVICE_NAME, SettingsPaneModel } from "./settings-pane"
import { Warmup } from "./warmup"

const chat = "5" as ChatID

describe("pane registry", () => {
  it("shows chats, messages and threads in the chat pane", () => {
    expect(paneViewKind({ kind: "chat", chatId: chat })).toBe("chat")
    expect(paneViewKind({ kind: "message", chatId: chat, messageId: "9" as MessageID })).toBe("chat")
    expect(paneViewKind({ kind: "thread", parentChatId: "1" as ChatID, threadId: chat })).toBe("chat")
  })

  it("shows settings for every settings page", () => {
    expect(paneViewKind({ kind: "settings" })).toBe("settings")
    expect(paneViewKind({ kind: "settings", page: "appearance" })).toBe("settings")
  })

  it("shows the empty pane for nothing selected and the unbuilt pane for everything else", () => {
    expect(paneViewKind({ kind: "empty" })).toBe("empty")
    const others: Destination[] = [
      { kind: "user", userId: "3" as UserID },
      { kind: "search", query: "x" },
      { kind: "allChats" },
      { kind: "archived" },
      { kind: "newThread" },
      { kind: "createSpace" },
      { kind: "joinSpace", handle: "acme" },
      { kind: "invite", token: "secret-token" },
    ]
    for (const destination of others) expect(paneViewKind(destination)).toBe("unbuilt")
  })

  it("never shows an invitation's token", () => {
    expect(destinationDescription({ kind: "invite", token: "secret-token" })).not.toContain("secret")
    expect(destinationDescription({ kind: "settings", page: "appearance" })).toBe("/settings/appearance")
  })
})

describe("status surfaces", () => {
  it("puts each status where the guides say", () => {
    expect(statusSurface("outdated")).toEqual({ kind: "screen", screen: "outdated" })
    expect(statusSurface("superseded")).toEqual({ kind: "screen", screen: "superseded" })
    expect(statusSurface("failed")).toEqual({ kind: "screen", screen: "failed" })
    expect(statusSurface("signedOut")).toEqual({ kind: "screen", screen: "signedOut" })
    // While the core erases a signing-out account, the whole shell is the signing-out screen, with no action.
    expect(statusSurface("ready", { signingOut: true })).toEqual({ kind: "screen", screen: "signingOut" })
    expect(statusSurface("ready", {})).toEqual({ kind: "none" })
    expect(statusScreenText.signingOut.action).toBeUndefined()
    expect(statusSurface("storageFull")).toEqual({ kind: "banner", banner: "storageFull" })
    expect(statusSurface("storageNotKept")).toEqual({ kind: "banner", banner: "storageNotKept" })
    // Connection states replace the chat header's subtitle, never a banner.
    expect(statusSurface("connecting")).toEqual({ kind: "header" })
    expect(statusSurface("updating")).toEqual({ kind: "header" })
    expect(statusSurface("waitingForNetwork")).toEqual({ kind: "header" })
    expect(statusSurface("starting")).toEqual({ kind: "starting" })
    expect(statusSurface("ready")).toEqual({ kind: "none" })
  })
})

describe("boot metrics", () => {
  it("records each boot moment once, as a mark and a measure from navigation start", () => {
    const perf = fakePerformance()
    const paints = manualPaints()
    const metrics = createBootMetrics({ performance: perf, afterPaint: paints.afterPaint })
    perf.set(12)
    metrics.mark("bootStart")
    metrics.mark("bootStart")
    perf.set(40)
    metrics.markAfterPaint("shellPaint")
    metrics.markAfterPaint("shellPaint")
    expect(paints.pending()).toBe(1)
    perf.set(55)
    paints.paint()
    expect(perf.marks).toEqual([perfNames.bootStart, perfNames.shellPaint])
    expect(metrics.measures()).toEqual([
      { name: perfNames.bootStart, ms: 12 },
      { name: perfNames.shellPaint, ms: 55 },
    ])
  })

  it("measures a chat switch from its start to the paint after its rows, keeping the latest", () => {
    const perf = fakePerformance()
    const paints = manualPaints()
    const metrics = createBootMetrics({ performance: perf, afterPaint: paints.afterPaint })
    for (const [start, end] of [
      [100, 130],
      [200, 210],
    ] as const) {
      perf.set(start)
      metrics.chatSwitchStarted()
      metrics.chatSwitchPainted()
      perf.set(end)
      paints.paint()
    }
    expect(metrics.measures()).toEqual([{ name: perfNames.chatSwitch, ms: 10 }])
  })

  it("works without a performance object", () => {
    const metrics = createBootMetrics({ performance: undefined, afterPaint: (fn) => fn() })
    metrics.mark("coreReady")
    expect(metrics.has("coreReady")).toBe(true)
  })
})

describe("unsaved work", () => {
  it("counts sends in flight and registered sources, and flushes", async () => {
    const work = new UnsavedWork()
    expect(work.has()).toBe(false)
    let release!: () => void
    const send = new Promise<void>((resolve) => (release = resolve))
    work.track(send)
    expect(work.has()).toBe(true)
    release()
    await send
    await Promise.resolve()
    expect(work.has()).toBe(false)
    let text = "draft"
    const unregister = work.register(() => text.length > 0)
    expect(work.has()).toBe(true)
    text = ""
    expect(work.has()).toBe(false)
    unregister()
    let flushed = 0
    work.onFlush(() => void (flushed += 1))
    work.onFlush(() => {
      throw new Error("one flush fails")
    })
    work.flush()
    expect(flushed).toBe(1)
  })
})

describe("focus regions", () => {
  it("reads the nearest data-focus-region", () => {
    const at = (value: string | null) => ({ closest: () => (value === null ? null : { getAttribute: () => value }) })
    expect(regionOf(at("composer"))).toBe("composer")
    expect(regionOf(at("timeline"))).toBe("timeline")
    expect(regionOf(at("other"))).toBeUndefined()
    expect(regionOf(at(null))).toBeUndefined()
    expect(regionOf(null)).toBeUndefined()
    expect(regionOf({})).toBeUndefined()
  })
})

describe("diagnostics", () => {
  it("carries states, IDs and log events, and nothing it was not given", () => {
    const text = buildDiagnostics({
      buildId: "2026-11-17T00:00:00.000Z",
      phase: "signedIn",
      status: "failed",
      core: { kind: "core", phase: "failed", connection: "idle", storage: "persistent", buildId: "b", failure: "opfs-busy" },
      role: "leader",
      panes: ["/c/5"],
      measures: [{ name: perfNames.coreReady, ms: 120 }],
      logs: [{ timestamp: 1, sequence: 0, level: "warn", scope: "App", event: "service worker" }],
      now: 0,
    })
    const report = JSON.parse(text) as Record<string, unknown>
    expect(report).toMatchObject({
      build: "2026-11-17T00:00:00.000Z",
      app: { phase: "signedIn", status: "failed", role: "leader" },
      core: { phase: "failed", failure: "opfs-busy" },
      panes: ["/c/5"],
    })
    expect(text).not.toContain("token")
  })
})

describe("demo parameter", () => {
  it("reads the scale, seed and storage, and ignores anything else", () => {
    expect(readDemoParams("?demo=small")).toEqual({ scale: "small" })
    expect(readDemoParams("?demo=large&seed=4&storage=memory")).toEqual({ scale: "large", seed: 4, storage: "memory" })
    expect(readDemoParams("?demo=huge")).toBeUndefined()
    expect(readDemoParams("?demo=medium&seed=-1&storage=disk")).toEqual({ scale: "medium" })
    expect(readDemoParams("")).toBeUndefined()
  })
})

describe("warmup", () => {
  const harness = () => {
    const paints = manualPaints()
    const idle: (() => boolean | void)[] = []
    const errors: unknown[] = []
    const warmup = new Warmup({
      afterPaint: paints.afterPaint,
      idle: (task) => void idle.push(task),
      onError: (error) => void errors.push(error),
    })
    /** Run idle slices until none is queued. */
    const drain = () => {
      while (idle.length > 0) {
        const task = idle.shift()!
        if (task()) idle.push(task)
      }
    }
    return { warmup, paints, idle, errors, drain }
  }

  it("runs nothing before the first paint, then one task per idle slice", () => {
    const h = harness()
    const ran: string[] = []
    h.warmup.add(() => void ran.push("a"))
    h.warmup.add(() => void ran.push("b"))
    expect(h.idle).toHaveLength(0)
    h.warmup.painted()
    expect(h.idle).toHaveLength(0)
    h.paints.paint()
    expect(h.idle).toHaveLength(1)
    const first = h.idle.shift()!
    // Another task is queued: the slice asks to run again.
    expect(first()).toBe(true)
    expect(ran).toEqual(["a"])
    h.idle.push(first)
    h.drain()
    expect(ran).toEqual(["a", "b"])
    // Added after the paint: runs on the next idle slice.
    h.warmup.add(() => void ran.push("c"))
    h.drain()
    expect(ran).toEqual(["a", "b", "c"])
    expect(h.warmup.pending).toBe(0)
  })

  it("does not wait for an idle slice that never comes: the timer runs the next task after maxWaitMs", () => {
    const paints = manualPaints()
    const idle: (() => boolean | void)[] = []
    const timers: { fn: () => void; ms: number; cancelled: boolean }[] = []
    const warmup = new Warmup({
      afterPaint: paints.afterPaint,
      idle: (task) => void idle.push(task),
      timeout: (fn, ms) => {
        const timer = { fn, ms, cancelled: false }
        timers.push(timer)
        return () => void (timer.cancelled = true)
      },
      maxWaitMs: 500,
    })
    const ran: string[] = []
    warmup.add(() => void ran.push("a"))
    warmup.add(() => void ran.push("b"))
    warmup.painted()
    paints.paint()
    const live = () => timers.filter((timer) => !timer.cancelled)
    expect(live().map((timer) => timer.ms)).toEqual([500])
    // The page stays busy: no idle slice. The timer runs one task and arms again.
    live()[0]!.fn()
    expect(ran).toEqual(["a"])
    const second = live().at(-1)!
    second.fn()
    expect(ran).toEqual(["a", "b"])
    // The idle slice that finally comes finds nothing left and stops.
    expect(idle.shift()!()).toBe(false)
    expect(warmup.pending).toBe(0)
  })

  it("reports a failing task and keeps going", async () => {
    const h = harness()
    const ran: string[] = []
    h.warmup.add(() => Promise.reject(new Error("offline")))
    h.warmup.add(() => {
      throw new Error("broken")
    })
    h.warmup.add(() => void ran.push("ok"))
    h.warmup.painted()
    h.paints.paint()
    h.drain()
    await Promise.resolve()
    expect(ran).toEqual(["ok"])
    expect(h.errors).toHaveLength(2)
  })
})

describe("settings pane model", () => {
  const options = (deviceName: () => Promise<string>, opened: unknown[]) => ({
    workspace: { openInPane: (paneId: string, destination: Destination) => void opened.push([paneId, destination]) } as never,
    paneId: "p1" as never,
    me: { get: () => undefined, peek: () => undefined },
    signOut: async () => {},
    deviceName,
    registry: new CommandRegistry(),
    platform: { os: "mac", surface: "browser" } as const,
  })

  it("opens pages in its pane and builds the account once the device name is known", async () => {
    const opened: unknown[] = []
    const model = new SettingsPaneModel(options(async () => "Chrome on macOS", opened))
    expect(model.account.peek()).toBeUndefined()
    await Promise.resolve()
    await Promise.resolve()
    expect(model.account.peek()?.deviceName).toBe("Chrome on macOS")
    model.openPage("appearance")
    expect(opened).toEqual([["p1", { kind: "settings", page: "appearance" }]])
  })

  it("falls back to a plain device name when the sign-in flows cannot load", async () => {
    const model = new SettingsPaneModel(options(() => Promise.reject(new Error("offline")), []))
    await Promise.resolve()
    await Promise.resolve()
    expect(model.account.peek()?.deviceName).toBe(FALLBACK_DEVICE_NAME)
  })
})
