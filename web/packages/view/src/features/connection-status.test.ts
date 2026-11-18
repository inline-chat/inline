import { describe, expect, it } from "vitest"
import type { ConnectionState } from "@inline/core-protocol"
import { manualTime, signal } from "@inline/reactive"
import { chatSubtitle, createConnectionDisplay, sessionStatus } from "./connection-status"
import { coreResource } from "./test-support"

const setup = () => {
  const time = manualTime()
  const connection = signal<ConnectionState | undefined>(undefined)
  const display = createConnectionDisplay({ connection, clock: time })
  return { time, connection, display, shown: () => display.displayed.peek() }
}

describe("connection display (rule 15)", () => {
  it("shows connecting at once on a cold start, and hides on connected", () => {
    const s = setup()
    expect(s.shown()).toBeUndefined()
    s.connection.set("connecting")
    expect(s.shown()).toBe("connecting")
    s.connection.set("updating")
    expect(s.shown()).toBe("updating")
    s.connection.set("connected")
    expect(s.shown()).toBeUndefined()
  })

  it("shows a reconnect only after it has lasted 1 s", () => {
    const s = setup()
    s.connection.set("connected")
    s.connection.set("connecting")
    expect(s.shown()).toBeUndefined()
    s.time.advance(999)
    expect(s.shown()).toBeUndefined()
    s.time.advance(1)
    expect(s.shown()).toBe("connecting")
    // While shown, changes show at once.
    s.connection.set("waitingForNetwork")
    expect(s.shown()).toBe("waitingForNetwork")
    s.connection.set("connected")
    expect(s.shown()).toBeUndefined()
  })

  it("never shows a reconnect that finishes within 1 s, and shows the latest state when the delay ends", () => {
    const s = setup()
    s.connection.set("updating") // reaching updating also ends the cold start
    s.connection.set("connected")
    s.connection.set("connecting")
    s.time.advance(600)
    s.connection.set("connected")
    s.time.advance(1000)
    expect(s.shown()).toBeUndefined()

    s.connection.set("connecting")
    s.time.advance(500)
    s.connection.set("waitingForNetwork")
    s.time.advance(499)
    expect(s.shown()).toBeUndefined()
    s.time.advance(1)
    expect(s.shown()).toBe("waitingForNetwork")
  })

  it("stops its timer when disposed", () => {
    const s = setup()
    s.connection.set("connected")
    s.connection.set("connecting")
    s.display.dispose()
    s.time.advance(2000)
    expect(s.shown()).toBeUndefined()
  })
})

describe("sessionStatus", () => {
  it("orders phase, storage and connection", () => {
    expect(sessionStatus(undefined, undefined)).toBe("starting")
    expect(sessionStatus(coreResource({ phase: "starting" }), "connecting")).toBe("starting")
    expect(sessionStatus(coreResource({ phase: "outdated" }), undefined)).toBe("outdated")
    expect(sessionStatus(coreResource({ phase: "superseded" }), undefined)).toBe("superseded")
    expect(sessionStatus(coreResource({ phase: "failed", failure: "x" }), undefined)).toBe("failed")
    expect(sessionStatus(coreResource({ phase: "signedOut" }), undefined)).toBe("signedOut")
    expect(sessionStatus(coreResource({ storage: "full" }), "connecting")).toBe("storageFull")
    expect(sessionStatus(coreResource({ storage: "memory" }), "connecting")).toBe("connecting")
    expect(sessionStatus(coreResource({ storage: "memory" }), undefined)).toBe("storageNotKept")
    expect(sessionStatus(coreResource(), undefined)).toBe("ready")
  })

  it("puts connection before typing and bot status in the subtitle", () => {
    expect(chatSubtitle({ connection: "connecting", typing: "Ada is typing", isDirect: true, peerIsBot: true })).toEqual({
      kind: "connection",
      state: "connecting",
    })
    expect(chatSubtitle({ connection: undefined, typing: "Ada is typing", isDirect: true })).toEqual({
      kind: "typing",
      text: "Ada is typing",
    })
    expect(chatSubtitle({ connection: undefined, isDirect: true, peerIsBot: true })).toEqual({ kind: "bot" })
    expect(chatSubtitle({ connection: undefined, isDirect: false, peerIsBot: true })).toEqual({ kind: "none" })
  })
})
