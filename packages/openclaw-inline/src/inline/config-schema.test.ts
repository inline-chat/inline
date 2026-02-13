import { describe, expect, it } from "vitest"
import { InlineAccountSchema, InlineConfigSchema, InlineRuntimeConfigSchema } from "./config-schema"

describe("inline/config-schema", () => {
  it("accepts dmPolicy=open only when allowFrom includes *", () => {
    expect(
      InlineConfigSchema.safeParse({ dmPolicy: "open", allowFrom: ["*"] }).success,
    ).toBe(true)
    expect(InlineConfigSchema.safeParse({ dmPolicy: "open", allowFrom: ["1"] }).success).toBe(
      false,
    )
  })

  it("accounts schema applies the same open allowFrom rule", () => {
    expect(
      InlineAccountSchema.safeParse({ dmPolicy: "open", allowFrom: ["*"] }).success,
    ).toBe(true)
    expect(
      InlineAccountSchema.safeParse({ dmPolicy: "open", allowFrom: ["2"] }).success,
    ).toBe(false)
  })

  it("runtime schema remains lenient so token-only setup does not get dropped", () => {
    expect(
      InlineRuntimeConfigSchema.safeParse({ token: "t", dmPolicy: "open" }).success,
    ).toBe(true)
  })

  it("accepts streaming and group tool-policy fields", () => {
    expect(
      InlineConfigSchema.safeParse({
        mediaMaxMb: 10,
        actions: {
          read: true,
          channels: true,
          permissions: false,
        },
        blockStreaming: true,
        chunkMode: "newline",
        blockStreamingCoalesce: { minChars: 600, idleMs: 700, maxChars: 2_200 },
        replyToBotWithoutMention: true,
        historyLimit: 12,
        dmHistoryLimit: 6,
        groups: {
          "123": {
            requireMention: false,
            tools: { allow: ["message", "web.search"] },
            toolsBySender: {
              "42": { allow: ["message"] },
            },
          },
        },
      }).success,
    ).toBe(true)
  })
})
