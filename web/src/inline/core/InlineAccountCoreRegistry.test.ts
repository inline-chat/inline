import { userId, type UserID } from "@inline/ids"
import { afterEach, describe, expect, it, vi } from "vitest"
import {
  InlineAccountCoreRegistry,
  type InlineAccountCoreOwner,
} from "./InlineAccountCoreRegistry"

class FakeAccountCore implements InlineAccountCoreOwner {
  running = false
  starts = 0
  stops = 0

  constructor(readonly accountId: UserID) {}

  async start() {
    if (this.running) return
    this.running = true
    this.starts += 1
  }

  async stop() {
    if (!this.running) return
    this.running = false
    this.stops += 1
  }
}

describe("InlineAccountCoreRegistry", () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it("returns one owner for an account", () => {
    const registry = new InlineAccountCoreRegistry(
      (accountId) => new FakeAccountCore(accountId),
    )

    expect(registry.get(userId(7))).toBe(
      registry.get(userId(7)),
    )
    expect(registry.get(userId(8))).not.toBe(
      registry.get(userId(7)),
    )
  })

  it("absorbs a Strict Mode release and immediate retain", async () => {
    vi.useFakeTimers()
    const registry = new InlineAccountCoreRegistry(
      (accountId) => new FakeAccountCore(accountId),
    )
    const core = registry.get(userId(7))

    const firstRelease = registry.retain(core)
    await Promise.resolve()
    firstRelease()
    const secondRelease = registry.retain(core)
    await vi.runAllTimersAsync()

    expect(core.starts).toBe(1)
    expect(core.stops).toBe(0)

    secondRelease()
    await vi.runAllTimersAsync()
    expect(core.stops).toBe(1)
  })
})
