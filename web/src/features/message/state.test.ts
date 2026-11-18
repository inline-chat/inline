import { describe, expect, it } from "vitest"
import { statePresentation } from "./state"

describe("statePresentation", () => {
  it("maps each state of an own message to the Mac glyph", () => {
    expect(statePresentation("sending", true)).toMatchObject({ glyph: "clock", tone: "muted" })
    expect(statePresentation("sent", true)).toMatchObject({ glyph: "check", tone: "muted" })
    expect(statePresentation("failed", true)).toMatchObject({ glyph: "warning", tone: "danger" })
  })

  it("never shows uncertain as failed or delivered", () => {
    const uncertain = statePresentation("uncertain", true)
    expect(uncertain?.glyph).toBe("unknown")
    expect(uncertain?.tone).toBe("muted")
    expect(uncertain?.glyph).not.toBe(statePresentation("sent", true)?.glyph)
    expect(uncertain?.glyph).not.toBe(statePresentation("failed", true)?.glyph)
    expect(uncertain?.glyph).not.toBe(statePresentation("sending", true)?.glyph)
    expect(uncertain?.label).not.toBe(statePresentation("sent", true)?.label)
  })

  it("shows nothing for messages from others", () => {
    for (const state of ["sending", "sent", "failed", "uncertain"] as const) {
      expect(statePresentation(state, false)).toBeUndefined()
    }
  })

  it("reads an unknown state from a newer core as uncertain", () => {
    expect(statePresentation("queued" as never, true)?.glyph).toBe("unknown")
  })

  it("gives every state its own label", () => {
    const labels = (["sending", "sent", "failed", "uncertain"] as const).map((state) => statePresentation(state, true)?.label)
    expect(new Set(labels).size).toBe(4)
  })
})
