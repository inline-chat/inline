import { describe, expect, it } from "vitest"
import type { OpenClawConfig } from "openclaw/plugin-sdk"
import { mkdtemp, symlink, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import path from "node:path"
import {
  findInlineTokenOwnerAccountId,
  formatDuplicateInlineTokenReason,
  inspectInlineAccount,
  listInlineAccountIds,
  resolveDefaultInlineAccountId,
  resolveInlineAccount,
  resolveInlineToken,
} from "./accounts"

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

  it("uses the first configured account as default when base config is absent", () => {
    const cfg = {
      channels: {
        inline: {
          accounts: { work: { token: "work-token" } },
        },
      },
    } satisfies OpenClawConfig

    expect(resolveDefaultInlineAccountId(cfg)).toBe("work")
    const account = resolveInlineAccount({ cfg, accountId: null })
    expect(account.accountId).toBe("work")
    expect(account.configured).toBe(true)
    expect(account.token).toBe("work-token")
  })

  it("does not prioritize default account when only baseUrl is set on base config", () => {
    const cfg = {
      channels: {
        inline: {
          baseUrl: "https://api.inline.chat",
          accounts: { work: { token: "work-token" } },
        },
      },
    } satisfies OpenClawConfig

    expect(resolveDefaultInlineAccountId(cfg)).toBe("work")
    const account = resolveInlineAccount({ cfg, accountId: null })
    expect(account.accountId).toBe("work")
    expect(account.token).toBe("work-token")
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

  it("normalizes account ids and resolves account overrides case-insensitively", () => {
    const cfg = {
      channels: {
        inline: {
          accounts: {
            "Work Bot": { token: "a-token", name: "Work Bot" },
          },
        },
      },
    } satisfies OpenClawConfig

    expect(listInlineAccountIds(cfg)).toEqual(["work-bot"])

    const account = resolveInlineAccount({ cfg, accountId: "work bot" })
    expect(account.accountId).toBe("work-bot")
    expect(account.configured).toBe(true)
    expect(account.token).toBe("a-token")
    expect(account.name).toBe("Work Bot")
  })

  it("does not fall back to the top-level token for unknown accounts when accounts are configured", () => {
    const cfg = {
      channels: {
        inline: {
          token: "base-token",
          accounts: {
            work: { token: "work-token" },
          },
        },
      },
    } satisfies OpenClawConfig

    const account = resolveInlineAccount({ cfg, accountId: "missing" })

    expect(account.accountId).toBe("missing")
    expect(account.configured).toBe(false)
    expect(account.token).toBeNull()
    expect(account.tokenSource).toBe("none")
  })

  it("detects duplicate concrete bot token owners in multi-account setups", () => {
    const cfg = {
      channels: {
        inline: {
          token: "base-token",
          accounts: {
            alerts: { name: "Alerts" },
            ops: { token: "base-token" },
            work: { token: "work-token" },
          },
        },
      },
    } satisfies OpenClawConfig

    expect(findInlineTokenOwnerAccountId({ cfg, accountId: "default" })).toBeNull()
    expect(findInlineTokenOwnerAccountId({ cfg, accountId: "alerts" })).toBe("default")
    expect(findInlineTokenOwnerAccountId({ cfg, accountId: "ops" })).toBe("default")
    expect(findInlineTokenOwnerAccountId({ cfg, accountId: "work" })).toBeNull()
    expect(
      formatDuplicateInlineTokenReason({
        accountId: "ops",
        ownerAccountId: "default",
      }),
    ).toBe(
      'Duplicate Inline bot token: account "ops" shares a token with account "default". Keep one owner account per Inline bot token.',
    )
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

  it("uses INLINE_TOKEN and INLINE_BOT_TOKEN for the default account", () => {
    const previousToken = process.env.INLINE_TOKEN
    const previousBotToken = process.env.INLINE_BOT_TOKEN
    try {
      delete process.env.INLINE_TOKEN
      process.env.INLINE_BOT_TOKEN = "env-bot-token"

      const cfg = {
        channels: {
          inline: {
            enabled: true,
          },
        },
      } satisfies OpenClawConfig

      expect(listInlineAccountIds(cfg)).toEqual(["default"])
      expect(resolveDefaultInlineAccountId(cfg)).toBe("default")
      expect(resolveInlineAccount({ cfg, accountId: "default" })).toEqual(
        expect.objectContaining({
          configured: true,
          token: "env-bot-token",
          tokenSource: "env",
        }),
      )

      process.env.INLINE_TOKEN = "env-token"
      expect(resolveInlineAccount({ cfg, accountId: "default" }).token).toBe("env-token")
      expect(resolveInlineAccount({ cfg, accountId: "default" }).tokenSource).toBe("env")
    } finally {
      if (previousToken === undefined) {
        delete process.env.INLINE_TOKEN
      } else {
        process.env.INLINE_TOKEN = previousToken
      }
      if (previousBotToken === undefined) {
        delete process.env.INLINE_BOT_TOKEN
      } else {
        process.env.INLINE_BOT_TOKEN = previousBotToken
      }
    }
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
    expect(account.tokenSource).toBe("config")

    await expect(resolveInlineToken(account)).resolves.toBe("from-config")
  })

  it("resolves env SecretRef token config for read-only account status", () => {
    const cfg = {
      secrets: {
        providers: {
          default: {
            source: "env",
            allowlist: ["INLINE_TOKEN"],
          },
        },
      },
      channels: {
        inline: {
          token: { source: "env", provider: "default", id: "INLINE_TOKEN" },
        },
      },
    } satisfies OpenClawConfig

    const account = resolveInlineAccount({
      cfg,
      accountId: "default",
      env: { INLINE_TOKEN: "from-secret-ref" },
    })

    expect(account.configured).toBe(true)
    expect(account.token).toBe("from-secret-ref")
    expect(account.tokenSource).toBe("env")
  })

  it("keeps unresolved SecretRef token config unavailable for runtime use", async () => {
    const cfg = {
      channels: {
        inline: {
          token: { source: "file", provider: "default", id: "inline-token" },
        },
      },
    } satisfies OpenClawConfig

    const account = resolveInlineAccount({ cfg, accountId: "default", env: {} })

    expect(account.configured).toBe(false)
    expect(account.token).toBeNull()
    expect(account.tokenSource).toBe("config")
    expect(account.tokenConfigured).toBe(true)
    await expect(resolveInlineToken(account)).rejects.toThrow(
      "Inline token is configured but unavailable",
    )
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
    expect(account.tokenSource).toBe("file")

    await expect(resolveInlineToken(account)).resolves.toBe("file-token")
    expect(inspectInlineAccount({ cfg, accountId: "default" })).toEqual(
      expect.objectContaining({
        configured: true,
        token: "file-token",
        tokenSource: "file",
        tokenStatus: "available",
      }),
    )
  })

  it("uses account tokenFile instead of inheriting the top-level token", async () => {
    const dir = await mkdtemp(path.join(tmpdir(), "openclaw-inline-account-token-"))
    const tokenPath = path.join(dir, "account-token.txt")
    await writeFile(tokenPath, "account-file-token\n", "utf8")

    const cfg = {
      channels: {
        inline: {
          token: "base-token",
          accounts: {
            ops: {
              tokenFile: tokenPath,
            },
          },
        },
      },
    } satisfies OpenClawConfig

    const account = resolveInlineAccount({ cfg, accountId: "ops" })

    expect(account.token).toBeNull()
    expect(account.tokenFile).toBe(tokenPath)
    expect(account.tokenSource).toBe("file")
    await expect(resolveInlineToken(account)).resolves.toBe("account-file-token")
    expect(inspectInlineAccount({ cfg, accountId: "ops" })).toEqual(
      expect.objectContaining({
        configured: true,
        token: "account-file-token",
        tokenSource: "file",
        tokenStatus: "available",
      }),
    )
    expect(findInlineTokenOwnerAccountId({ cfg, accountId: "ops" })).toBeNull()
  })

  it.runIf(process.platform !== "win32")("resolveInlineToken rejects symlinked tokenFile paths", async () => {
    const dir = await mkdtemp(path.join(tmpdir(), "openclaw-inline-token-"))
    const tokenPath = path.join(dir, "token.txt")
    const linkPath = path.join(dir, "token-link.txt")
    await writeFile(tokenPath, "file-token\n", "utf8")
    await symlink(tokenPath, linkPath)

    const cfg = {
      channels: {
        inline: {
          tokenFile: linkPath,
        },
      },
    } satisfies OpenClawConfig
    const account = resolveInlineAccount({ cfg, accountId: "default" })

    expect(account.configured).toBe(true)
    expect(inspectInlineAccount({ cfg, accountId: "default" })).toEqual(
      expect.objectContaining({
        configured: false,
        token: null,
        tokenSource: "file",
        tokenStatus: "configured_unavailable",
      }),
    )
    await expect(resolveInlineToken(account)).rejects.toThrow(
      "Inline tokenFile is empty or unreadable",
    )
  })

  it("does not fall back to the top-level token when an account SecretRef is unavailable", () => {
    const cfg = {
      channels: {
        inline: {
          token: "base-token",
          accounts: {
            ops: {
              token: { source: "file", provider: "default", id: "ops-token" },
            },
          },
        },
      },
    } satisfies OpenClawConfig

    const account = resolveInlineAccount({ cfg, accountId: "ops", env: {} })

    expect(account.configured).toBe(false)
    expect(account.token).toBeNull()
    expect(account.tokenSource).toBe("config")
    expect(account.tokenConfigured).toBe(true)
    expect(inspectInlineAccount({ cfg, accountId: "ops", env: {} })).toEqual(
      expect.objectContaining({
        configured: false,
        token: null,
        tokenSource: "config",
        tokenStatus: "configured_unavailable",
      }),
    )
    expect(findInlineTokenOwnerAccountId({ cfg, accountId: "ops", env: {} })).toBeNull()
  })

  it("inspects unresolved SecretRef tokens as configured but unavailable", () => {
    const cfg = {
      channels: {
        inline: {
          token: { source: "file", provider: "default", id: "inline-token" },
        },
      },
    } satisfies OpenClawConfig

    expect(inspectInlineAccount({ cfg, accountId: "default", env: {} })).toEqual(
      expect.objectContaining({
        configured: false,
        token: null,
        tokenSource: "config",
        tokenStatus: "configured_unavailable",
        tokenConfigured: true,
      }),
    )
  })
})
