// @vitest-environment happy-dom
import { beforeEach, describe, expect, it } from "vitest"
import { createWebTitleAndBadge } from "./badge"
import { canvasFaviconRenderer } from "./favicon"
import { deferredFavicon, flush, makeTestEnv } from "./web-env.fixture"

const iconLink = () => document.querySelector('link[rel~="icon"]') as HTMLLinkElement | null

beforeEach(() => {
  document.head.replaceChildren()
  document.title = "Inline"
})

describe("web title and badge", () => {
  it("prefixes the title with the debounced count and keeps the base title", async () => {
    const t = makeTestEnv()
    const { badge, setTitle, title } = createWebTitleAndBadge(t.env)
    setTitle("General · Inline")
    expect(document.title).toBe("General · Inline")
    badge.set(3)
    expect(document.title).toBe("General · Inline")
    t.clock.advance(500)
    expect(document.title).toBe("(3) General · Inline")
    expect(badge.count.get()).toBe(3)
    setTitle("Design · Inline")
    expect(title.get()).toBe("Design · Inline")
    expect(document.title).toBe("(3) Design · Inline")
    badge.set(150, { immediate: true })
    expect(document.title).toBe("(99+) Design · Inline")
    badge.set(0)
    expect(document.title).toBe("Design · Inline")
    await flush()
  })

  it("draws the favicon and restores the original on zero", async () => {
    document.head.append(Object.assign(document.createElement("link"), { rel: "icon", href: "/icon.png" }))
    const t = makeTestEnv()
    const { badge } = createWebTitleAndBadge(t.env)
    badge.set(2, { immediate: true })
    await flush()
    expect(iconLink()?.href).toBe("data:image/png;label=2")
    badge.set(0)
    expect(iconLink()?.href).toBe("http://localhost:3000/icon.png")
  })

  it("creates an icon link when the page has none", () => {
    const t = makeTestEnv()
    createWebTitleAndBadge(t.env)
    expect(iconLink()?.href).toBe("http://localhost:3000/favicon.ico")
  })

  it("keeps the latest favicon when renders finish out of order", async () => {
    const { renderer, calls } = deferredFavicon()
    const t = makeTestEnv({ favicon: renderer })
    const { badge } = createWebTitleAndBadge(t.env)
    badge.set(3, { immediate: true })
    badge.set(5, { immediate: true })
    expect(calls.map((c) => c.label)).toEqual(["3", "5"])
    calls[1]?.resolve("data:five")
    calls[0]?.resolve("data:three")
    await flush()
    expect(iconLink()?.href).toBe("data:five")
  })

  it("ignores a render that finishes after the count went to zero", async () => {
    const { renderer, calls } = deferredFavicon()
    const t = makeTestEnv({ favicon: renderer })
    const { badge } = createWebTitleAndBadge(t.env)
    badge.set(3, { immediate: true })
    badge.set(0)
    calls[0]?.resolve("data:three")
    await flush()
    expect(iconLink()?.href).toBe("http://localhost:3000/favicon.ico")
  })

  it("without a canvas keeps the title prefix and leaves the icon alone", () => {
    const t = makeTestEnv({ favicon: null })
    const { badge } = createWebTitleAndBadge(t.env)
    badge.set(4, { immediate: true })
    expect(document.title).toBe("(4) Inline")
    expect(iconLink()).toBeNull()
  })

  it("uses the Badging API where it exists and tolerates its rejection", async () => {
    const t = makeTestEnv()
    const { badge } = createWebTitleAndBadge(t.env)
    badge.set(2, { immediate: true })
    badge.set(0)
    expect(t.navigator.badgeCalls).toEqual([2, "clear"])
    const rejecting = makeTestEnv()
    const nav = rejecting.navigator as { setAppBadge: unknown }
    nav.setAppBadge = () => Promise.reject(new Error("not installed"))
    createWebTitleAndBadge(rejecting.env).badge.set(1, { immediate: true })
    await flush()
    expect(document.title).toBe("(1) Inline")
  })

  it("dispose restores the base title and icon and drops a pending increase", async () => {
    const t = makeTestEnv()
    const tb = createWebTitleAndBadge(t.env)
    tb.badge.set(2, { immediate: true })
    await flush()
    tb.badge.set(9)
    tb.dispose()
    t.clock.advance(1000)
    expect(document.title).toBe("Inline")
    expect(iconLink()?.href).toBe("http://localhost:3000/favicon.ico")
  })
})

describe("canvas favicon renderer", () => {
  it("is skipped where there is no 2D canvas (happy-dom)", () => {
    expect(canvasFaviconRenderer(document)).toBeNull()
  })

  it("draws the base icon and the label into a PNG data URL", async () => {
    const ops: string[] = []
    const context = {
      clearRect: () => ops.push("clear"),
      drawImage: () => ops.push("image"),
      beginPath: () => {},
      arc: () => ops.push("arc"),
      fill: () => {},
      fillText: (text: string) => ops.push(`text:${text}`),
      fillStyle: "",
      font: "",
      textAlign: "",
      textBaseline: "",
    }
    const fakeDocument = {
      createElement(tag: string) {
        if (tag === "canvas") {
          return { width: 0, height: 0, getContext: () => context, toDataURL: () => "data:image/png;base64,AAAA" }
        }
        const image = {
          onload: null as (() => void) | null,
          onerror: null as (() => void) | null,
          set src(_value: string) {
            queueMicrotask(() => image.onload?.())
          },
        }
        return image
      },
    }
    const renderer = canvasFaviconRenderer(fakeDocument)
    expect(await renderer?.render("/favicon.ico", "99+")).toBe("data:image/png;base64,AAAA")
    expect(ops).toEqual(["clear", "image", "arc", "text:99+"])
  })

  it("draws the badge alone when the base icon fails to load", async () => {
    const ops: string[] = []
    const fakeDocument = {
      createElement(tag: string) {
        if (tag === "canvas") {
          return {
            width: 0,
            height: 0,
            getContext: () => ({
              clearRect: () => {},
              drawImage: () => ops.push("image"),
              beginPath: () => {},
              arc: () => ops.push("arc"),
              fill: () => {},
              fillText: () => {},
            }),
            toDataURL: () => "data:x",
          }
        }
        const image = {
          onload: null as (() => void) | null,
          onerror: null as (() => void) | null,
          set src(_value: string) {
            queueMicrotask(() => image.onerror?.())
          },
        }
        return image
      },
    }
    expect(await canvasFaviconRenderer(fakeDocument)?.render("/missing.ico", "1")).toBe("data:x")
    expect(ops).toEqual(["arc"])
  })
})
