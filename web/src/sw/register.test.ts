import { createUpdateFeed } from "@inline/platform"
import { manualClock, type ManualClock } from "@inline/platform/testing"
import { describe, expect, it } from "vitest"
import { CLIENT_BUILDS_PATH, META_CACHE, shellCacheName } from "./protocol"
import {
  registerServiceWorker,
  type RegisterServiceWorkerOptions,
  type ServiceWorkerPageEnv,
  type ServiceWorkerStatus,
} from "./register"
import { FakeBrowser, type FakeWindow } from "./testing/fake-browser"
import { host, testBuild, type TestBuild } from "./testing/test-build"

const MINUTE = 60_000

interface Page {
  readonly window: FakeWindow
  readonly sw: ReturnType<typeof registerServiceWorker>
  readonly updater: ReturnType<typeof createUpdateFeed>["updater"]
  readonly clock: ManualClock
  readonly history: ServiceWorkerStatus[]
}

/** A tab running `build` with the real registration code. */
const startPage = (
  window: FakeWindow,
  build: TestBuild,
  options: Partial<RegisterServiceWorkerOptions> = {},
  env: Partial<ServiceWorkerPageEnv> = {},
): Page => {
  const clock = manualClock()
  const { updater, feed } = createUpdateFeed()
  const sw = registerServiceWorker({
    enabled: true,
    buildId: build.buildId,
    feed,
    env: window.env(clock, env),
    ...options,
  })
  const history: ServiceWorkerStatus[] = []
  sw.subscribe((status) => history.push(status))
  return { window, sw, updater, clock, history }
}

const browserWith = (build: TestBuild): FakeBrowser => {
  const browser = new FakeBrowser()
  host(browser.network, build)
  browser.deployScript(build.config)
  return browser
}

/** Build 1 installed through a first tab. */
const firstTab = async (options: Partial<RegisterServiceWorkerOptions> = {}) => {
  const b1 = testBuild(1)
  const browser = browserWith(b1)
  const page = startPage(await browser.openWindow("/"), b1, options)
  await browser.settle()
  return { browser, b1, page }
}

const deploy = (browser: FakeBrowser, build: TestBuild): void => {
  host(browser.network, build)
  browser.deployScript(build.config)
}

const recordedBuilds = async (browser: FakeBrowser): Promise<Record<string, string>> => {
  const response = await browser.caches.match(`https://app.test${CLIENT_BUILDS_PATH}`, { cacheName: META_CACHE })
  return response ? ((await response.json()) as Record<string, string>) : {}
}

const swChecks = (browser: FakeBrowser): number => browser.network.log.filter((record) => record.url === "/sw.js").length

