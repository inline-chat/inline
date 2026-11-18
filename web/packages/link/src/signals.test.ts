import type { Command } from "@inline/core-protocol"
import { watchBrowserSignals } from "@inline/link"
import { VirtualClock } from "@inline/link/testing"
import { describe, expect, it } from "vitest"

const fakeWindow = (online: boolean) => Object.assign(new EventTarget(), { navigator: { onLine: online } })
const fakeDocument = (visibilityState: string) => Object.assign(new EventTarget(), { visibilityState })

describe("browser signals", () => {
  it("sends the current state, then online, visibility and wake changes, until stopped", () => {
    const posted: Command[] = []
    const win = fakeWindow(true)
    const doc = fakeDocument("visible")
    const clock = new VirtualClock()
    const stop = watchBrowserSignals(
      { post: (command) => posted.push(command) },
      { window: win, document: doc, clock, wakeCheckMs: 10_000, wakeGapMs: 30_000 },
    )
    const signals = () => posted.map((command) => (command.kind === "signal" ? command.signal : command))

    expect(signals()).toEqual([
      { kind: "online", online: true },
      { kind: "visibility", visible: true },
    ])

    win.dispatchEvent(new Event("offline"))
    doc.visibilityState = "hidden"
    doc.dispatchEvent(new Event("visibilitychange"))
    win.dispatchEvent(new Event("online"))
    expect(signals().slice(2)).toEqual([
      { kind: "online", online: false },
      { kind: "visibility", visible: false },
      { kind: "online", online: true },
    ])

    // Timers on time: no wake.
    clock.advance(50_000)
    expect(posted).toHaveLength(5)

    // The machine slept: the next check runs far later than scheduled.
    clock.jump(120_000)
    clock.advance(0)
    expect(signals().at(-1)).toEqual({ kind: "wake" })

    stop()
    win.dispatchEvent(new Event("offline"))
    expect(clock.pendingTimers).toBe(0)
    expect(signals().at(-1)).toEqual({ kind: "wake" })
  })

  it("does nothing outside a window", () => {
    const posted: Command[] = []
    const clock = new VirtualClock()
    const stop = watchBrowserSignals({ post: (command) => posted.push(command) }, { clock })
    clock.advance(100_000)
    stop()
    expect(posted).toEqual([])
    expect(clock.pendingTimers).toBe(0)
  })
})
