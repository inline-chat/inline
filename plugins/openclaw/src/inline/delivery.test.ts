import { afterEach, describe, expect, it, vi } from "vitest"
import { ProtocolClientError } from "@inline-chat/realtime-sdk"
import { createInlineMessageSender } from "./delivery"

const rateLimit = (seconds: number, code = 3) => new Error("send failed", {
  cause: new ProtocolClientError("rpc-error", { code, retryAfterSeconds: seconds }),
})

afterEach(() => vi.useRealTimers())

describe("monitor delivery", () => {
  it("waits the server hint and reuses one send identity", async () => {
    vi.useFakeTimers()
    const client = { sendMessage: vi.fn().mockRejectedValueOnce(rateLimit(2)).mockResolvedValue({ messageId: 9n }) }
    const sending = createInlineMessageSender(client)({ chatId: 7n, text: "Answer" })
    await vi.advanceTimersByTimeAsync(1_999)
    expect(client.sendMessage).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(1)
    await expect(sending).resolves.toEqual({ messageId: 9n })
    const first = client.sendMessage.mock.calls[0]![0]
    const second = client.sendMessage.mock.calls[1]![0]
    expect(first).toBe(second)
    expect(first.randomId).not.toBe(0n)
    expect(typeof first.randomId).toBe("bigint")
  })

  it("preserves a supplied identity and stops after two retries", async () => {
    vi.useFakeTimers()
    const error = rateLimit(1, 429)
    const client = { sendMessage: vi.fn().mockRejectedValue(error) }
    const sending = createInlineMessageSender(client)({ chatId: 7n, text: "Answer", randomId: -42n })
    const result = expect(sending).rejects.toBe(error)
    await vi.advanceTimersByTimeAsync(2_000)
    await result
    expect(client.sendMessage).toHaveBeenCalledTimes(3)
    expect(client.sendMessage.mock.calls.every(([request]) => request.randomId === -42n)).toBe(true)
  })

  it("cancels a flood wait without retrying or closing the shared client", async () => {
    const controller = new AbortController()
    const client = { sendMessage: vi.fn().mockRejectedValue(rateLimit(2)), close: vi.fn() }
    const sending = createInlineMessageSender(client, controller.signal)({ chatId: 7n, text: "Answer" })
    controller.abort()
    await expect(sending).rejects.toMatchObject({ name: "AbortError" })
    expect(client.sendMessage).toHaveBeenCalledTimes(1)
    expect(client.close).not.toHaveBeenCalled()
  })

  it.each([
    rateLimit(61), rateLimit(Number.POSITIVE_INFINITY), rateLimit(Number.NaN), rateLimit(0), rateLimit(-1),
    new ProtocolClientError("timeout"), new ProtocolClientError("commit-outcome-unknown"),
    new Error("rate limit, try again"), new ProtocolClientError("rpc-error", { code: 403, retryAfterSeconds: 1 }),
    new ProtocolClientError("rpc-error", { code: 3 }),
    new Error("uncertain", { cause: new ProtocolClientError("commit-outcome-unknown", { retryAfterSeconds: 1 }) }),
  ])("does not retry an unqualified rejection or uncertain send (%s)", async (error) => {
    const client = { sendMessage: vi.fn().mockRejectedValue(error) }
    await expect(createInlineMessageSender(client)({ chatId: 7n, text: "Answer" })).rejects.toBe(error)
    expect(client.sendMessage).toHaveBeenCalledTimes(1)
  })

  it("rejects a cancelled send before the SDK handoff", async () => {
    const controller = new AbortController()
    controller.abort(new Error("cancelled"))
    const client = { sendMessage: vi.fn() }
    await expect(createInlineMessageSender(client, controller.signal)({ chatId: 7n, text: "Answer" })).rejects.toThrow("cancelled")
    expect(client.sendMessage).not.toHaveBeenCalled()
  })
})
