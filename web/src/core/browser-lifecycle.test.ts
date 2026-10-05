import { afterEach, describe, expect, it, vi } from "vitest"
import { BrowserLifecycle } from "./browser-lifecycle"

describe("browser connection hints", () => {
  afterEach(() => {
    vi.useRealTimers()
    vi.unstubAllGlobals()
  })

  it("establishes constraints before start, probes on foreground/restore, and detaches listeners", async () => {
    vi.useFakeTimers()
    const browserWindow = Object.assign(new EventTarget(), { setInterval, clearInterval })
    const browserDocument = Object.assign(new EventTarget(), { hidden: true })
    vi.stubGlobal("window", browserWindow)
    vi.stubGlobal("document", browserDocument)
    vi.stubGlobal("navigator", { onLine: false })
    const connection = {
      setNetworkAvailable: vi.fn(async (_available: boolean) => {}),
      setAppActive: vi.fn(async (_active: boolean) => {}),
      systemDidWake: vi.fn(async () => {}),
    }
    const onError = vi.fn()
    const discard = vi.fn()
    const lifecycle = new BrowserLifecycle(connection, onError, discard)
    await lifecycle.attach()
    expect(connection.setNetworkAvailable).toHaveBeenLastCalledWith(false)
    expect(connection.setAppActive).toHaveBeenLastCalledWith(false)
    browserDocument.hidden = false
    browserDocument.dispatchEvent(new Event("visibilitychange"))
    expect(connection.systemDidWake).toHaveBeenCalledTimes(1)
    browserWindow.dispatchEvent(Object.assign(new Event("pageshow"), { persisted: true }))
    expect(connection.systemDidWake).toHaveBeenCalledTimes(2)
    browserWindow.dispatchEvent(new Event("offline"))
    expect(connection.setNetworkAvailable).toHaveBeenLastCalledWith(false)
    browserWindow.dispatchEvent(Object.assign(new Event("pagehide"), { persisted: true }))
    expect(discard).not.toHaveBeenCalled()
    browserWindow.dispatchEvent(Object.assign(new Event("pagehide"), { persisted: false }))
    expect(discard).toHaveBeenCalledTimes(1)
    await lifecycle.detach()
    browserDocument.dispatchEvent(new Event("resume"))
    expect(connection.systemDidWake).toHaveBeenCalledTimes(2)
    expect(onError).not.toHaveBeenCalled()
    expect(vi.getTimerCount()).toBe(0)
  })

  it("treats elapsed sleep as a wake hint only while the page is visible", async () => {
    vi.useFakeTimers()
    const browserWindow = Object.assign(new EventTarget(), { setInterval, clearInterval })
    const browserDocument = Object.assign(new EventTarget(), { hidden: true })
    vi.stubGlobal("window", browserWindow)
    vi.stubGlobal("document", browserDocument)
    vi.stubGlobal("navigator", { onLine: true })
    const connection = {
      setNetworkAvailable: vi.fn(async () => {}),
      setAppActive: vi.fn(async () => {}),
      systemDidWake: vi.fn(async () => {}),
    }
    const lifecycle = new BrowserLifecycle(connection, vi.fn(), vi.fn())
    await lifecycle.attach()
    vi.setSystemTime(Date.now() + 120_000)
    await vi.advanceTimersByTimeAsync(15_000)
    expect(connection.systemDidWake).not.toHaveBeenCalled()
    browserDocument.hidden = false
    vi.setSystemTime(Date.now() + 120_000)
    await vi.advanceTimersByTimeAsync(15_000)
    expect(connection.systemDidWake).toHaveBeenCalledTimes(1)
    await lifecycle.detach()
  })
})
