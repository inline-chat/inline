import { describe, expect, it } from "vitest"
import type { OpenClawConfig } from "openclaw/plugin-sdk"
import { mkdtemp, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import path from "node:path"
import { listInlineAccountIds, resolveDefaultInlineAccountId, resolveInlineAccount, resolveInlineToken } from "./accounts"

describe("inline/accounts", () => {
  it("lists default account when base config is present", () => {
    const cfg = {
      channels: {
        inline: { token: "t" },
      },
    } satisfies OpenClawConfig
    expect(listInlineAccountIds(cfg)).toEqual(["default"])
  })

  it("lists account overrides as well", () => {
    const cfg = {
      channels: {
        inline: {
          token: "t",
          accounts: {
            a: { token: "a" },
            " b ": { token: "b" },
          },
        },
      },
    } satisfies OpenClawConfig
    expect(listInlineAccountIds(cfg).sort()).toEqual(["a", "b", "default"])
  })

  it("chooses default as the default account when present", () => {
    const cfg = {
      channels: {
        inline: {
          token: "t",
          accounts: { a: { token: "a" } },
        },
      },
    } satisfies OpenClawConfig
    expect(resolveDefaultInlineAccountId(cfg)).toBe("default")
  })

  it("merges base config into account overrides", () => {
    const cfg = {
      channels: {
        inline: {
          name: "base",
          baseUrl: "https://api.inline.chat",
          token: "base-token",
          parseMarkdown: false,
          accounts: {
            a: { name: "A", token: "a-token" },
          },
        },
      },
    } satisfies OpenClawConfig

    const a = resolveInlineAccount({ cfg, accountId: "a" })
    expect(a.accountId).toBe("a")
    expect(a.name).toBe("A")
    expect(a.baseUrl).toBe("https://api.inline.chat")
    expect(a.token).toBe("a-token")
    expect(a.config.parseMarkdown).toBe(false)
  })

  it("keeps token-based setup available even when dmPolicy=open has no allowFrom", () => {
    const cfg = {
      channels: {
        inline: {
          token: "t",
          dmPolicy: "open",
        },
      },
    } satisfies OpenClawConfig

    expect(listInlineAccountIds(cfg)).toEqual(["default"])
    const account = resolveInlineAccount({ cfg, accountId: "default" })
    expect(account.configured).toBe(true)
    expect(account.token).toBe("t")
  })

  it("resolveInlineToken prefers inline token over tokenFile", async () => {
    const cfg = {
      channels: {
        inline: {
          token: "from-config",
          tokenFile: "/tmp/ignored",
        },
      },
    } satisfies OpenClawConfig
    const account = resolveInlineAccount({ cfg, accountId: "default" })

    await expect(resolveInlineToken(account)).resolves.toBe("from-config")
  })

  it("resolveInlineToken reads tokenFile when inline token is absent", async () => {
    const dir = await mkdtemp(path.join(tmpdir(), "openclaw-inline-token-"))
    const tokenPath = path.join(dir, "token.txt")
    await writeFile(tokenPath, "file-token\n", "utf8")

    const cfg = {
      channels: {
        inline: {
          tokenFile: tokenPath,
        },
      },
    } satisfies OpenClawConfig
    const account = resolveInlineAccount({ cfg, accountId: "default" })

    await expect(resolveInlineToken(account)).resolves.toBe("file-token")
  })
})
