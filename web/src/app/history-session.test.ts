import { createMemoryHistory } from "@inline/view"
import { describe, expect, it } from "vitest"
import { createSessionHistory, HISTORY_SESSION_KEY } from "./history-session"
import { memoryStorage } from "./test-fixtures"

const counter = () => {
  let n = 0
  return () => `s${++n}`
}

describe("history entries from before a sign-out", () => {
  it("read as `/` on Back and Forward and when read, and are rewritten to `/` in place", () => {
    const memory = createMemoryHistory("/")
    const history = createSessionHistory(memory, { newSession: counter() })
    const heard: string[] = []
    history.listen((location) => void heard.push(location.path))
    history.push("/c/1", { inline: { seq: 1 } })
    history.push("/c/2/m/9", { inline: { seq: 2 } })
    // The binding's own stamp is kept beside the session.
    expect(memory.current().state).toEqual({ inline: { seq: 2 }, inlineSession: "s1" })

    history.endSession()
    expect(history.session()).toBe("s2")
    expect(memory.current().path).toBe("/")
    history.push("/c/7", { inline: { seq: 3 } })

    memory.back()
    expect(heard).toEqual(["/"])
    expect(memory.current().path).toBe("/")
    memory.back()
    expect(heard).toEqual(["/", "/"])
    expect(memory.current().path).toBe("/")
    expect(history.current()).toEqual({ path: "/", state: { inlineSession: "s2" } })
    // The new session's own entry is reached as it was written.
    memory.forward()
    memory.forward()
    expect(heard.at(-1)).toBe("/c/7")
  })

  it("leaves entries the app never wrote alone (a typed URL, the first load)", () => {
    const memory = createMemoryHistory("/c/5")
    const history = createSessionHistory(memory, { newSession: counter() })
    expect(history.current().path).toBe("/c/5")
    history.endSession()
    memory.push("/c/6", null)
    const heard: string[] = []
    history.listen((location) => void heard.push(location.path))
    memory.back()
    memory.forward()
    expect(heard).toEqual(["/", "/c/6"])
  })

  it("keeps its session across a reload (sessionStorage), or adopts the entry it loaded on", () => {
    const storage = memoryStorage()
    const memory = createMemoryHistory("/")
    const first = createSessionHistory(memory, { storage, newSession: counter() })
    first.push("/c/1", null)
    first.endSession()
    first.push("/c/2", null)
    expect(storage.getItem(HISTORY_SESSION_KEY)).toBe("s2")
    // A reload: the same tab's storage.
    const reloaded = createSessionHistory(memory, { storage, newSession: () => "fresh" })
    expect(reloaded.current().path).toBe("/c/2")
    memory.back()
    expect(reloaded.current().path).toBe("/")
    // Without storage: the session of the entry the page loaded on.
    const loaded = createMemoryHistory("/")
    loaded.push("/c/3", { inlineSession: "old" })
    const adopted = createSessionHistory(loaded, { newSession: () => "fresh" })
    expect(adopted.session()).toBe("old")
    expect(adopted.current().path).toBe("/c/3")
  })
})
