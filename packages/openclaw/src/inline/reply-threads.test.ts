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
})
