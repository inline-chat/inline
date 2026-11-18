import { describe, expect, it } from "vitest"
import { META_CACHE, shellCacheName } from "./protocol"
import { clearServiceWorkerCaches } from "./register"
import { FakeBrowser, type FakeWindow } from "./testing/fake-browser"
import { host, TEST_SHELL_POLICY, testBuild, type TestBuild } from "./testing/test-build"

const hello = (window: FakeWindow, build: TestBuild): void =>
  window.viewOf(window.controller)?.postMessage({ type: "inline-sw:hello", buildId: build.buildId })

/** A browser with build 1 installed and active, and one tab on it that said hello. */
const installed = async () => {
  const browser = new FakeBrowser()
  const b1 = testBuild(1)
  host(browser.network, b1)
  browser.deployScript(b1.config)
  const tab = await browser.openWindow("/")
  await browser.register()
  await browser.settle()
  hello(tab, b1)
  await browser.settle()
  return { browser, b1, tab }
}

/** Deploys build `n` and lets the browser find it. */
const deploy = async (browser: FakeBrowser, build: TestBuild): Promise<void> => {
  host(browser.network, build)
  browser.deployScript(build.config)
  await browser.track(browser.softUpdate())
  await browser.settle()
}

const precachedPaths = (build: TestBuild): string[] =>
  ["/", "/__inline-sw/complete", build.paths.css, build.paths.entry, build.paths.lazy, build.paths.shared, build.paths.wasm, build.paths.worker].sort()

describe("install", () => {
  it("precaches the shell and exactly the manifest's files into the build's cache", async () => {
    const { browser, b1 } = await installed()
    expect(browser.caches.names().filter((name) => name !== META_CACHE)).toEqual([shellCacheName(b1.buildId)])
    expect(browser.caches.paths(shellCacheName(b1.buildId))).toEqual(precachedPaths(b1))
    // No lab page, lab chunk or source map.
    expect(b1.config.assets.map((entry) => entry.url)).not.toContain("/assets/lab-b1.js")
    expect(b1.config.assets.map((entry) => entry.url)).not.toContain(`${b1.paths.entry}.map`)
  })

  it("keeps the shell's response headers but drops transfer headers", async () => {
    const { browser, b1 } = await installed()
    const shell = await browser.caches.match("https://app.test/", { cacheName: shellCacheName(b1.buildId) })
    expect(shell?.headers.get("x-frame-options")).toBe("DENY")
    expect(shell?.headers.get("content-encoding")).toBeNull()
    expect(shell?.redirected).toBe(false)
  })

  it("leaves no cache when a download fails, and installs on the next check", async () => {
    const browser = new FakeBrowser()
    const b1 = testBuild(1)
    host(browser.network, b1)
    browser.network.fail(b1.paths.wasm)
    browser.deployScript(b1.config)
    await browser.register()
    await browser.settle()
    expect(browser.workers[0]?.state).toBe("redundant")
    expect(browser.registration?.active).toBeNull()
    expect(browser.caches.names()).toEqual([])

    browser.network.heal(b1.paths.wasm)
    await browser.softUpdate()
    await browser.settle()
    expect(browser.registration?.active?.buildId).toBe(b1.buildId)
    expect(browser.caches.paths(shellCacheName(b1.buildId))).toEqual(precachedPaths(b1))
  })

  it("fails when the host serves bytes the manifest did not name", async () => {
    const browser = new FakeBrowser()
    const b1 = testBuild(1)
    host(browser.network, b1)
    // A stale edge still serves the previous shell at `/`.
    browser.network.serve("/", "<!doctype html><title>older shell</title>")
    browser.deployScript(b1.config)
    await browser.register()
    await browser.settle()
    expect(browser.workers[0]?.state).toBe("redundant")
    expect(browser.caches.names()).toEqual([])
  })

  it("deletes the partial cache when a write fails (quota)", async () => {
    const browser = new FakeBrowser()
    const b1 = testBuild(1)
    host(browser.network, b1)
    browser.caches.failWritesAfter(3)
    browser.deployScript(b1.config)
    await browser.register()
    await browser.settle()
    expect(browser.workers[0]?.state).toBe("redundant")
    expect(browser.caches.names()).toEqual([])
  })

  it("redoes an interrupted install from scratch", async () => {
    const browser = new FakeBrowser()
    const b1 = testBuild(1)
    host(browser.network, b1)
    // A previous attempt died after two writes: no completion marker.
    const leftover = await browser.caches.open(shellCacheName(b1.buildId))
    await leftover.put("https://app.test/assets/garbage.js", new Response("x"))
    await leftover.put(`https://app.test${b1.paths.entry}`, new Response("half"))
    browser.deployScript(b1.config)
    await browser.register()
    await browser.settle()
    expect(browser.caches.paths(shellCacheName(b1.buildId))).toEqual(precachedPaths(b1))
    const entry = await browser.caches.match(`https://app.test${b1.paths.entry}`, { cacheName: shellCacheName(b1.buildId) })
    expect(await entry?.text()).toBe(b1.files[b1.paths.entry])
  })

  it("takes over the first page without a reload, and never skips waiting on its own", async () => {
    const { browser, b1, tab } = await installed()
    // The first install has nothing to wait for and claims the open tab.
    expect(tab.controller?.buildId).toBe(b1.buildId)
    expect(browser.workers[0]?.skipWaitingCalled).toBe(false)

    await deploy(browser, testBuild(2))
    expect(browser.registration?.waiting?.buildId).toBe(testBuild(2).buildId)
    expect(browser.registration?.active?.buildId).toBe(b1.buildId)
    expect(browser.workers[1]?.skipWaitingCalled).toBe(false)
  })
})

