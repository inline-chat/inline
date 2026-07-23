import { describe, expect, it, vi } from "vitest"
import { userId } from "@inline/ids"
import { InlineDesktopAuthSessionPersistence } from "./InlineDesktopAuthSessionPersistence"

describe("InlineDesktopAuthSessionPersistence", () => {
  it("maps the encrypted main-process vault onto the shared auth contract", async () => {
    const session = { token: "token", userId: userId(7) }
    const bridge = {
      loadSession: vi.fn(async () => ({
        session,
        storage: "encrypted" as const,
      })),
      saveSession: vi.fn(async () => true),
      clearSession: vi.fn(async () => undefined),
    }
    const persistence = new InlineDesktopAuthSessionPersistence(
      bridge,
    )

    await expect(persistence.load()).resolves.toEqual({
      status: "ready",
      session,
    })
    await persistence.save(session)
    await persistence.clear()
    expect(bridge.saveSession).toHaveBeenCalledWith(session)
    expect(bridge.clearSession).toHaveBeenCalledOnce()
  })

  it("surfaces unavailable encryption and failed writes", async () => {
    const bridge = {
      loadSession: vi.fn(async () => ({
        session: null,
        storage: "unavailable" as const,
      })),
      saveSession: vi.fn(async () => false),
      clearSession: vi.fn(async () => undefined),
    }
    const persistence = new InlineDesktopAuthSessionPersistence(
      bridge,
    )

    await expect(persistence.load()).resolves.toEqual({
      status: "unavailable",
    })
    await expect(
      persistence.save({ token: "token", userId: userId(7) }),
    ).rejects.toThrow("credential storage is unavailable")
  })
})
