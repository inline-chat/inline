import { describe, expect, it, vi } from "vitest"
import type { OpenClawConfig } from "openclaw/plugin-sdk"
import {
  createInlineReplyThreadForMessage,
  getInlineReplyThreadsCapabilityConfig,
  resolveInlineReplyThreadChatId,
  isInlineReplyThreadsEnabled,
} from "./reply-threads"

describe("inline/reply-threads", () => {
  it("retries an unknown anchored-create outcome once and recovers the server child", async () => {
    const invokeRaw = vi.fn()
      .mockRejectedValueOnce(Object.assign(new Error("response lost"), { code: "commit-outcome-unknown" }))
      .mockResolvedValueOnce({
        oneofKind: "createSubthread",
        createSubthread: {
          chat: { id: 73n, parentChatId: 7n, parentMessageId: 3n, title: "Reply" },
          anchorMessage: null,
        },
      })
    await expect(createInlineReplyThreadForMessage({
      client: { invokeRaw } as any,
      parentChatId: 7n,
      parentMessageId: 3n,
    })).resolves.toMatchObject({ childChatId: 73n, parentChatId: 7n, parentMessageId: 3n })
    expect(invokeRaw).toHaveBeenCalledTimes(2)
  })

  it("does not retry a definite anchored-create rejection", async () => {
    const invokeRaw = vi.fn().mockRejectedValue(Object.assign(new Error("denied"), { code: "forbidden" }))
    await expect(createInlineReplyThreadForMessage({
      client: { invokeRaw } as any,
      parentChatId: 7n,
      parentMessageId: 3n,
    })).rejects.toThrow("denied")
    expect(invokeRaw).toHaveBeenCalledTimes(1)
  })

  it.each(["", "invalid", "0", "-1", "+1", "0x10", 0, -1, Number.MAX_SAFE_INTEGER + 1])("rejects an invalid explicit child instead of sending to its parent: %s", (threadId) => {
    expect(() => resolveInlineReplyThreadChatId({ cfg: {}, parentChatId: 7n, threadId })).toThrow("invalid reply-thread")
  })

  it("treats Inline reply threads as available by default", () => {
    expect(
      isInlineReplyThreadsEnabled({
        cfg: {
          channels: {
            inline: {},
          },
        } as OpenClawConfig,
      }),
    ).toBe(true)
  })

  it("keeps reply threads available even when legacy capability config is false", () => {
    expect(
      isInlineReplyThreadsEnabled({
        cfg: {
          channels: {
            inline: {
              capabilities: {
                replyThreads: false,
              },
            },
          },
        } as OpenClawConfig,
      }),
    ).toBe(true)
  })

  it("does not use account-level capability config as a tool/routing gate", () => {
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
    expect(isInlineReplyThreadsEnabled({ cfg, accountId: "missing" })).toBe(true)
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
              replyThreadAutoCreateMinMessages: 25,
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
                "123": { replyThreadAutoCreateMinMessages: 2 },
                "456": { replyThreadParentHistoryLimit: 2 },
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
    expect(isInlineReplyThreadsEnabled({ cfg, accountId: "missing" })).toBe(true)
  })
})