describe("fetch", () => {
  it("starts offline: a deep link gets the shell, and every file comes from the cache", async () => {
    const { browser, b1 } = await installed()
    browser.network.online = false
    browser.network.take()

    const tab = await browser.openWindow("/c/123/m/9")
    expect(tab.document).toBe(b1.files["/index.html"])
    expect(await tab.text(b1.paths.entry)).toBe(b1.files[b1.paths.entry])
    expect(await tab.text(b1.paths.css)).toBe(b1.files[b1.paths.css])
    expect(await tab.text(b1.paths.lazy)).toBe(b1.files[b1.paths.lazy])
    // The core worker and the WASM it loads (the worker's own requests go
    // through the same service worker).
    expect(await tab.text(b1.paths.worker)).toBe(b1.files[b1.paths.worker])
    const wasm = await tab.fetch(b1.paths.wasm)
    expect(wasm.headers.get("content-type")).toBe("application/wasm")
    expect(new Uint8Array(await wasm.arrayBuffer())).toEqual(b1.files[b1.paths.wasm])
    expect(browser.network.take()).toEqual([])
  })

  it("leaves API, cross-origin, non-GET, ranged and query requests to the network", async () => {
    const { browser, tab } = await installed()
    browser.handled.length = 0
    await tab.fetch("/v1/getMe")
    await tab.fetch("/v1/sendMessage", { method: "POST", body: "{}" })
    await tab.fetch("https://api.inline.chat/v1/getChats")
    await tab.fetch("https://media.example.com/photo.jpg")
    await tab.fetch(testBuild(1).paths.entry, { headers: { range: "bytes=0-10" } })
    await tab.fetch(`${testBuild(1).paths.entry}?v=2`)
    expect(browser.handled).toEqual([
      "network GET /v1/getMe",
      "network POST /v1/sendMessage",
      "network GET https://api.inline.chat/v1/getChats",
      "network GET https://media.example.com/photo.jpg",
      `network GET ${testBuild(1).paths.entry}`,
      `network GET ${testBuild(1).paths.entry}?v=2`,
    ])

    browser.network.online = false
    await expect(tab.fetch("/v1/getMe")).rejects.toThrow("Failed to fetch")
  })

  it("does not answer navigations to files or denied paths with the shell", async () => {
    const { browser } = await installed()
    browser.handled.length = 0
    for (const path of ["/lab-sw.html", "/sw.js", "/robots.txt", "/__debug"]) await browser.openWindow(path)
    await browser.openWindow("/index.html")
    expect(browser.handled).toEqual([
      "network GET /lab-sw.html",
      "network GET /sw.js",
      "network GET /robots.txt",
      "network GET /__debug",
      "worker GET /index.html",
    ])
  })

  it("answers which build it is", async () => {
    const { browser, b1, tab } = await installed()
    const received: unknown[] = []
    tab.env({ now: () => 0, setTimeout: () => 0, clearTimeout: () => undefined }).container?.addEventListener(
      "message",
      (event) => received.push(event.data),
    )
    tab.viewOf(tab.controller)?.postMessage({ type: "inline-sw:which-build" })
    await browser.settle()
    expect(received).toEqual([{ type: "inline-sw:build", buildId: b1.buildId }])
  })
})

