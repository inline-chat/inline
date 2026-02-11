import { describe, expect, it } from "vitest"
import type { OpenClawConfig } from "openclaw/plugin-sdk"
import { listInlineAccountIds, resolveDefaultInlineAccountId, resolveInlineAccount } from "./accounts"

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
})