describe("registerServiceWorker", () => {
  it("first install: takes control of the page without a reload and reports no update", async () => {
    const { browser, b1, page } = await firstTab()
    expect(page.window.registeredScripts).toEqual(["/sw.js"])
    expect(page.sw.status()).toMatchObject({ phase: "registered", controlled: true, pending: "none" })
    expect(page.updater.state.get()).toEqual({ status: "none" })
    expect(page.window.reloadRequests).toBe(0)
    // It told the worker which build it runs.
    expect(await recordedBuilds(browser)).toEqual({ [page.window.id]: b1.buildId })
  })

  it("reports a new build as available while it downloads and ready when it waits", async () => {
    const { browser, page } = await firstTab()
    const b2 = testBuild(2)
    deploy(browser, b2)
    await page.sw.checkForUpdate()
    await browser.settle()
    const updates = page.history.map((status) => status.update.status)
    expect(updates).toContain("available")
    expect(updates.indexOf("available")).toBeLessThan(updates.indexOf("ready"))
    expect(page.updater.state.get()).toEqual({ status: "ready", version: b2.buildId })
    expect(page.sw.status().pending).toBe("waiting")
  })

  it("learns the version of a worker that was already waiting when the tab opened", async () => {
    const { browser, b1, page } = await firstTab()
    const b2 = testBuild(2)
    deploy(browser, b2)
    await page.sw.checkForUpdate()
    await browser.settle()
    const later = startPage(await browser.openWindow("/"), b1)
    await browser.settle()
    expect(later.updater.state.get()).toEqual({ status: "ready", version: b2.buildId })
  })

  it("apply: the waiting worker takes over and this tab reloads once it is controlled", async () => {
    const { browser, page } = await firstTab()
    const b2 = testBuild(2)
    deploy(browser, b2)
    await page.sw.checkForUpdate()
    await browser.settle()
    expect(page.window.reloadRequests).toBe(0)

    page.updater.apply()
    await browser.settle()
    expect(browser.registration?.active?.buildId).toBe(b2.buildId)
    expect(page.window.reloadRequests).toBe(1)
    const reloaded = await browser.reload(page.window)
    expect(reloaded.document).toBe(b2.files["/index.html"])
  })

  it("does nothing on apply unless an update is ready", async () => {
    const { browser, page } = await firstTab()
    page.updater.apply()
    page.sw.applyUpdate()
    await browser.settle()
    expect(page.window.reloadRequests).toBe(0)
  })

  it("after another tab applied: reloads hidden idle tabs only, and keeps the old build's files", async () => {
    const { browser, b1, page: applying } = await firstTab()
    const visibleIdle = startPage(await browser.openWindow("/"), b1, { hasUnsavedWork: () => false })
    const hiddenIdle = startPage(await browser.openWindow("/", { visible: false }), b1, { hasUnsavedWork: () => false })
    const hiddenBusy = startPage(await browser.openWindow("/", { visible: false }), b1, { hasUnsavedWork: () => true })
    const hiddenUnknown = startPage(await browser.openWindow("/", { visible: false }), b1)
    await browser.settle()
    const b2 = testBuild(2)
    deploy(browser, b2)
    await applying.sw.checkForUpdate()
    await browser.settle()

    applying.updater.apply()
    await browser.settle()
    expect(applying.window.reloadRequests).toBe(1)
    expect(hiddenIdle.window.reloadRequests).toBe(1)
    expect(visibleIdle.window.reloadRequests).toBe(0)
    expect(hiddenBusy.window.reloadRequests).toBe(0)
    // Without a `hasUnsavedWork` answer a tab never reloads by itself.
    expect(hiddenUnknown.window.reloadRequests).toBe(0)
    expect(visibleIdle.sw.status().pending).toBe("activated-elsewhere")
    expect(visibleIdle.updater.state.get()).toEqual({ status: "ready", version: b2.buildId })

    // The tabs still on build 1 told the new worker, so its files stay.
    await browser.registration?.active?.handle.prune()
    expect(browser.caches.names()).toContain(shellCacheName(b1.buildId))
    browser.network.online = false
    expect(await visibleIdle.window.text(b1.paths.lazy)).toBe(b1.files[b1.paths.lazy])

    // The visible tab reloads when the user moves away from it.
    visibleIdle.window.setVisible(false)
    expect(visibleIdle.window.reloadRequests).toBe(1)
    hiddenBusy.window.setVisible(true)
    hiddenBusy.window.setVisible(false)
    expect(hiddenBusy.window.reloadRequests).toBe(0)

    // Apply in a tab whose worker already changed just reloads it.
    hiddenBusy.updater.apply()
    expect(hiddenBusy.window.reloadRequests).toBe(1)
  })

  it("checks for updates periodically and on focus, at most once per gap", async () => {
    const { browser, page } = await firstTab({ checkIntervalMs: 60 * MINUTE, minCheckGapMs: 5 * MINUTE })
    const initial = swChecks(browser)
    deploy(browser, testBuild(2))

    page.window.emit("focus")
    await browser.settle()
    expect(swChecks(browser)).toBe(initial)

    page.clock.advance(60 * MINUTE - 1)
    await browser.settle()
    expect(browser.registration?.waiting).toBeNull()
    page.clock.advance(1)
    await browser.settle()
    expect(swChecks(browser)).toBe(initial + 1)
    expect(page.updater.state.get().status).toBe("ready")

    page.clock.advance(5 * MINUTE)
    page.window.emit("focus")
    page.window.emit("online")
    await browser.settle()
    expect(swChecks(browser)).toBe(initial + 2)
  })

  it("ignores a failed update check (offline)", async () => {
    const { browser, page } = await firstTab()
    browser.network.online = false
    await page.sw.checkForUpdate()
    await browser.settle()
    expect(page.sw.status()).toMatchObject({ phase: "registered", update: { status: "none" } })
  })

  it("reloads anyway when the new worker does not take over after apply", async () => {
    const { browser, page } = await firstTab({ applyTimeoutMs: 10_000 })
    deploy(browser, testBuild(2))
    await page.sw.checkForUpdate()
    await browser.settle()
    browser.dropPageMessages = true
    page.updater.apply()
    await browser.settle()
    expect(page.window.reloadRequests).toBe(0)
    page.clock.advance(10_000)
    expect(page.window.reloadRequests).toBe(1)
  })

  it("when disabled, removes an existing worker and its caches", async () => {
    const { browser, b1 } = await firstTab()
    const devTab = await browser.openWindow("/")
    const dev = startPage(devTab, b1, { enabled: false })
    await browser.settle()
    expect(dev.sw.status().phase).toBe("disabled")
    expect(devTab.registeredScripts).toEqual([])
    expect(browser.liveRegistration()).toBeNull()
    expect(browser.caches.names()).toEqual([])
  })

  it("is unsupported without a secure context or a service worker container", async () => {
    const b1 = testBuild(1)
    const browser = browserWith(b1)
    const window = await browser.openWindow("/")
    expect(startPage(window, b1, {}, { secureContext: false }).sw.status().phase).toBe("unsupported")
    expect(startPage(window, b1, {}, { container: undefined }).sw.status().phase).toBe("unsupported")
    await browser.settle()
    expect(window.registeredScripts).toEqual([])
  })

  it("reports a registration that fails", async () => {
    const b1 = testBuild(1)
    // Nothing deployed at /sw.js: the script cannot be fetched.
    const browser = new FakeBrowser()
    host(browser.network, b1)
    const errors: unknown[] = []
    const page = startPage(await browser.openWindow("/"), b1, { onError: (error) => errors.push(error) })
    await browser.settle()
    expect(page.sw.status().phase).toBe("failed")
    expect(errors).toHaveLength(1)
  })

  it("registers the script URL the env turns it into (Trusted Types)", async () => {
    const b1 = testBuild(1)
    const browser = browserWith(b1)
    const trusted = { toString: () => "https://app.test/sw.js" }
    const page = startPage(await browser.openWindow("/"), b1, {}, { scriptUrl: () => trusted })
    await browser.settle()
    expect(page.window.registeredScripts).toEqual([trusted])
  })

  it("says hello again after a back-forward cache restore", async () => {
    const { browser, b1, page } = await firstTab()
    await browser.caches.delete(META_CACHE)
    page.window.emit("pageshow", { persisted: false })
    await browser.settle()
    expect(await recordedBuilds(browser)).toEqual({})
    page.window.emit("pageshow", { persisted: true })
    await browser.settle()
    expect(await recordedBuilds(browser)).toEqual({ [page.window.id]: b1.buildId })
  })

  it("dispose stops checks and detaches the apply handler", async () => {
    const { browser, page } = await firstTab()
    deploy(browser, testBuild(2))
    await page.sw.checkForUpdate()
    await browser.settle()
    page.sw.dispose()
    page.updater.apply()
    await browser.settle()
    expect(page.window.reloadRequests).toBe(0)
    expect(page.clock.pendingTimers()).toBe(0)
  })
})
