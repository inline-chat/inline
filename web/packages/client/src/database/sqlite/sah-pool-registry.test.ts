import { describe, expect, it } from "vitest"
import { InlineSqliteUnavailableError, isInlineSqliteStartupFallbackSafe } from "./errors"
import {
  isSahPoolBusyError,
  sahPoolNames,
  SahPoolRegistry,
  type SahPoolInstallOptions,
} from "./sah-pool-registry"

const busy = () => Object.assign(new Error("held elsewhere"), { name: "NoModificationAllowedError" })

const registry = (
  install: (options: SahPoolInstallOptions, call: number) => Promise<string>,
  delays: readonly number[] = [10, 20],
) => {
  const calls: SahPoolInstallOptions[] = []
  const slept: number[] = []
  const pools = new SahPoolRegistry<string>({
    install: (options) => {
      calls.push(options)
      return install(options, calls.length)
    },
    sleep: async (ms) => {
      slept.push(ms)
    },
    busyRetryDelaysMs: delays,
  })
  return { pools, calls, slept }
}

describe("SahPoolRegistry", () => {
  it("always installs so that a failure leaves the files and can be retried", async () => {
    const { pools, calls } = registry(async () => "pool")
    await pools.acquire({ accountId: "42" })
    expect(calls).toHaveLength(1)
    expect(calls[0]?.preserveOnInitFailure).toBe(true)
    expect(calls[0]?.forceReinitIfPreviouslyFailed).toBe(true)
  })

  it("gives each account its own pool name and directory", async () => {
    const { pools, calls } = registry(async (options) => options.name)
    const a = await pools.acquire({ accountId: "1" })
    const b = await pools.acquire({ accountId: "2" })
    expect(a).not.toBe(b)
    expect(calls[0]?.directory).not.toBe(calls[1]?.directory)
    expect(calls[0]?.directory).toContain("user-1")
    expect(calls[1]?.directory).toContain("user-2")
  })

  it("separates the same account under different namespaces", () => {
    const one = sahPoolNames({ accountId: "7", namespace: "api.inline.chat" })
    const two = sahPoolNames({ accountId: "7", namespace: "localhost:8000" })
    expect(one.directory).not.toBe(two.directory)
    expect(one.name).not.toBe(two.name)
  })

  it("never lets an account ID or namespace escape its directory", () => {
    const names = sahPoolNames({ accountId: "../../other", namespace: "../x/y" })
    expect(names.directory.split("/")).toHaveLength(3)
    expect(names.directory).not.toContain("..")
  })

  it("shares one installation between concurrent callers", async () => {
    const { pools, calls } = registry(async () => "pool")
    const [a, b] = await Promise.all([
      pools.acquire({ accountId: "1" }),
      pools.acquire({ accountId: "1" }),
    ])
    expect(a).toBe(b)
    expect(calls).toHaveLength(1)
  })

  it("retries while another context holds the pool, then succeeds", async () => {
    const { pools, calls, slept } = registry(async (_options, call) => {
      if (call < 3) throw busy()
      return "pool"
    })
    await expect(pools.acquire({ accountId: "1" })).resolves.toBe("pool")
    expect(calls).toHaveLength(3)
    expect(slept).toEqual([10, 20])
  })

  it("reports busy after the retries are spent, and does not fall back to memory", async () => {
    const { pools, calls } = registry(async () => {
      throw busy()
    })
    const error = await pools.acquire({ accountId: "1" }).catch((cause: unknown) => cause)
    expect(error).toBeInstanceOf(InlineSqliteUnavailableError)
    expect((error as InlineSqliteUnavailableError).reason).toBe("opfs-busy")
    expect(isInlineSqliteStartupFallbackSafe(error)).toBe(false)
    expect(calls).toHaveLength(3)
  })

  it("does not cache a failure: the next attempt installs again", async () => {
    let fail = true
    const { pools, calls } = registry(async () => {
      if (fail) throw busy()
      return "pool"
    }, [])
    await expect(pools.acquire({ accountId: "1" })).rejects.toMatchObject({ reason: "opfs-busy" })
    fail = false
    await expect(pools.acquire({ accountId: "1" })).resolves.toBe("pool")
    expect(calls).toHaveLength(2)
  })

  it("does not retry a failure that is not contention", async () => {
    const { pools, calls } = registry(async () => {
      throw new Error("corrupt header")
    })
    await expect(pools.acquire({ accountId: "1" })).rejects.toMatchObject({
      reason: "opfs-initialization-failed",
    })
    expect(calls).toHaveLength(1)
  })

  it("classifies a permission failure so the app can run in memory honestly", async () => {
    const { pools } = registry(async () => {
      throw Object.assign(new Error("denied"), { name: "SecurityError" })
    })
    const error = await pools.acquire({ accountId: "1" }).catch((cause: unknown) => cause)
    expect((error as InlineSqliteUnavailableError).reason).toBe("opfs-permission-denied")
    expect(isInlineSqliteStartupFallbackSafe(error)).toBe(true)
  })

  it("forgets a pool so it can be installed afresh after an erase", async () => {
    const { pools, calls } = registry(async () => "pool")
    await pools.acquire({ accountId: "1" })
    pools.forget({ accountId: "1" })
    await pools.acquire({ accountId: "1" })
    expect(calls).toHaveLength(2)
  })

  it("recognises contention through a wrapped cause", () => {
    expect(isSahPoolBusyError(new Error("wrapped", { cause: busy() }))).toBe(true)
    expect(isSahPoolBusyError(new Error("other"))).toBe(false)
  })
})
