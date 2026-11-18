import { createFakePlatform } from "@inline/platform/testing"
import { signal } from "@inline/reactive"
import { describe, expect, it } from "vitest"
import { BoundToggle, ClearMediaAction, clearMediaStatusText, refreshEstimateOnShow } from "./controls"
import { memoryPreferencesStorage, PreferencesStore } from "./preferences"

describe("BoundToggle", () => {
  it("shows the setting, writes through, and follows changes from elsewhere", () => {
    const store = new PreferencesStore({ storage: memoryPreferencesStorage() })
    const bound = new BoundToggle(store.spellCheck, (on) => store.setSpellCheck(on))
    expect(bound.toggle.pressed.peek()).toBe(true)
    bound.toggle.toggle()
    expect(store.spellCheck.peek()).toBe(false)
    store.setSpellCheck(true)
    expect(bound.toggle.pressed.peek()).toBe(true)
    bound.dispose()
    store.setSpellCheck(false)
    expect(bound.toggle.pressed.peek()).toBe(true)
  })

  it("springs back when the write is refused", () => {
    const source = signal(false)
    const bound = new BoundToggle(source, () => {})
    bound.toggle.toggle()
    expect(bound.toggle.pressed.peek()).toBe(false)
    bound.dispose()
  })

  it("can start disabled", () => {
    const bound = new BoundToggle(signal(true), () => {}, { disabled: true })
    bound.toggle.toggle()
    expect(bound.toggle.pressed.peek()).toBe(true)
    bound.dispose()
  })
})

describe("ClearMediaAction", () => {
  it("is unavailable without a handler", async () => {
    const action = new ClearMediaAction({})
    expect(action.available).toBe(false)
    await action.run()
    expect(action.status.peek()).toBe("idle")
  })

  it("runs once at a time, reports the result and refreshes the estimate", async () => {
    let release: () => void = () => {}
    let clears = 0
    let refreshes = 0
    const action = new ClearMediaAction({
      clear: () => {
        clears++
        return new Promise<void>((resolve) => {
          release = resolve
        })
      },
      refresh: async () => {
        refreshes++
      },
    })
    const first = action.run()
    void action.run()
    expect(action.status.peek()).toBe("clearing")
    expect(clears).toBe(1)
    release()
    await first
    expect(action.status.peek()).toBe("cleared")
    expect(refreshes).toBe(1)
    expect(clearMediaStatusText("cleared")).toBe("Cached media cleared.")
  })

  it("reports a failure", async () => {
    const action = new ClearMediaAction({
      clear: () => {
        throw new Error("nope")
      },
    })
    await action.run()
    expect(action.status.peek()).toBe("failed")
  })
})

describe("refreshEstimateOnShow", () => {
  it("asks for a fresh estimate when attached", async () => {
    const fake = createFakePlatform()
    let calls = 0
    const storage = fake.platform.storage
    if (!storage.available) throw new Error("expected storage")
    const counting = { ...storage, refreshEstimate: async () => void calls++ }
    refreshEstimateOnShow(counting).attach({} as HTMLElement)
    expect(calls).toBe(1)
    fake.dispose()
  })
})
