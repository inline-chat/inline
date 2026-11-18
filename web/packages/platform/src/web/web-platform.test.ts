// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import type { FreezeEvent, PageHideEvent, PersistentStorage } from "../platform"
import type { WebEnv } from "./env"
import { createWebFiles, DOWNLOAD_URL_LIFETIME_MS } from "./files"
import { createWebPlatform } from "./index"
import { detectOperatingSystem, webPlatformInfo } from "./info"
import { createWebLifecycle } from "./lifecycle"
import { createWebLinks } from "./links"
import { createWebStorage, promptsForPersistence } from "./storage"
import { CHROME_UA, FIREFOX_UA, flush, makeTestEnv } from "./web-env.fixture"

// Compile-time check: the real DOM objects satisfy the injected shapes.
export const realDomSatisfiesWebEnv = (w: Window, d: Document, n: Navigator): Partial<WebEnv> => ({
  window: w,
  document: d,
  navigator: n,
})

beforeEach(() => {
  document.head.replaceChildren()
  document.body.replaceChildren()
  document.title = "Inline"
})

describe("info", () => {
  const cases: [string, Parameters<typeof detectOperatingSystem>[0], string][] = [
    ["client hints macOS", { userAgent: "x", onLine: true, userAgentData: { platform: "macOS" } }, "mac"],
    ["client hints Windows", { userAgent: "x", onLine: true, userAgentData: { platform: "Windows" } }, "windows"],
    ["Chrome on Mac", { userAgent: CHROME_UA, onLine: true }, "mac"],
    ["iPad desktop UA", { userAgent: CHROME_UA, onLine: true, maxTouchPoints: 5 }, "ios"],
    ["Firefox on Linux", { userAgent: FIREFOX_UA, onLine: true }, "linux"],
    ["Windows", { userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64)", onLine: true }, "windows"],
    ["ChromeOS", { userAgent: "Mozilla/5.0 (X11; CrOS x86_64 14541.0.0)", onLine: true }, "chromeos"],
    ["Android", { userAgent: "Mozilla/5.0 (Linux; Android 14; Pixel 8)", onLine: true }, "android"],
    ["iPhone", { userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)", onLine: true }, "ios"],
    ["unknown", { userAgent: "curl/8", onLine: true }, "unknown"],
  ]
  it.each(cases)("%s", (_name, navigator, os) => {
    expect(detectOperatingSystem(navigator)).toBe(os)
  })

  it("is a web tab, with Cmd on Apple systems and Ctrl elsewhere", () => {
    expect(webPlatformInfo({ userAgent: CHROME_UA, onLine: true })).toEqual({
      kind: "web",
      os: "mac",
      shortcutModifier: "meta",
      surface: "tab",
    })
    expect(webPlatformInfo({ userAgent: FIREFOX_UA, onLine: true }).shortcutModifier).toBe("ctrl")
  })
})

describe("links", () => {
  it("opens only URLs that pass the injected check, with noopener and noreferrer", () => {
    const t = makeTestEnv()
    const links = createWebLinks(t.env, (url) => url.startsWith("https:"))
    expect(links.openExternal("javascript:alert(1)")).toBe(false)
    expect(links.openExternal("https://example.com/a")).toBe(true)
    expect(t.opened).toEqual([{ url: "https://example.com/a", target: "_blank", features: "noopener,noreferrer" }])
  })

  it("reports the page URL as the initial deep link and never fires later ones", () => {
    const t = makeTestEnv()
    const links = createWebLinks(t.env, () => true)
    expect(links.initialDeepLink).toBe("http://localhost:3000/")
    expect(typeof links.onDeepLink(() => {})).toBe("function")
  })
})

describe("files", () => {
  afterEach(() => {
    vi.restoreAllMocks()
    delete (window as { showSaveFilePicker?: unknown }).showSaveFilePicker
  })

  it("downloads through a link without a save dialog, and revokes the URL later", async () => {
    const t = makeTestEnv()
    const clicked: { href: string; download: string }[] = []
    vi.spyOn(HTMLAnchorElement.prototype, "click").mockImplementation(function (this: HTMLAnchorElement) {
      clicked.push({ href: this.href, download: this.download })
    })
    const files = createWebFiles(t.env)
    expect(await files.save(new Blob(["x"]), "notes.txt")).toBe("downloaded")
    expect(clicked).toEqual([{ href: "blob:test/1", download: "notes.txt" }])
    expect(document.body.querySelector("a")).toBeNull()
    t.clock.advance(DOWNLOAD_URL_LIFETIME_MS - 1)
    expect(t.revoked).toEqual([])
    t.clock.advance(1)
    expect(t.revoked).toEqual(["blob:test/1"])
  })

  it("writes through the save dialog where it exists", async () => {
    const t = makeTestEnv()
    const written: Blob[] = []
    let closed = false
    const picker = vi.fn(async () => ({
      createWritable: async () => ({
        write: async (blob: Blob) => void written.push(blob),
        close: async () => {
          closed = true
        },
      }),
    }))
    Object.assign(window, { showSaveFilePicker: picker })
    const blob = new Blob(["x"])
    expect(await createWebFiles(t.env).save(blob, "a.png")).toBe("saved")
    expect(picker).toHaveBeenCalledWith({ suggestedName: "a.png" })
    expect(written).toEqual([blob])
    expect(closed).toBe(true)
  })

  it("reports a dismissed dialog as cancelled", async () => {
    const t = makeTestEnv()
    Object.assign(window, {
      showSaveFilePicker: async () => {
        throw Object.assign(new Error("aborted"), { name: "AbortError" })
      },
    })
    expect(await createWebFiles(t.env).save(new Blob(["x"]), "a")).toBe("cancelled")
  })

  it("falls back to a download when the dialog is refused", async () => {
    const t = makeTestEnv()
    vi.spyOn(HTMLAnchorElement.prototype, "click").mockImplementation(() => {})
    Object.assign(window, {
      showSaveFilePicker: async () => {
        throw Object.assign(new Error("no activation"), { name: "SecurityError" })
      },
    })
    expect(await createWebFiles(t.env).save(new Blob(["x"]), "a")).toBe("downloaded")
  })

  it("fails when writing fails", async () => {
    const t = makeTestEnv()
    Object.assign(window, {
      showSaveFilePicker: async () => ({
        createWritable: async () => {
          throw new Error("disk full")
        },
      }),
    })
    expect(await createWebFiles(t.env).save(new Blob(["x"]), "a")).toBe("failed")
  })

  it("reveal is desktop only", () => {
    expect(createWebFiles(makeTestEnv().env).reveal).toEqual({ available: false, reason: "desktop-only" })
  })
})

describe("storage", () => {
  const manager = (persisted: boolean) => {
    const calls = { persist: 0 }
    return {
      calls,
      storage: {
        persisted: async () => persisted,
        persist: async () => {
          calls.persist++
          persisted = true
          return true
        },
        estimate: async () => ({ usage: 10, quota: 100 }),
      },
    }
  }

  const create = (userAgent: string, storage: ReturnType<typeof manager>["storage"]) => {
    const capability = createWebStorage(makeTestEnv({ userAgent, storage }).env)
    if (!capability.available) throw new Error("expected storage")
    return capability as PersistentStorage
  }

  it("is unavailable without a storage manager", () => {
    expect(createWebStorage(makeTestEnv({ storage: null }).env).available).toBe(false)
  })

  it("reports persisted state and the estimate as signals", async () => {
    const s = create(CHROME_UA, manager(false).storage)
    expect(s.persisted.get()).toBeNull()
    await flush()
    expect(s.persisted.get()).toBe(false)
    expect(s.estimate.get()).toEqual({ usage: 10, quota: 100 })
  })

  it("asks for persistence where it does not prompt", async () => {
    const m = manager(false)
    const s = create(CHROME_UA, m.storage)
    expect(s.canRequestSilently).toBe(true)
    expect(await s.requestPersistence()).toBe(true)
    expect(m.calls.persist).toBe(1)
    expect(s.persisted.get()).toBe(true)
  })

  it("does not ask in Firefox, which prompts", async () => {
    const m = manager(false)
    const s = create(FIREFOX_UA, m.storage)
    expect(s.canRequestSilently).toBe(false)
    expect(await s.requestPersistence()).toBe(false)
    expect(m.calls.persist).toBe(0)
    expect(promptsForPersistence(FIREFOX_UA)).toBe(true)
    expect(promptsForPersistence(CHROME_UA)).toBe(false)
  })

  it("does not ask again when already persisted", async () => {
    const m = manager(true)
    expect(await create(CHROME_UA, m.storage).requestPersistence()).toBe(true)
    expect(m.calls.persist).toBe(0)
  })
})

describe("lifecycle", () => {
  const setup = () => {
    const t = makeTestEnv()
    const { lifecycle, dispose } = createWebLifecycle(t.env)
    const freezes: FreezeEvent[] = []
    const hides: PageHideEvent[] = []
    const wakes: number[] = []
    lifecycle.freezes.subscribe((e) => freezes.push(e))
    lifecycle.onPageHide((e) => hides.push(e))
    lifecycle.onWake((e) => wakes.push(e.gapMs))
    return { t, lifecycle, dispose, freezes, hides, wakes }
  }

  it("follows visibility, focus and online state", () => {
    const { t, lifecycle } = setup()
    expect([lifecycle.visible.get(), lifecycle.focused.get(), lifecycle.online.get()]).toEqual([true, true, true])
    t.setHasFocus(false)
    t.setVisibility("hidden")
    expect([lifecycle.visible.get(), lifecycle.focused.get()]).toEqual([false, false])
    t.setHasFocus(true)
    t.setVisibility("visible")
    expect([lifecycle.visible.get(), lifecycle.focused.get()]).toEqual([true, true])
    window.dispatchEvent(new Event("blur"))
    expect(lifecycle.focused.get()).toBe(false)
    window.dispatchEvent(new Event("focus"))
    expect(lifecycle.focused.get()).toBe(true)
    window.dispatchEvent(new Event("offline"))
    expect(lifecycle.online.get()).toBe(false)
    window.dispatchEvent(new Event("online"))
    expect(lifecycle.online.get()).toBe(true)
  })

  it("reports freeze and resume once each, including the back-forward cache", () => {
    const { freezes, hides } = setup()
    document.dispatchEvent(new Event("freeze"))
    window.dispatchEvent(Object.assign(new Event("pagehide"), { persisted: true }))
    window.dispatchEvent(Object.assign(new Event("pageshow"), { persisted: true }))
    document.dispatchEvent(new Event("resume"))
    expect(freezes).toEqual(["freeze", "resume"])
    expect(hides).toEqual([{ persisted: true }])
  })

  it("a plain page hide is not a freeze", () => {
    const { freezes, hides } = setup()
    window.dispatchEvent(new Event("pagehide"))
    expect(hides).toEqual([{ persisted: false }])
    expect(freezes).toEqual([])
  })

  it("detects a sleep from the timer gap", () => {
    const { t, wakes } = setup()
    t.clock.advance(60_000)
    expect(wakes).toEqual([])
    t.clock.sleep(20 * 60_000)
    expect(wakes).toHaveLength(1)
  })

  it("checks for a wake as soon as the page becomes visible", () => {
    const { t, wakes } = setup()
    // Freeze the timer by moving time without running it, then show the page.
    const now = t.clock.now()
    vi.spyOn(t.clock, "now").mockReturnValue(now + 30 * 60_000)
    t.setVisibility("visible")
    expect(wakes).toEqual([30 * 60_000])
  })

  it("dispose removes listeners and timers", () => {
    const { t, lifecycle, dispose, freezes } = setup()
    dispose()
    window.dispatchEvent(new Event("offline"))
    document.dispatchEvent(new Event("freeze"))
    expect(lifecycle.online.get()).toBe(true)
    expect(freezes).toEqual([])
    expect(t.clock.pendingTimers()).toBe(0)
  })
})

describe("createWebPlatform", () => {
  it("wires every capability and marks desktop-only ones unavailable", () => {
    const t = makeTestEnv()
    const platform = createWebPlatform({ env: t.env, isSafeExternalUrl: () => true })
    expect(platform.info.kind).toBe("web")
    expect(platform.notifications.available).toBe(true)
    expect(platform.storage.available).toBe(true)
    for (const capability of [
      platform.spellcheck,
      platform.tray,
      platform.launchAtLogin,
      platform.globalShortcut,
      platform.window.newWindow,
      platform.window.alwaysOnTop,
      platform.window.titleBarOverlay,
      platform.files.reveal,
    ]) {
      expect(capability).toEqual({ available: false, reason: "desktop-only" })
    }
    platform.dispose()
  })

  it("composes the window title with the badge and restores it on dispose", () => {
    const t = makeTestEnv()
    const platform = createWebPlatform({ env: t.env, isSafeExternalUrl: () => true })
    platform.window.setTitle("Inbox · Inline")
    platform.badge.set(5)
    t.clock.advance(500)
    expect(document.title).toBe("(5) Inbox · Inline")
    platform.dispose()
    expect(document.title).toBe("Inbox · Inline")
    expect(t.clock.pendingTimers()).toBe(0)
  })

  it("exposes the update feed for the service worker glue", () => {
    const t = makeTestEnv()
    const platform = createWebPlatform({ env: t.env, isSafeExternalUrl: () => true })
    let reloads = 0
    platform.updates.setApplyHandler(() => reloads++)
    platform.updates.report({ status: "ready", version: "1.2.3" })
    expect(platform.updater.state.get()).toEqual({ status: "ready", version: "1.2.3" })
    platform.updater.apply()
    expect(reloads).toBe(1)
    platform.dispose()
  })
})
