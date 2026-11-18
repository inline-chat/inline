import { describe, expect, test } from "vitest"
import { createBrowserHistory, createMemoryHistory, type BrowserWindowLike } from "./history"

describe("memory history", () => {
  test("push, replace and go behave like a browser's session history", () => {
    const history = createMemoryHistory("/a")
    const heard: string[] = []
    const stop = history.listen((location) => heard.push(location.path))
    history.push("/b", { n: 1 })
    history.push("/c", null)
    history.back()
    expect(history.current()).toEqual({ path: "/b", state: { n: 1 } })
    history.replace("/b2", { n: 2 })
    history.push("/d", null)
    expect(history.entries().map((e) => e.path)).toEqual(["/a", "/b2", "/d"])
    history.go(-2)
    history.go(-1) // Outside the stack: ignored, like a browser.
    history.go(5)
    expect(history.current().path).toBe("/a")
    stop()
    history.forward()
    expect(heard).toEqual(["/b", "/a"])
  })
})

/** A window with just enough of the History API, recording calls. Popstate is fired by hand. */
const fakeWindow = () => {
  const calls: string[] = []
  const location = { pathname: "/c/1", search: "?x=1" }
  const listeners = new Set<(event: { state: unknown }) => void>()
  const win: BrowserWindowLike & { pop(path: string, state: unknown): void } = {
    history: {
      state: null as unknown,
      pushState(state, _unused, url) {
        calls.push(`push ${url}`)
        this.state = state
        location.pathname = url ?? ""
      },
      replaceState(state, _unused, url) {
        calls.push(`replace ${url}`)
        this.state = state
        location.pathname = url ?? ""
      },
      go(delta) {
        calls.push(`go ${delta}`)
      },
    } as BrowserWindowLike["history"] & { state: unknown },
    location,
    addEventListener: (_type, listener) => void listeners.add(listener),
    removeEventListener: (_type, listener) => void listeners.delete(listener),
    pop(path, state) {
      ;(win.history as { state: unknown }).state = state
      location.pathname = path
      location.search = ""
      for (const listener of listeners) listener({ state })
    },
  }
  return { win, calls, listenerCount: () => listeners.size }
}

describe("browser history", () => {
  test("reads the location and state of the injected window", () => {
    const { win } = fakeWindow()
    const history = createBrowserHistory(win)
    expect(history.current()).toEqual({ path: "/c/1?x=1", state: null })
  })

  test("writes through the History API and hears popstate", () => {
    const { win, calls, listenerCount } = fakeWindow()
    const history = createBrowserHistory(win)
    const heard: unknown[] = []
    const stop = history.listen((location) => heard.push(location))
    history.push("/c/2", { a: 1 })
    history.replace("/c/3", { a: 2 })
    history.go(-1)
    win.pop("/c/9", { b: 1 })
    expect(calls).toEqual(["push /c/2", "replace /c/3", "go -1"])
    expect(heard).toEqual([{ path: "/c/9", state: { b: 1 } }])
    stop()
    expect(listenerCount()).toBe(0)
  })
})
