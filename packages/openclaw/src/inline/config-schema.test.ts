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
    expect(
      InlineConfigSchema.safeParse({
        accounts: {
          work: { dmPolicy: "open", allowFrom: ["2"] },
        },
      }).success,
    ).toBe(false)
  })

  it("runtime schema remains lenient so token-only setup does not get dropped", () => {
    expect(
      InlineRuntimeConfigSchema.safeParse({ token: "t", dmPolicy: "open" }).success,
    ).toBe(true)
  })

  it("runtime schema tolerates future host fields without dropping known Inline config", () => {
    const result = InlineRuntimeConfigSchema.safeParse({
      token: "t",
      futureHostField: true,
      streaming: {
        mode: "progress",
        futureModeOption: "host-owned",
        preview: {
          toolProgress: false,
          futurePreviewOption: true,
        },
        block: {
          coalesce: {
            minChars: 500,
            futureCoalesceOption: "ok",
          },
        },
      },
      accounts: {
        work: {
          token: "work-token",
          futureAccountField: "ok",
          streaming: {
            mode: "block",
            futureAccountStreamingField: true,
          },
        },
      },
    })

    expect(result.success).toBe(true)
  })

  it("channel config schema tolerates unknown host-owned fields but rejects bad known streaming values", () => {
    expect(
      InlineConfigSchema.safeParse({
        token: "t",
        futureHostField: true,
        streaming: {
          mode: "progress",
          futureModeOption: "host-owned",
          preview: {
            toolProgress: false,
            futurePreviewOption: true,
          },
        },
        accounts: {
          work: {
            token: "work-token",
            futureAccountField: true,
            streaming: {
              mode: "partial",
              futureAccountStreamingField: true,
            },
          },
        },
      }).success,
    ).toBe(true)

    expect(InlineConfigSchema.safeParse({ streaming: "stream" }).success).toBe(false)
    expect(InlineConfigSchema.safeParse({ streaming: { mode: "stream" } }).success).toBe(false)
    expect(
      InlineConfigSchema.safeParse({
        streaming: { progress: { commandText: "hidden" } },
      }).success,
    ).toBe(false)
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
        streaming: {
          mode: "progress",
          chunkMode: "newline",
          preview: {
            chunk: { minChars: 200, maxChars: 800, breakPreference: "paragraph" },
            toolProgress: false,
            commandText: "status",
          },
          progress: {
            label: "Working",
            labels: ["Working", "Reading"],
            maxLines: 4,
            render: "text",
            toolProgress: false,
            commandText: "status",
          },
          block: {
            enabled: true,
            coalesce: { minChars: 600, idleMs: 700, maxChars: 2_200 },
          },
        },
        streamMode: "block",
        draftChunk: { minChars: 200, maxChars: 800, breakPreference: "sentence" },
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

  it("accepts legacy scalar streaming aliases for older OpenClaw configs", () => {
    expect(InlineConfigSchema.safeParse({ streaming: "partial" }).success).toBe(true)
    expect(InlineConfigSchema.safeParse({ streaming: false }).success).toBe(true)
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
})
