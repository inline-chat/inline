import { describe, expect, it, vi } from "vitest"
import { registerBotCapabilitiesWithRetry } from "./bot-capabilities.js"

describe("bot capability registration", () => {
  it("retries a transient failure", async () => {
    const register = vi.fn()
      .mockRejectedValueOnce(new Error("not ready"))
      .mockResolvedValue(undefined)
    const wait = vi.fn(async () => {})

    await expect(registerBotCapabilitiesWithRetry({
      register,
      retryDelaysMs: [25],
      wait,
    })).resolves.toBe(true)

    expect(register).toHaveBeenCalledTimes(2)
    expect(wait).toHaveBeenCalledWith(25)
  })

  it("stops before registering when cancelled", async () => {
    const register = vi.fn(async () => {})

    await expect(registerBotCapabilitiesWithRetry({
      register,
      isCancelled: () => true,
    })).resolves.toBe(false)

    expect(register).not.toHaveBeenCalled()
  })

  it("reports retry exhaustion and stops after the configured attempts", async () => {
    const failure = new Error("still unavailable")
    const register = vi.fn(async () => { throw failure })
    const onFailure = vi.fn()
    const wait = vi.fn(async () => {})

    await expect(registerBotCapabilitiesWithRetry({
      register,
      retryDelaysMs: [10],
      onFailure,
      wait,
    })).resolves.toBe(false)

    expect(register).toHaveBeenCalledTimes(2)
    expect(wait).toHaveBeenCalledOnce()
    expect(onFailure).toHaveBeenNthCalledWith(1, failure, true)
    expect(onFailure).toHaveBeenNthCalledWith(2, failure, false)
  })

  it("honors cancellation between retry attempts", async () => {
    const register = vi.fn(async () => { throw new Error("not ready") })
    const wait = vi.fn(async () => {})
    let cancellationChecks = 0

    await expect(registerBotCapabilitiesWithRetry({
      register,
      retryDelaysMs: [10, 20],
      isCancelled: () => cancellationChecks++ > 0,
      wait,
    })).resolves.toBe(false)

    expect(register).toHaveBeenCalledOnce()
    expect(wait).toHaveBeenCalledOnce()
  })

  it("uses the default scheduler when a retry delay is supplied", async () => {
    const register = vi.fn()
      .mockRejectedValueOnce(new Error("not ready"))
      .mockResolvedValue(undefined)

    await expect(registerBotCapabilitiesWithRetry({
      register,
      retryDelaysMs: [0],
    })).resolves.toBe(true)

    expect(register).toHaveBeenCalledTimes(2)
  })
})
