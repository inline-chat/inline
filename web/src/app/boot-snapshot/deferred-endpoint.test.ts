import { scriptedEndpoint } from "@inline/reactive/testing"
import { describe, expect, it } from "vitest"
import { DeferredEndpoint } from "./deferred-endpoint"
import { PENDING_TOKEN } from "./hinted-auth"
import { uid } from "./test-support"

describe("DeferredEndpoint", () => {
  it("queues commands until attached, then sends them in order with the confirmed session", () => {
    const deferred = new DeferredEndpoint()
    deferred.post({ kind: "hello", buildId: "b", protocol: 0 })
    deferred.post({ kind: "session", action: "start", session: { userId: uid(7), token: PENDING_TOKEN } })
    deferred.post({ kind: "subscribe", sub: 1, query: { kind: "core" } })
    const core = scriptedEndpoint()
    expect(core.posted).toEqual([])
    deferred.attach(core, { userId: uid(7), token: "t7" })
    expect(core.posted).toEqual([
      { kind: "hello", buildId: "b", protocol: 0 },
      { kind: "session", action: "start", session: { userId: uid(7), token: "t7" } },
      { kind: "subscribe", sub: 1, query: { kind: "core" } },
    ])
    deferred.post({ kind: "unsubscribe", sub: 1 })
    expect(core.posted.at(-1)).toEqual({ kind: "unsubscribe", sub: 1 })
  })

  it("never forwards a stand-in session for another user", () => {
    const deferred = new DeferredEndpoint()
    deferred.post({ kind: "session", action: "start", session: { userId: uid(7), token: PENDING_TOKEN } })
    const core = scriptedEndpoint()
    deferred.attach(core, { userId: uid(8), token: "t8" })
    expect(core.posted).toEqual([])
  })

  it("forwards the core's messages once attached and drops everything when closed first", () => {
    const deferred = new DeferredEndpoint()
    const seen: string[] = []
    deferred.subscribe((message) => void seen.push(message.kind))
    deferred.post({ kind: "session", action: "signOut" })
    const core = scriptedEndpoint()
    deferred.close()
    deferred.attach(core, { userId: uid(7), token: "t7" })
    core.deliver({ kind: "snapshot", snapshot: { revision: 1, rows: [], lists: [], resources: [] } })
    expect(core.posted).toEqual([])
    expect(seen).toEqual([])

    const live = new DeferredEndpoint()
    live.subscribe((message) => void seen.push(message.kind))
    live.attach(core, { userId: uid(7), token: "t7" })
    core.deliver({ kind: "snapshot", snapshot: { revision: 2, rows: [], lists: [], resources: [] } })
    expect(seen).toEqual(["snapshot"])
  })
})
