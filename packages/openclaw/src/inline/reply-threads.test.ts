import { describe, expect, it } from "vitest"
import type { OpenClawConfig } from "openclaw/plugin-sdk"
import {
  getInlineReplyThreadsCapabilityConfig,
  isInlineReplyThreadsEnabled,
} from "./reply-threads"

describe("inline/reply-threads", () => {
  it("defaults replyThreads to false when unset", () => {
    expect(
      isInlineReplyThreadsEnabled({
        cfg: {
          channels: {
            inline: {},
          },
        } as OpenClawConfig,
      }),
    ).toBe(false)
  })

  it("reads the top-level replyThreads capability", () => {
    expect(
      isInlineReplyThreadsEnabled({
        cfg: {
          channels: {
            inline: {
              capabilities: {
                replyThreads: true,
              },
            },
          },
        } as OpenClawConfig,
      }),
    ).toBe(true)
  })

  it("prefers account-level replyThreads over the base config", () => {
    const cfg = {
      channels: {
        inline: {
          token: "base-token",
          capabilities: {
            replyThreads: false,
          },
          accounts: {
            work: {
              token: "work-token",
              capabilities: {
                replyThreads: true,
              },
            },
          },
        },
      },
    } as OpenClawConfig

    expect(isInlineReplyThreadsEnabled({ cfg, accountId: "work" })).toBe(true)
    expect(getInlineReplyThreadsCapabilityConfig({ cfg, accountId: "work" })).toEqual({
      replyThreads: true,
    })
  })

  it("enables reply-thread handling when placement mode is configured", () => {
    expect(
      isInlineReplyThreadsEnabled({
        cfg: {
          channels: {
            inline: {
              replyThreadMode: "thread",
            },
          },
        } as OpenClawConfig,
      }),
    ).toBe(true)

    expect(
      isInlineReplyThreadsEnabled({
        cfg: {
          channels: {
            inline: {
              groups: {
                "123": { replyThreadMode: "main" },
              },
            },
          },
        } as OpenClawConfig,
      }),
    ).toBe(true)
  })

  it("enables reply-thread handling when reply-thread policy is configured", () => {
    expect(
      isInlineReplyThreadsEnabled({
        cfg: {
          channels: {
            inline: {
              replyThreadRequireExplicitMention: false,
            },
          },
        } as OpenClawConfig,
      }),
    ).toBe(true)

    expect(
      isInlineReplyThreadsEnabled({
        cfg: {
          channels: {
            inline: {
              groups: {
                "123": { replyThreadParentHistoryLimit: 2 },
              },
            },
          },
        } as OpenClawConfig,
      }),
    ).toBe(true)
  })

  it("uses account-level placement mode when resolving reply-thread handling", () => {
    const cfg = {
      channels: {
        inline: {
          token: "base-token",
          accounts: {
            work: {
              token: "work-token",
              groups: {
                "123": { replyThreadMode: "thread" },
              },
            },
          },
        },
      },
    } as OpenClawConfig

    expect(isInlineReplyThreadsEnabled({ cfg, accountId: "work" })).toBe(true)
    expect(isInlineReplyThreadsEnabled({ cfg, accountId: "missing" })).toBe(false)
  })
})
