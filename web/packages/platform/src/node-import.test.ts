// Runs in plain Node (the package default environment), not happy-dom.
import { afterEach, describe, expect, it, vi } from "vitest"

const BROWSER_GLOBALS = [
  "window",
  "document",
  "navigator",
  "location",
  "Notification",
  "localStorage",
  "sessionStorage",
  "indexedDB",
  "matchMedia",
  "requestAnimationFrame",
  "showSaveFilePicker",
  "history",
  "screen",
  "self",
] as const

describe("importing the package", () => {
  const saved = new Map<string, PropertyDescriptor | undefined>()

  afterEach(() => {
    for (const [name, descriptor] of saved) {
      if (descriptor) Object.defineProperty(globalThis, name, descriptor)
      else delete (globalThis as Record<string, unknown>)[name]
    }
    saved.clear()
  })

  it("touches no browser global, in the index or the testing entry", async () => {
    const touched: string[] = []
    for (const name of BROWSER_GLOBALS) {
      saved.set(name, Object.getOwnPropertyDescriptor(globalThis, name))
      Object.defineProperty(globalThis, name, {
        configurable: true,
        get() {
          touched.push(name)
          return undefined
        },
      })
    }

    vi.resetModules()
    const index = await import("./index")
    const testing = await import("./testing/index")

    expect(touched).toEqual([])
    expect(typeof index.createWebPlatform).toBe("function")
    expect(typeof testing.createFakePlatform).toBe("function")

    // The trap works: reading a global is recorded.
    void (globalThis as { document?: unknown }).document
    expect(touched).toEqual(["document"])
  })

  it("lets the pure parts run in Node", async () => {
    const { decideMessageNotification, createBadgeController, badgeLabel } = await import("./index")
    expect(badgeLabel(120)).toBe("99+")
    expect(typeof createBadgeController).toBe("function")
    expect(
      decideMessageNotification({
        outgoing: false,
        newlyInserted: true,
        unread: true,
        dateSeconds: 100,
        nowMs: 100_000,
        viewingConversation: false,
        chatMode: "global",
        globalMode: "all",
        directMessage: true,
        mentionsMe: false,
      }).notify,
    ).toBe(true)
  })

  it("fails clearly when the web platform is created without a window", async () => {
    const { createWebPlatform } = await import("./index")
    expect(() => createWebPlatform({ isSafeExternalUrl: () => true })).toThrow(/needs a window/)
  })
})
