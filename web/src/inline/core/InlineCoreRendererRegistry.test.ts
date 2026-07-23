import { AuthStore } from "@inline/client"
import { userId } from "@inline/ids"
import { afterEach, describe, expect, it, vi } from "vitest"
import type { InlineCoreRendererClient } from "./InlineCoreRendererClient"
import { InlineCoreRendererRegistry } from "./InlineCoreRendererRegistry"
const fakeClient = (ownerName = "inline-core-v-test") => ({
  accountId: userId(7),
  ownerName,
  start: vi.fn(async () => undefined),
  detach: vi.fn(),
  canReplaceUnresponsiveBootOwner: vi.fn(() => false),
})

describe("InlineCoreRendererRegistry", () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it("retains one renderer client across a Strict Mode remount", async () => {
    vi.useFakeTimers()
    const client = fakeClient()
    const createClient = vi.fn(
      () => client as unknown as InlineCoreRendererClient,
    )
    const registry = new InlineCoreRendererRegistry(
      createClient,
    )
    const auth = new AuthStore({ persistence: "memory" })
    auth.login({ token: "token", userId: userId(7) })

    const resolved = registry.get(userId(7), auth)
    const firstRelease = registry.retain(resolved)
    firstRelease()
    const secondRelease = registry.retain(resolved)
    await vi.runAllTimersAsync()

    expect(createClient).toHaveBeenCalledOnce()
    expect(client.detach).not.toHaveBeenCalled()

    secondRelease()
    await vi.runAllTimersAsync()
    expect(client.detach).toHaveBeenCalledOnce()
  })

  it("does not replace an active renderer when the session changes", async () => {
    vi.useFakeTimers()
    const client = fakeClient()
    const createClient = vi.fn(
      () => client as unknown as InlineCoreRendererClient,
    )
    const registry = new InlineCoreRendererRegistry(createClient)
    const auth = new AuthStore({ persistence: "memory" })
    auth.login({ token: "token", userId: userId(7) })

    const original = registry.get(userId(7), auth)
    const release = registry.retain(original)
    auth.login({ token: "replacement", userId: userId(7) })
    expect(() => registry.get(userId(7), auth)).toThrow(
      "Cannot replace an active Inline core renderer session",
    )
    expect(createClient).toHaveBeenCalledOnce()
    release()
    await vi.runAllTimersAsync()
  })

  it("replaces only an unresponsive pre-handshake owner", () => {
    const failed = fakeClient()
    failed.canReplaceUnresponsiveBootOwner.mockReturnValue(true)
    const replacement = fakeClient("replacement")
    const createClient = vi
      .fn()
      .mockReturnValueOnce(
        failed as unknown as InlineCoreRendererClient,
      )
      .mockReturnValueOnce(
        replacement as unknown as InlineCoreRendererClient,
      )
    const registry = new InlineCoreRendererRegistry(createClient)
    const auth = new AuthStore({ persistence: "memory" })
    auth.login({ token: "token", userId: userId(7) })

    const original = registry.get(userId(7), auth)
    expect(
      registry.replaceUnresponsiveBootOwner(original, auth),
    ).toBe(replacement)
    expect(failed.detach).toHaveBeenCalledOnce()
    expect(createClient).toHaveBeenCalledTimes(2)
    expect(createClient.mock.calls[1]?.[0].workerName).toContain(
      "-replacement-",
    )
    expect(registry.get(userId(7), auth)).toBe(replacement)
  })
})
