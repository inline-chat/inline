import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import os from "node:os"
import path from "node:path"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import {
  clearInlineReplyThreadRouteCacheForTest,
  lookupInlineReplyThreadRoute,
  rememberInlineReplyThreadRoute,
} from "./thread-routes.js"
import { clearInlineRuntime, setInlineRuntime } from "../runtime.js"

describe("inline/thread-routes", () => {
  const tempDirs: string[] = []

  beforeEach(() => {
    clearInlineReplyThreadRouteCacheForTest()
    clearInlineRuntime()
  })

  afterEach(() => {
    clearInlineReplyThreadRouteCacheForTest()
    clearInlineRuntime()
    for (const dir of tempDirs.splice(0)) {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  function setStateDir(): string {
    const stateDir = mkdtempSync(path.join(os.tmpdir(), "openclaw-inline-routes-"))
    tempDirs.push(stateDir)
    setInlineRuntime({
      state: {
        resolveStateDir: () => stateDir,
      },
      logging: {
        getChildLogger: () => ({ warn: vi.fn() }),
      },
    } as any)
    return stateDir
  }

  function writeRoutesFile(stateDir: string, updatedAt: number): void {
    const routesDir = path.join(stateDir, "inline", "reply-thread-routes")
    mkdirSync(routesDir, { recursive: true })
    writeFileSync(
      path.join(routesDir, "default.json"),
      JSON.stringify({
        version: 1,
        routes: {
          "default:parent:7000:agent:__any__": {
            accountId: "default",
            parentChatId: "7000",
            threadId: "7100",
            createdAt: updatedAt,
            updatedAt,
          },
        },
      }),
    )
  }

  it("records and looks up active routes in memory", async () => {
    rememberInlineReplyThreadRoute({
      accountId: "default",
      parentChatId: 7000n,
      threadId: 7100n,
      parentMessageId: 700001n,
      agentId: "main",
    })

    await expect(
      lookupInlineReplyThreadRoute({
        accountId: "default",
        parentChatId: 7000n,
        parentMessageId: 700001n,
        agentId: "main",
      }),
    ).resolves.toMatchObject({
      accountId: "default",
      parentChatId: "7000",
      threadId: "7100",
      parentMessageId: "700001",
      agentId: "main",
    })
  })

  it("does not use an active route for a different parent message", async () => {
    rememberInlineReplyThreadRoute({
      accountId: "default",
      parentChatId: 7000n,
      threadId: 7100n,
      parentMessageId: 700001n,
      agentId: "main",
    })

    await expect(
      lookupInlineReplyThreadRoute({
        accountId: "default",
        parentChatId: 7000n,
        parentMessageId: 700002n,
        agentId: "main",
      }),
    ).resolves.toBeNull()
  })

  it("reads active route files when keyed store is unavailable", async () => {
    const stateDir = setStateDir()
    writeRoutesFile(stateDir, Date.now())

    await expect(
      lookupInlineReplyThreadRoute({
        accountId: "default",
        parentChatId: 7000n,
      }),
    ).resolves.toMatchObject({
      accountId: "default",
      parentChatId: "7000",
      threadId: "7100",
    })
  })

  it("ignores expired route files", async () => {
    const stateDir = setStateDir()
    writeRoutesFile(stateDir, Date.now() - 8 * 24 * 60 * 60 * 1000)

    await expect(
      lookupInlineReplyThreadRoute({
        accountId: "default",
        parentChatId: 7000n,
      }),
    ).resolves.toBeNull()
  })
})
