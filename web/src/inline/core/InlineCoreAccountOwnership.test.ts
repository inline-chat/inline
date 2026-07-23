import { userId } from "@inline/ids"
import { describe, expect, it } from "vitest"
import {
  createInlineCoreAccountOwnershipAcquirer,
  inlineCoreAccountLockName,
  type InlineCoreLockManager,
} from "./InlineCoreAccountOwnership"

class FakeLockManager implements InlineCoreLockManager {
  private readonly held = new Set<string>()
  readonly events: string[] = []

  async request<T>(
    name: string,
    _options: { mode: "exclusive"; ifAvailable: true },
    callback: (lock: unknown | null) => Promise<T>,
  ): Promise<T> {
    if (this.held.has(name)) {
      this.events.push(`unavailable:${name}`)
      return callback(null)
    }
    this.held.add(name)
    this.events.push(`acquired:${name}`)
    try {
      return await callback({ name })
    } finally {
      this.events.push(`released:${name}`)
      this.held.delete(name)
    }
  }
}

describe("Inline core account ownership", () => {
  it("uses one unversioned account lock across bundle generations", async () => {
    const accountId = userId(7)
    const lockName = inlineCoreAccountLockName(accountId)
    const locks = new FakeLockManager()
    const oldGeneration = createInlineCoreAccountOwnershipAcquirer(locks)
    const newGeneration = createInlineCoreAccountOwnershipAcquirer(locks)

    const oldLease = await oldGeneration(accountId)
    expect(oldLease).not.toBeNull()
    await expect(newGeneration(accountId)).resolves.toBeNull()
    expect(locks.events).toEqual([
      `acquired:${lockName}`,
      `unavailable:${lockName}`,
    ])

    await oldLease?.release()
    const newLease = await newGeneration(accountId)
    expect(newLease).not.toBeNull()
    await newLease?.release()
    expect(locks.events).toEqual([
      `acquired:${lockName}`,
      `unavailable:${lockName}`,
      `released:${lockName}`,
      `acquired:${lockName}`,
      `released:${lockName}`,
    ])
  })

  it("fails closed when Web Locks are unavailable", async () => {
    const acquire = createInlineCoreAccountOwnershipAcquirer(undefined)
    await expect(acquire(userId(7))).resolves.toBeNull()
  })
})
