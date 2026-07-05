import { mkdtempSync, rmSync } from "node:fs"
import os from "node:os"
import path from "node:path"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import {
  clearInlineThreadParticipationCacheForTest,
  hasInlineThreadParticipationWithPersistence,
  recordInlineThreadParticipation,
} from "./thread-participation.js"
import { clearInlineRuntime, setInlineRuntime } from "../runtime.js"

describe("inline/thread-participation", () => {
  const tempDirs: string[] = []

  beforeEach(() => {
    clearInlineThreadParticipationCacheForTest()
    clearInlineRuntime()
  })

  afterEach(() => {
    clearInlineThreadParticipationCacheForTest()
    clearInlineRuntime()
    for (const dir of tempDirs.splice(0)) {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  it("records and checks thread participation in memory", async () => {
    recordInlineThreadParticipation("default", 7000n, 7100n)

    await expect(
      hasInlineThreadParticipationWithPersistence({
        accountId: "default",
        parentChatId: 7000n,
        threadId: 7100n,
      }),
    ).resolves.toBe(true)
  })

  it("scopes participation by account and thread", async () => {
    recordInlineThreadParticipation("default", 7000n, 7100n)

    await expect(
      hasInlineThreadParticipationWithPersistence({
        accountId: "other",
        parentChatId: 7000n,
        threadId: 7100n,
      }),
    ).resolves.toBe(false)
    await expect(
      hasInlineThreadParticipationWithPersistence({
        accountId: "default",
        parentChatId: 7000n,
        threadId: 7200n,
      }),
    ).resolves.toBe(false)
  })

  it("writes and reads persistent participation when runtime state is available", async () => {
    const register = vi.fn(async () => {})
    const lookup = vi.fn(async () => ({ repliedAt: 1_700_000_000 }))
    const openKeyedStore = vi.fn(() => ({ register, lookup }))

    setInlineRuntime({
      state: {
        resolveStateDir: () => "/tmp/inline-thread-participation-tests",
        openKeyedStore,
      },
      logging: {
        getChildLogger: () => ({ warn: vi.fn() }),
      },
    } as any)

    recordInlineThreadParticipation("default", 7000n, 7100n, { agentId: "main" })

    expect(openKeyedStore).toHaveBeenCalledWith({
      namespace: "inline.thread-participation",
      maxEntries: 1000,
      defaultTtlMs: 86_400_000,
    })
    expect(register).toHaveBeenCalledWith(
      "default:7000:7100",
      expect.objectContaining({ agentId: "main" }),
      { ttlMs: 86_400_000 },
    )

    clearInlineThreadParticipationCacheForTest()
    await expect(
      hasInlineThreadParticipationWithPersistence({
        accountId: "default",
        parentChatId: 7000n,
        threadId: 7100n,
      }),
    ).resolves.toBe(true)
    expect(lookup).toHaveBeenCalledWith("default:7000:7100")
  })

  it("falls back to state-dir persistence when keyed store is unavailable", async () => {
    const stateDir = mkdtempSync(path.join(os.tmpdir(), "openclaw-inline-thread-"))
    tempDirs.push(stateDir)
    const warn = vi.fn()
    const openKeyedStore = vi.fn(() => {
      throw new Error("openKeyedStore is only available for bundled plugins in this release.")
    })

    setInlineRuntime({
      state: {
        resolveStateDir: () => stateDir,
        openKeyedStore,
      },
      logging: {
        getChildLogger: () => ({ warn }),
      },
    } as any)

    recordInlineThreadParticipation("default", 7000n, 7100n)
    clearInlineThreadParticipationCacheForTest()

    let found = false
    for (let attempt = 0; attempt < 20; attempt += 1) {
      found = await hasInlineThreadParticipationWithPersistence({
        accountId: "default",
        parentChatId: 7000n,
        threadId: 7100n,
      })
      if (found) break
      await new Promise((resolve) => setTimeout(resolve, 10))
    }

    expect(found).toBe(true)
    expect(openKeyedStore).toHaveBeenCalled()
    expect(warn).not.toHaveBeenCalled()
  })
})