describe("integrity of cached responses", () => {
  /** What a one-time script on the origin could do: write its own response into the build's cache. */
  const plant = async (browser: FakeBrowser, build: TestBuild, path: string, body: string) => {
    const cache = await browser.caches.open(shellCacheName(build.buildId))
    await cache.put(`https://app.test${path}`, new Response(body, { headers: { "content-type": "text/html" } }))
  }
  const cachedText = async (browser: FakeBrowser, build: TestBuild, path: string) =>
    (await browser.caches.match(`https://app.test${path}`, { cacheName: shellCacheName(build.buildId) }))?.text()

  it("never serves a shell planted in its cache: the network answers and the cache is rebuilt", async () => {
    const { browser, b1 } = await installed()
    await plant(browser, b1, "/", "<script src=/evil.js></script>")
    const tab = await browser.openWindow("/")
    expect(tab.document).toBe(b1.files["/index.html"])
    await browser.settle()
    expect(await cachedText(browser, b1, "/")).toBe(b1.files["/index.html"])
    expect(browser.caches.paths(shellCacheName(b1.buildId))).toEqual(precachedPaths(b1))
  })

  it("offline, a planted shell is not served, and no other build's cache stands in for it", async () => {
    const { browser, b1 } = await installed()
    await plant(browser, b1, "/", "<script src=/evil.js></script>")
    // A cache named like an older build's, with a shell of its own.
    const older = await browser.caches.open(shellCacheName("2000-01-01T00:00:00.000Z"))
    await older.put("https://app.test/", new Response("<script src=/evil.js></script>"))
    browser.network.online = false
    await expect(browser.openWindow("/")).rejects.toThrow("Failed to fetch")
    await browser.caches.delete(shellCacheName(b1.buildId))
    await expect(browser.openWindow("/")).rejects.toThrow("Failed to fetch")
  })

  it("never serves a planted precached file: the network answers and the cache is rebuilt", async () => {
    const { browser, b1, tab } = await installed()
    await plant(browser, b1, b1.paths.entry, "globalThis.pwned = 1")
    expect(await tab.text(b1.paths.entry)).toBe(b1.files[b1.paths.entry])
    await browser.settle()
    expect(await cachedText(browser, b1, b1.paths.entry)).toBe(b1.files[b1.paths.entry])
  })

  it("serves the verified shell with the build's content policy as a header, beside the host's headers", async () => {
    const { browser, b1, tab } = await installed()
    browser.network.online = false
    const response = await browser.fetchVia(tab.controller, "/c/1", { navigate: true })
    expect(await response.text()).toBe(b1.files["/index.html"])
    expect(b1.config.shellPolicy).toBe(TEST_SHELL_POLICY)
    expect(response.headers.get("content-security-policy")).toBe(TEST_SHELL_POLICY)
    expect(response.headers.get("x-frame-options")).toBe("DENY")
  })

  it("keeps a policy the host already sends and adds the build's beside it", async () => {
    const browser = new FakeBrowser()
    const b1 = testBuild(1)
    host(browser.network, b1)
    browser.network.serve("/", b1.files["/index.html"] ?? "", {
      "content-type": "text/html",
      "content-security-policy": "frame-ancestors 'none'",
    })
    browser.deployScript(b1.config)
    const tab = await browser.openWindow("/")
    await browser.register()
    await browser.settle()
    const response = await browser.fetchVia(tab.controller ?? browser.registration?.active ?? null, "/", { navigate: true })
    expect(response.headers.get("content-security-policy")).toBe(`frame-ancestors 'none', ${TEST_SHELL_POLICY}`)
  })
})

