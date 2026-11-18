import type { Command, Intent } from "@inline/core-protocol"
import {
  type InProcessCore,
  type LinkRole,
  SIGN_OUT_SHUTDOWN_TIMEOUT_MS,
  START_FAILURE,
  connectCore,
  inProcessCore,
  linkNames,
} from "@inline/link"
import { FakeCore, FakeDurable, type FakeTab, FakeWorld, RecordingUi } from "@inline/link/testing"
import { Log } from "@inline/log"
import { describe, expect, it } from "vitest"

type ChatId = Extract<Intent, { kind: "sendText" }>["chatId"]
const chat = "9" as ChatId
const windowQuery = { kind: "chatWindow", chatId: chat, anchor: "latest" } as const
const account = { origin: "https://api.inline.test", userId: "7" }
const names = linkNames(account)
const quiet = new Log("Link", { sink: false })

const send = (tx: string): Command => ({
  kind: "intent",
  tx,
  intent: { kind: "sendText", chatId: chat, clientKey: tx, text: tx },
})

type Tab = {
  tab: FakeTab
  linked: ReturnType<typeof connectCore>
  ui: RecordingUi
  cores: FakeCore[]
  handles: InProcessCore[]
  roles: LinkRole[]
}

const open = (
  world: FakeWorld,
  durable: FakeDurable,
  id: string,
  build = "2026-11-17.1",
  options: { failStarts?: number } = {},
): Tab => {
  let failStarts = options.failStarts ?? 0
  const tab = world.tab(id)
  const cores: FakeCore[] = []
  const handles: InProcessCore[] = []
  const linked = connectCore({
    account,
    buildId: build,
    locks: tab.locks,
    channels: tab.channels,
    clock: tab.clock,
    lifecycle: tab.lifecycle,
    contextId: id,
    log: quiet,
    startCore: () => {
      if (failStarts > 0) {
        failStarts -= 1
        throw new TypeError("This document requires 'TrustedScriptURL' assignment.")
      }
      const handle = inProcessCore(
        () => {
          const core = new FakeCore(durable, { buildId: build })
          cores.push(core)
          return core
        },
        { log: quiet },
      )
      handles.push(handle)
      return handle
    },
  })
  tab.onKill(() => {
    for (const core of cores) core.kill()
  })
  const roles: LinkRole[] = []
  linked.onRole((role) => roles.push(role))
  return { tab, linked, ui: new RecordingUi(linked), cores, handles, roles }
}

const intentsFor = (durable: FakeDurable, tx: string) =>
  durable.cores.flatMap((core) => core.commandsOf("intent")).filter((command) => command.tx === tx)

