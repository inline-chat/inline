import { Db } from "@inline/client/core"
import { userId } from "@inline/ids"
import { afterEach, describe, expect, it, vi } from "vitest"
import {
  INLINE_CORE_PROTOCOL_VERSION,
  type InlineCoreSnapshot,
} from "../core/InlineCoreProtocol"
import type { InlineRuntimeCore } from "./InlineRuntimeCore"
import { InlineRuntimePreloader } from "./InlineRuntimePreloader"

const activePreloaders: InlineRuntimePreloader[] = []

const makeCore = (
  db = new Db({ autoHydrate: false, persistence: false }),
) => {
  let snapshot: InlineCoreSnapshot = {
    protocolVersion: INLINE_CORE_PROTOCOL_VERSION,
    ownerId: "runtime-preloader-test-owner",
    accountId: userId(7),
    phase: "openingStorage",
    cacheReady: false,
    connectionState: "idle",
  }
  const listeners = new Set<() => void>()
  const promoteCached = vi.fn(async (_key: string) => true)
  const core = {
    client: { db },
    mediaRepository: { promoteCached },
    start: vi.fn(async () => undefined),
    getSnapshot: () => snapshot,
    subscribe: (listener: () => void) => {
      listeners.add(listener)
      return () => listeners.delete(listener)
    },
  } as unknown as InlineRuntimeCore
  return {
    core,
    promoteCached,
    setSnapshot(next: Partial<InlineCoreSnapshot>) {
      snapshot = { ...snapshot, ...next }
      for (const listener of listeners) listener()
    },
  }
}

afterEach(() => {
  for (const preloader of activePreloaders.splice(0)) preloader.clear()
  vi.useRealTimers()
})

describe("InlineRuntimePreloader", () => {
  it("deduplicates route loads and resolves as soon as cached projections are ready", async () => {
    const state = makeCore()
    const release = vi.fn()
    const acquireCore = vi.fn(() => ({ core: state.core, release }))
    const preloader = new InlineRuntimePreloader({
      acquireCore,
      payloadTtlMs: 60_000,
    })
    activePreloaders.push(preloader)

    const first = preloader.prepare(userId(7))
    const second = preloader.prepare(userId(7))
    expect(acquireCore).toHaveBeenCalledOnce()

    state.setSnapshot({ phase: "cacheReady", cacheReady: true })

    await expect(Promise.all([first, second])).resolves.toEqual([
      expect.objectContaining({ accountId: userId(7) }),
      expect.objectContaining({ accountId: userId(7) }),
    ])
    expect(state.core.start).toHaveBeenCalledOnce()
    expect(release).not.toHaveBeenCalled()
  })

  it("does not expire the core lease while storage hydration is pending", async () => {
    vi.useFakeTimers()
    const state = makeCore()
    const release = vi.fn()
    const preloader = new InlineRuntimePreloader({
      acquireCore: () => ({ core: state.core, release }),
      payloadTtlMs: 5,
      cacheReadyTimeoutMs: 10_000,
    })
    activePreloaders.push(preloader)

    const prepared = preloader.prepare(userId(7))
    await vi.advanceTimersByTimeAsync(50)
    expect(release).not.toHaveBeenCalled()

    state.setSnapshot({ phase: "cacheReady", cacheReady: true })
    await expect(prepared).resolves.toEqual(
      expect.objectContaining({ accountId: userId(7) }),
    )
    expect(release).not.toHaveBeenCalled()

    await vi.advanceTimersByTimeAsync(5)
    expect(release).toHaveBeenCalledOnce()
  })

  it("does not make avatar media a runtime-readiness dependency", async () => {
    const state = makeCore()
    const preloader = new InlineRuntimePreloader({
      acquireCore: () => ({ core: state.core, release: vi.fn() }),
      payloadTtlMs: 60_000,
    })
    activePreloaders.push(preloader)

    const prepared = preloader.prepare(userId(7))
    state.setSnapshot({ phase: "cacheReady", cacheReady: true })
    await expect(prepared).resolves.toEqual(
      expect.objectContaining({ promotedAvatarCount: 0 }),
    )
    expect(state.promoteCached).not.toHaveBeenCalled()
  })

  it("surfaces a nonresponsive boot owner instead of replacing it", async () => {
    const failed = makeCore()
    failed.setSnapshot({
      phase: "error",
      blockingFailure: {
        code: "owner-unresponsive",
        message: "Inline core worker did not complete its handshake",
        recoveryAction: "reload",
      },
    })
    const releaseFailed = vi.fn()
    const preloader = new InlineRuntimePreloader({
      acquireCore: () => ({
        core: failed.core,
        release: releaseFailed,
      }),
      payloadTtlMs: 60_000,
    })
    activePreloaders.push(preloader)

    await expect(preloader.prepare(userId(7))).rejects.toThrow(
      "Inline core worker did not complete its handshake",
    )
    expect(releaseFailed).toHaveBeenCalledOnce()
  })
})
