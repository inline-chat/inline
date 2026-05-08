import { readFileSync } from "node:fs"
import { describe, expect, it } from "vitest"
import { InlineAccountSchema, InlineConfigSchema, InlineRuntimeConfigSchema } from "./config-schema"

describe("inline/config-schema", () => {
  it("accepts top-level reply thread capability config", () => {
    expect(
      InlineConfigSchema.safeParse({
        capabilities: {
          replyThreads: true,
        },
      }).success,
    ).toBe(true)
  })

  it("accepts account-level reply thread capability config", () => {
    expect(
      InlineConfigSchema.safeParse({
        accounts: {
          work: {
            capabilities: {
              replyThreads: true,
            },
          },
        },
      }).success,
    ).toBe(true)
  })

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
      InlineAccountSchema.safeParse({
        dmPolicy: "open",
        allowFrom: ["*"],
        capabilities: { replyThreads: true },
      }).success,
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
          send: true,
          read: true,
          channels: true,
          permissions: false,
        },
        blockStreaming: true,
        streamViaEditMessage: true,
        chunkMode: "newline",
        commands: {
          native: false,
          nativeSkills: true,
        },
        blockStreamingCoalesce: { minChars: 600, idleMs: 700, maxChars: 2_200 },
        replyToBotWithoutMention: true,
        historyLimit: 25,
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

  it("accepts top-level and group systemPrompt fields", () => {
    expect(
      InlineConfigSchema.safeParse({
        systemPrompt: "Keep replies natural.",
        groups: {
          "123": {
            requireMention: false,
            systemPrompt: "Do not wrap bare URLs in backticks.",
            tools: { allow: ["message"] },
          },
        },
      }).success,
    ).toBe(true)
  })

  it("keeps the manifest channel config schema in sync", () => {
    const manifest = JSON.parse(
      readFileSync(new URL("../../openclaw.plugin.json", import.meta.url), "utf8"),
    ) as { channelConfigs?: { inline?: { schema?: unknown } } }

    expect(manifest.channelConfigs?.inline?.schema).toEqual(
      InlineConfigSchema.toJSONSchema({
        target: "draft-07",
        unrepresentable: "any",
      }),
    )
  })
})
