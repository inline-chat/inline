import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import type { ResolvedInlineAccount } from "./accounts"

const sdkMock = vi.hoisted(() => ({
  constructorOptions: [] as Array<Record<string, unknown>>,
  connect: vi.fn(),
  invokeRaw: vi.fn(),
  close: vi.fn(),
}))

vi.mock("@inline-chat/realtime-sdk", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@inline-chat/realtime-sdk")>()
  return {
    ...actual,
    InlineSdkClient: class {
      constructor(options: Record<string, unknown>) {
        sdkMock.constructorOptions.push(options)
      }

      connect(signal?: AbortSignal) {
        return sdkMock.connect(signal)
      }

      invokeRaw(...args: unknown[]) {
        return sdkMock.invokeRaw(...args)
      }

      close() {
        return sdkMock.close()
      }
    },
  }
})

import { probeInlineAccount } from "./probe"

const account = {
  accountId: "local",
  configured: true,
  baseUrl: "http://127.0.0.1:8000",
  token: "test-token",
  tokenFile: null,
  tokenSource: "config",
} as ResolvedInlineAccount

describe("inline/probe", () => {
  beforeEach(() => {
    sdkMock.constructorOptions.length = 0
    sdkMock.connect.mockReset().mockResolvedValue(undefined)
    sdkMock.invokeRaw.mockReset()
    sdkMock.close.mockReset().mockResolvedValue(undefined)
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it("passes one abort signal and an early deadline through connect and GET_ME", async () => {
    sdkMock.invokeRaw.mockResolvedValue({
      oneofKind: "getMe",
      getMe: {
        user: {
          id: 42n,
          firstName: "Kevin",
          lastName: "",
          username: "kevin",
          bot: true,
        },
      },
    })

    await expect(probeInlineAccount(account, 15_000)).resolves.toMatchObject({
      ok: true,
      accountId: "local",
      user: {
        id: "42",
        username: "kevin",
        name: "Kevin",
        bot: true,
      },
    })

    expect(sdkMock.constructorOptions).toEqual([
      expect.objectContaining({ rpcTimeoutMs: 12_500 }),
    ])
    const signal = sdkMock.connect.mock.calls[0]?.[0]
    expect(signal).toBeInstanceOf(AbortSignal)
    expect(sdkMock.invokeRaw).toHaveBeenCalledWith(
      expect.anything(),
      expect.anything(),
      { signal, timeoutMs: 12_500 },
    )
    expect(sdkMock.close).toHaveBeenCalledOnce()
  })

  it("preserves SDK defaults when the host does not supply a positive deadline", async () => {
    sdkMock.invokeRaw.mockResolvedValue({
      oneofKind: "getMe",
      getMe: {
        user: { id: 42n, firstName: "Kevin" },
      },
    })

    await expect(probeInlineAccount(account, 0)).resolves.toMatchObject({ ok: true })

    expect(sdkMock.constructorOptions).toEqual([
      expect.not.objectContaining({ rpcTimeoutMs: expect.anything() }),
    ])
    expect(sdkMock.connect).toHaveBeenCalledWith(undefined)
    expect(sdkMock.invokeRaw).toHaveBeenCalledWith(
      expect.anything(),
      expect.anything(),
      undefined,
    )
  })

  it("aborts and cleans up a connection attempt before the host deadline", async () => {
    vi.useFakeTimers()
    sdkMock.connect.mockImplementation((signal?: AbortSignal) => new Promise<void>((_resolve, reject) => {
      signal?.addEventListener("abort", () => reject(new Error("aborted")), { once: true })
    }))

    const resultPromise = probeInlineAccount(account, 3_000)
    await vi.advanceTimersByTimeAsync(600)

    await expect(resultPromise).resolves.toMatchObject({
      ok: false,
      error: "probe timeout after 3000ms",
    })
    expect(sdkMock.close).toHaveBeenCalledOnce()
  })

  it("aborts GET_ME and returns before the host deadline after bounded cleanup", async () => {
    vi.useFakeTimers()
    sdkMock.invokeRaw.mockImplementation((...args: unknown[]) => {
      const options = args[2] as { signal?: AbortSignal }
      return new Promise((_resolve, reject) => {
        options.signal?.addEventListener("abort", () => reject(new Error("aborted")), { once: true })
      })
    })
    sdkMock.close.mockImplementation(() => new Promise((resolve) => {
      setTimeout(resolve, 2_000)
    }))

    const resultPromise = probeInlineAccount(account, 3_000)
    let settled = false
    void resultPromise.then(() => {
      settled = true
    })

    await vi.advanceTimersByTimeAsync(2_599)
    expect(settled).toBe(false)
    await vi.advanceTimersByTimeAsync(1)

    await expect(resultPromise).resolves.toMatchObject({
      ok: false,
      error: "probe timeout after 3000ms",
    })
    expect(sdkMock.close).toHaveBeenCalledOnce()
  })
})
