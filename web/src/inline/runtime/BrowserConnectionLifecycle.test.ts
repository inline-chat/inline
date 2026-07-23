import { afterEach, describe, expect, it, vi } from "vitest"
import { BrowserConnectionLifecycle } from "./BrowserConnectionLifecycle"

const flush = async () => {
  await Promise.resolve()
  await Promise.resolve()
}

describe("BrowserConnectionLifecycle", () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("maps browser network and visibility hints to constraints", async () => {
    const setNetworkAvailable = vi.fn(async () => undefined)
    const setAppActive = vi.fn(async () => undefined)
    const lifecycle = new BrowserConnectionLifecycle({
      connection: {
        setNetworkAvailable,
        setAppActive,
        systemDidWake: vi.fn(async () => undefined),
      },
    })

    const detach = lifecycle.attach()
    window.dispatchEvent(new Event("offline"))
    window.dispatchEvent(new Event("online"))
    window.dispatchEvent(new Event("pagehide"))
    window.dispatchEvent(new Event("pageshow"))
    await flush()

    expect(setNetworkAvailable).toHaveBeenCalledWith(false)
    expect(setNetworkAvailable).toHaveBeenCalledWith(true)
    expect(setAppActive).toHaveBeenCalledWith(false)
    expect(setAppActive).toHaveBeenCalledWith(true)

    detach()
  })

  it("probes the connection when a bfcache page is restored", async () => {
    const systemDidWake = vi.fn(async () => undefined)
    const lifecycle = new BrowserConnectionLifecycle({
      connection: {
        setNetworkAvailable: vi.fn(async () => undefined),
        setAppActive: vi.fn(async () => undefined),
        systemDidWake,
      },
    })

    lifecycle.attach()
    window.dispatchEvent(
      new PageTransitionEvent("pageshow", {
        persisted: true,
      }),
    )
    await flush()

    expect(systemDidWake).toHaveBeenCalledTimes(1)
    lifecycle.detach()
  })

  it("detaches ownership only when the page is discarded", async () => {
    const onPageDiscard = vi.fn()
    const lifecycle = new BrowserConnectionLifecycle({
      connection: {
        setNetworkAvailable: vi.fn(async () => undefined),
        setAppActive: vi.fn(async () => undefined),
        systemDidWake: vi.fn(async () => undefined),
      },
      onPageDiscard,
    })

    lifecycle.attach()
    window.dispatchEvent(
      new PageTransitionEvent("pagehide", { persisted: true }),
    )
    expect(onPageDiscard).not.toHaveBeenCalled()

    window.dispatchEvent(
      new PageTransitionEvent("pagehide", { persisted: false }),
    )
    expect(onPageDiscard).toHaveBeenCalledOnce()
    lifecycle.detach()
  })

  it("removes every browser listener when detached", async () => {
    const setNetworkAvailable = vi.fn(async () => undefined)
    const lifecycle = new BrowserConnectionLifecycle({
      connection: {
        setNetworkAvailable,
        setAppActive: vi.fn(async () => undefined),
        systemDidWake: vi.fn(async () => undefined),
      },
    })

    lifecycle.attach()
    await flush()
    const callsAfterAttach = setNetworkAvailable.mock.calls.length
    lifecycle.detach()
    window.dispatchEvent(new Event("offline"))
    await flush()

    expect(setNetworkAvailable).toHaveBeenCalledTimes(
      callsAfterAttach,
    )
  })
})