describe("connectCore", () => {
  it("elects one leader; a follower reaches its core with isolated sub IDs", async () => {
    const world = new FakeWorld()
    const durable = new FakeDurable()
    const a = open(world, durable, "a")
    const b = open(world, durable, "b")
    await world.settle()

    expect(a.linked.role).toBe("leader")
    expect(b.linked.role).toBe("follower")
    expect(durable.cores).toHaveLength(1)
    expect(world.lockHolder(names.locks.leader)).toBe("a")

    a.linked.post({ kind: "subscribe", sub: 1, query: { kind: "core" } })
    b.linked.post({ kind: "subscribe", sub: 1, query: windowQuery })
    b.linked.post(send("t1"))
    await world.settle()

    expect(a.ui.phase(1)).toBe("ready")
    expect(a.ui.list(1)).toBeUndefined()
    expect(a.ui.settled).toEqual([])
    expect(b.ui.list(1)).toHaveLength(1)
    expect(b.ui.resources.get(1)).toBeUndefined()
    expect(b.ui.settledFor("t1")).toEqual(["accepted"])
    expect(a.ui.errors).toEqual([])
    expect(b.ui.errors).toEqual([])
  })

  it("two contexts starting at once end with exactly one leader", async () => {
    const world = new FakeWorld()
    const durable = new FakeDurable()
    const tabs = ["a", "b", "c", "d"].map((id) => open(world, durable, id))
    await world.settle()
    expect(tabs.filter((tab) => tab.linked.role === "leader")).toHaveLength(1)
    expect(tabs.filter((tab) => tab.linked.role === "follower")).toHaveLength(3)
    expect(durable.cores).toHaveLength(1)
  })

  for (const ending of ["closes", "is killed"] as const) {
    it(`hands off when the leader ${ending} mid-session, restoring the follower's subscriptions`, async () => {
      const world = new FakeWorld()
      const durable = new FakeDurable()
      const a = open(world, durable, "a")
      const b = open(world, durable, "b")
      const c = open(world, durable, "c")
      await world.settle()
      b.linked.post({ kind: "subscribe", sub: 1, query: windowQuery })
      b.linked.post({ kind: "subscribe", sub: 2, query: { kind: "core" } })
      c.linked.post({ kind: "subscribe", sub: 1, query: { kind: "core" } })
      b.linked.post(send("t1"))
      await world.settle()
      expect(b.ui.list(1)).toHaveLength(1)

      if (ending === "closes") a.linked.close()
      else a.tab.kill()
      await world.settle()

      expect(b.linked.role).toBe("leader")
      expect(c.linked.role).toBe("follower")
      expect(b.roles).toEqual(["follower", "handoff", "leader"])
      expect(durable.cores).toHaveLength(2)
      expect(durable.cores[0]!.alive).toBe(false)
      const next = durable.cores[1]!
      expect([...next.subs.values()].map((query) => query.kind).sort()).toEqual(["chatWindow", "core", "core"])
      expect(b.ui.snapshots).toBe(1)
      expect(b.ui.list(1)).toHaveLength(1)
      expect(b.ui.phase(2)).toBe("ready")
      expect(c.ui.phase(1)).toBe("ready")
      expect(b.ui.errors).toEqual([])
      expect(c.ui.errors).toEqual([])
      expect(durable.applied).toEqual(["t1"])
    })
  }

  it("delivers an intent posted during the handoff to the new core once", async () => {
    const world = new FakeWorld()
    const durable = new FakeDurable()
    const a = open(world, durable, "a")
    const b = open(world, durable, "b")
    await world.settle()
    b.linked.post({ kind: "subscribe", sub: 1, query: windowQuery })
    await world.settle()

    a.tab.kill()
    b.linked.post(send("during"))
    await world.settle()
    b.linked.post(send("after"))
    await world.settle()

    expect(b.linked.role).toBe("leader")
    expect(intentsFor(durable, "during")).toHaveLength(1)
    expect(durable.applied).toEqual(["during", "after"])
    expect(b.ui.settledFor("during")).toEqual(["accepted"])
    expect(b.ui.list(1)).toHaveLength(2)
    expect(b.ui.errors).toEqual([])
  })

  it("applies an intent once when the old leader committed it and died before answering", async () => {
    const world = new FakeWorld()
    const durable = new FakeDurable()
    const a = open(world, durable, "a")
    const b = open(world, durable, "b")
    await world.settle()
    b.linked.post({ kind: "subscribe", sub: 1, query: windowQuery })
    await world.settle()

    a.cores[0]!.mute()
    b.linked.post(send("t1"))
    await world.settle()
    expect(durable.applied).toEqual(["t1"])
    expect(b.ui.settledFor("t1")).toEqual([])

    a.tab.kill()
    await world.settle()

    expect(intentsFor(durable, "t1")).toHaveLength(2) // re-sent by tx ...
    expect(durable.applied).toEqual(["t1"]) // ... applied once
    expect(b.ui.settledFor("t1")).toEqual(["accepted"])
    expect(b.ui.list(1)).toHaveLength(1)
  })

  it("lets a newer build take leadership; older contexts report superseded and stop", async () => {
    const world = new FakeWorld()
    const durable = new FakeDurable()
    const a = open(world, durable, "a", "2026-11-17.1")
    const c = open(world, durable, "c", "2026-11-17.1")
    await world.settle()
    a.linked.post({ kind: "subscribe", sub: 1, query: { kind: "core" } })
    c.linked.post({ kind: "subscribe", sub: 1, query: { kind: "core" } })
    await world.settle()
    expect(a.linked.role).toBe("leader")

    const n = open(world, durable, "n", "2026-11-18.1")
    n.linked.post({ kind: "subscribe", sub: 1, query: { kind: "core" } })
    await world.settle()

    expect(a.linked.role).toBe("superseded")
    expect(c.linked.role).toBe("superseded")
    expect(n.linked.role).toBe("leader")
    expect(a.ui.phase(1)).toBe("superseded")
    expect(c.ui.phase(1)).toBe("superseded")
    expect(n.ui.phase(1)).toBe("ready")
    expect(a.cores[0]!.closed).toBe(true)
    expect(c.cores).toHaveLength(0)
    expect(world.heldLocks().sort()).toEqual([names.locks.context("n"), names.locks.leader, `${names.channel}/term/n.1`].sort())
    expect(world.queuedLockRequests()).toBe(0)
  })

  it("an older context that meets a newer leader reports superseded and never leads", async () => {
    const world = new FakeWorld()
    const durable = new FakeDurable()
    const n = open(world, durable, "n", "2026-11-18.1")
    await world.settle()
    const old = open(world, durable, "old", "2026-11-17.1")
    old.linked.post({ kind: "subscribe", sub: 1, query: { kind: "core" } })
    await world.settle()
    expect(old.linked.role).toBe("superseded")
    expect(old.ui.phase(1)).toBe("superseded")
    expect(n.linked.role).toBe("leader")

    n.linked.close()
    await world.settle()
    expect(old.cores).toHaveLength(0)
    expect(world.heldLocks()).toEqual([])
  })

  it("closes a dead follower's context on the core", async () => {
    const world = new FakeWorld()
    const durable = new FakeDurable()
    const a = open(world, durable, "a")
    const b = open(world, durable, "b")
    await world.settle()
    a.linked.post({ kind: "subscribe", sub: 1, query: { kind: "core" } })
    b.linked.post({ kind: "subscribe", sub: 1, query: windowQuery })
    await world.settle()
    expect(durable.cores[0]!.subs.size).toBe(2)

    b.tab.kill()
    await world.settle()
    expect([...durable.cores[0]!.subs.values()].map((query) => query.kind)).toEqual(["core"])
    expect(a.linked.role).toBe("leader")
  })

  it("when the core dies, the leader steps down, a follower takes over and the old leader follows it", async () => {
    const world = new FakeWorld()
    const durable = new FakeDurable()
    const a = open(world, durable, "a")
    const b = open(world, durable, "b")
    await world.settle()
    a.linked.post({ kind: "subscribe", sub: 1, query: { kind: "core" } })
    await world.settle()

    a.handles[0]!.fail("worker error")
    await world.settle()
    expect(b.linked.role).toBe("leader")
    expect(a.linked.role).toBe("follower")
    expect(a.ui.phase(1)).toBe("ready")
    expect(a.ui.errors).toEqual([])
  })

  it("restarts the core after a backoff when no other context can lead", async () => {
    const world = new FakeWorld()
    const durable = new FakeDurable()
    const a = open(world, durable, "a")
    await world.settle()
    a.linked.post({ kind: "subscribe", sub: 1, query: { kind: "core" } })
    await world.settle()

    a.handles[0]!.fail("worker error")
    await world.settle()
    expect(a.linked.role).toBe("handoff")
    expect(durable.cores).toHaveLength(1)

    world.clock.advance(499)
    await world.settle()
    expect(durable.cores).toHaveLength(1)
    world.clock.advance(1)
    await world.settle()
    expect(a.linked.role).toBe("leader")
    expect(durable.cores).toHaveLength(2)
    expect(a.ui.phase(1)).toBe("ready")

    a.handles[1]!.fail("worker error")
    await world.settle()
    world.clock.advance(500)
    await world.settle()
    expect(durable.cores).toHaveLength(2) // the second failure waits twice as long
    world.clock.advance(500)
    await world.settle()
    expect(durable.cores).toHaveLength(3)
  })

  it("makes a core that cannot start visible as failed, and clears it when a start succeeds", async () => {
    const world = new FakeWorld()
    const durable = new FakeDurable()
    const a = open(world, durable, "a", "2026-11-17.1", { failStarts: 2 })
    a.linked.post({ kind: "subscribe", sub: 1, query: { kind: "core" } })
    a.linked.post({ kind: "subscribe", sub: 2, query: windowQuery })
    await world.settle()

    expect(a.ui.phase(1)).toBe("failed")
    expect(a.ui.resources.get(1)).toMatchObject({ failure: START_FAILURE })
    expect(a.ui.resources.get(2)).toBeUndefined()
    expect(world.heldLocks()).toEqual([names.locks.context("a")])

    world.clock.advance(500)
    await world.settle()
    expect(a.ui.phase(1)).toBe("failed")
    expect(a.ui.messages).toHaveLength(1) // the same failure is reported once

    world.clock.advance(1000)
    await world.settle()
    expect(a.linked.role).toBe("leader")
    expect(a.ui.phase(1)).toBe("ready")
    expect(a.ui.resources.get(1)).not.toHaveProperty("failure")
    expect(a.ui.errors).toEqual([])
  })

  it("a leader about to freeze steps down and leaves the queue; on resume it rejoins", async () => {
    const world = new FakeWorld()
    const durable = new FakeDurable()
    const a = open(world, durable, "a")
    const b = open(world, durable, "b")
    await world.settle()

    a.tab.lifecycle.fire("freeze")
    await world.settle()
    expect(b.linked.role).toBe("leader")
    expect(durable.cores[0]!.alive).toBe(false)

    a.tab.lifecycle.fire("resume")
    await world.settle()
    expect(a.linked.role).toBe("follower")

    b.linked.close()
    await world.settle()
    expect(a.linked.role).toBe("leader")
  })

  describe("closing while the core signs out", () => {
    /** A leader whose core's shutdown waits until the test releases it, recording an early terminate. */
    const slowLeader = (world: FakeWorld, durable: FakeDurable, id: string) => {
      const tab = world.tab(id)
      const state = { shutdownStarted: false, shutdownDone: false, terminatedEarly: false, release: () => {} }
      const linked = connectCore({
        account,
        buildId: "2026-11-17.1",
        locks: tab.locks,
        channels: tab.channels,
        clock: tab.clock,
        lifecycle: tab.lifecycle,
        contextId: id,
        log: quiet,
        startCore: () => {
          const inner = inProcessCore(() => new FakeCore(durable), { log: quiet })
          return {
            open: (contextId) => inner.open(contextId),
            onExit: (listener) => inner.onExit(listener),
            shutdown: () => {
              state.shutdownStarted = true
              return new Promise<void>((resolve) => {
                state.release = () => {
                  state.shutdownDone = true
                  void inner.shutdown().then(resolve)
                }
              })
            },
            terminate: () => {
              if (!state.shutdownDone) state.terminatedEarly = true
              inner.terminate()
            },
          }
        },
      })
      return { linked, state }
    }

    it("does not terminate a core erasing after this context's sign-out at the ordinary 3 s bound", async () => {
      const world = new FakeWorld()
      const durable = new FakeDurable()
      const a = slowLeader(world, durable, "a")
      await world.settle()
      expect(a.linked.role).toBe("leader")

      a.linked.post({ kind: "session", action: "signOut" })
      a.linked.close()
      await world.settle()
      expect(a.state.shutdownStarted).toBe(true)
      world.clock.advance(3_001)
      await world.settle()
      expect(a.state.terminatedEarly).toBe(false)
      expect(world.heldLocks()).not.toEqual([])

      a.state.release()
      await world.settle()
      expect(a.state.terminatedEarly).toBe(false)
      expect(world.heldLocks()).toEqual([])
      expect(world.clock.pendingTimers).toBe(0)
    })

    it("applies the long bound for a sign-out relayed from a follower, and still terminates at it", async () => {
      const world = new FakeWorld()
      const durable = new FakeDurable()
      const a = slowLeader(world, durable, "a")
      await world.settle()
      const b = open(world, durable, "b")
      await world.settle()
      expect(b.linked.role).toBe("follower")

      b.linked.post({ kind: "session", action: "signOut" })
      await world.settle()
      b.linked.close()
      a.linked.close()
      await world.settle()
      world.clock.advance(3_001)
      await world.settle()
      expect(a.state.terminatedEarly).toBe(false)

      world.clock.advance(SIGN_OUT_SHUTDOWN_TIMEOUT_MS)
      await world.settle()
      expect(a.state.terminatedEarly).toBe(true)
      expect(world.heldLocks()).toEqual([])
    })

    it("keeps the ordinary bound when no sign-out passed through", async () => {
      const world = new FakeWorld()
      const durable = new FakeDurable()
      const a = slowLeader(world, durable, "a")
      await world.settle()
      a.linked.close()
      await world.settle()
      world.clock.advance(3_001)
      await world.settle()
      expect(a.state.terminatedEarly).toBe(true)
      expect(world.heldLocks()).toEqual([])
    })
  })

  it("closing the last context releases everything", async () => {
    const world = new FakeWorld()
    const durable = new FakeDurable()
    const a = open(world, durable, "a")
    const b = open(world, durable, "b")
    await world.settle()
    a.linked.post({ kind: "subscribe", sub: 1, query: { kind: "core" } })
    b.linked.post({ kind: "subscribe", sub: 1, query: windowQuery })
    await world.settle()

    b.linked.close()
    await world.settle()
    expect(durable.cores[0]!.subs.size).toBe(1)
    a.linked.close()
    await world.settle()

    expect(a.linked.role).toBe("closed")
    expect(b.linked.role).toBe("closed")
    expect(world.heldLocks()).toEqual([])
    expect(world.queuedLockRequests()).toBe(0)
    expect(world.openChannels()).toEqual([])
    expect(world.clock.pendingTimers).toBe(0)
    expect(durable.cores.every((core) => core.closed)).toBe(true)
    expect(a.tab.lifecycle.listenerCount).toBe(0)
  })
})