describe("updates and version skew", () => {
  it("a new version waits while an old tab lives, and the old tab keeps its build", async () => {
    const { browser, b1, tab } = await installed()
    const b2 = testBuild(2)
    await deploy(browser, b2)
    expect(browser.registration?.waiting?.buildId).toBe(b2.buildId)
    expect(browser.caches.names().sort()).toEqual([META_CACHE, shellCacheName(b1.buildId), shellCacheName(b2.buildId)].sort())

    browser.network.online = false
    expect(await tab.text(b1.paths.lazy)).toBe(b1.files[b1.paths.lazy])
    // A new tab opened now still gets build 1: code is not swapped while build 1 runs.
    const second = await browser.openWindow("/chats")
    expect(second.document).toBe(b1.files["/index.html"])
  })

  it("applying the update moves every tab to the new worker; an old tab still gets its files", async () => {
    const { browser, b1, tab: oldTab } = await installed()
    const other = await browser.openWindow("/c/1")
    hello(other, b1)
    const b2 = testBuild(2)
    await deploy(browser, b2)
    const changes: string[] = []
    oldTab.env({ now: () => 0, setTimeout: () => 0, clearTimeout: () => undefined }).container?.addEventListener(
      "controllerchange",
      () => changes.push("old tab"),
    )

    // The user chose to update in the other tab.
    other.viewOf(browser.registration?.waiting ?? null)?.postMessage({ type: "inline-sw:skip-waiting" })
    await browser.settle()
    expect(browser.registration?.active?.buildId).toBe(b2.buildId)
    expect(oldTab.controller?.buildId).toBe(b2.buildId)
    expect(changes).toEqual(["old tab"])

    // The other tab reloads into build 2 and says so.
    const reloaded = await browser.reload(other)
    expect(reloaded.document).toBe(b2.files["/index.html"])
    hello(reloaded, b2)
    await browser.settle()

    // The old tab, still running build 1, lazy-loads offline: build 1's cache is kept for it.
    browser.network.online = false
    expect(await oldTab.text(b1.paths.lazy)).toBe(b1.files[b1.paths.lazy])
    expect(await oldTab.text(b1.paths.worker)).toBe(b1.files[b1.paths.worker])
    expect(browser.caches.names()).toContain(shellCacheName(b1.buildId))

    // Once it is gone, the next prune removes build 1.
    await browser.closeWindow(oldTab)
    hello(reloaded, b2)
    await browser.settle()
    expect(browser.caches.names().sort()).toEqual([META_CACHE, shellCacheName(b2.buildId)].sort())
  })

  it("deletes nothing while a living tab has not said which build it runs", async () => {
    const { browser, b1, tab } = await installed()
    const b2 = testBuild(2)
    await deploy(browser, b2)
    await browser.openWindow("/")
    tab.viewOf(browser.registration?.waiting ?? null)?.postMessage({ type: "inline-sw:skip-waiting" })
    await browser.settle()
    const result = await browser.registration?.active?.handle.prune()
    expect(result?.deferred).toBe(true)
    expect(browser.caches.names()).toContain(shellCacheName(b1.buildId))
  })

  it("never deletes a newer build's cache (a waiting worker's)", async () => {
    const { browser, b1 } = await installed()
    const b2 = testBuild(2)
    await deploy(browser, b2)
    const result = await browser.registration?.active?.handle.prune()
    expect(result?.deleted).toEqual([])
    expect(result?.kept.slice().sort()).toEqual([shellCacheName(b1.buildId), shellCacheName(b2.buildId)].sort())
  })

  it("activates once the last old tab closes, and removes the old cache", async () => {
    const { browser, b1, tab } = await installed()
    const b2 = testBuild(2)
    await deploy(browser, b2)
    await browser.closeWindow(tab)
    expect(browser.registration?.active?.buildId).toBe(b2.buildId)
    expect(browser.caches.names()).not.toContain(shellCacheName(b1.buildId))
    const next = await browser.openWindow("/")
    expect(next.document).toBe(b2.files["/index.html"])
  })

  it("serves a file both builds share from the new cache", async () => {
    const { browser, tab } = await installed()
    const b2 = testBuild(2)
    await deploy(browser, b2)
    tab.viewOf(browser.registration?.waiting ?? null)?.postMessage({ type: "inline-sw:skip-waiting" })
    await browser.settle()
    browser.network.online = false
    expect(await tab.text(b2.paths.shared)).toBe(b2.files[b2.paths.shared])
  })
})

describe("kill switch", () => {
  it("takes over without waiting, erases its caches only, unregisters, and leaves requests alone", async () => {
    const { browser, b1, tab } = await installed()
    const media = await browser.caches.open("inline-media-v1")
    await media.put("https://app.test/media/1", new Response("bytes"))

    await deploy(browser, testBuild(3, { killSwitch: true }))
    expect(tab.controller?.config.killSwitch).toBe(true)
    expect(browser.caches.names()).toEqual(["inline-media-v1"])
    expect(browser.liveRegistration()).toBeNull()

    browser.handled.length = 0
    expect(await tab.text(b1.paths.entry)).toBe(b1.files[b1.paths.entry])
    expect(browser.handled).toEqual([`network GET ${b1.paths.entry}`])
    browser.network.online = false
    await expect(tab.fetch(b1.paths.entry)).rejects.toThrow("Failed to fetch")
  })
})

describe("sign-out", () => {
  it("clearing the caches erases them; the worker refills its build in the background", async () => {
    const { browser, b1 } = await installed()
    expect(await clearServiceWorkerCaches(browser.caches)).toHaveLength(2)
    expect(browser.caches.names()).toEqual([])

    // Offline right after sign-out: nothing to start from.
    browser.network.online = false
    await expect(browser.openWindow("/")).rejects.toThrow("Failed to fetch")

    // Online: the shell comes from the network and the cache is rebuilt.
    browser.network.online = true
    const tab = await browser.openWindow("/")
    expect(tab.document).toBe(b1.files["/index.html"])
    await browser.settle()
    expect(browser.caches.paths(shellCacheName(b1.buildId))).toEqual(precachedPaths(b1))
  })
})
