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

  it("accepts reply thread mode defaults and group overrides", () => {
    expect(
      InlineConfigSchema.safeParse({
        capabilities: { replyThreads: true },
        replyThreadMode: "auto",
        replyThreadAutoCreateMinMessages: 50,
        groups: {
          "*": { replyThreadMode: "thread", replyThreadAutoCreateMinMessages: 20 },
          "123": { replyThreadMode: "main", replyThreadAutoCreateMinMessages: 0 },
        },
        accounts: {
          work: {
            capabilities: { replyThreads: true },
            replyThreadMode: "main",
            replyThreadAutoCreateMinMessages: 100,
            groups: {
              "456": { replyThreadMode: "thread", replyThreadAutoCreateMinMessages: 10 },
            },
          },
        },
      }).success,
    ).toBe(true)

    expect(InlineConfigSchema.safeParse({ replyThreadMode: "parent" }).success).toBe(false)
    expect(
      InlineConfigSchema.safeParse({
        groups: {
          "123": { replyThreadMode: "reply" },
        },
      }).success,
    ).toBe(false)
    expect(InlineConfigSchema.safeParse({ replyThreadAutoCreateMinMessages: -1 }).success).toBe(false)
    expect(InlineConfigSchema.safeParse({ replyThreadAutoCreateMinMessages: 1.5 }).success).toBe(false)
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

  it("accepts SecretRef-shaped token config", () => {
    const ref = { source: "env", provider: "default", id: "INLINE_TOKEN" }

    expect(InlineConfigSchema.safeParse({ token: ref }).success).toBe(true)
    expect(
      InlineConfigSchema.safeParse({
        accounts: {
          work: { token: ref },
        },
      }).success,
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
        reactionNotifications: "allowlist",
        reactionAllowlist: ["51", "accessGroup:operators"],
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
            allowFrom: ["51", "accessGroup:operators"],
            tools: { allow: ["message", "web.search"] },
            toolsBySender: {
              "42": { allow: ["message"] },
            },
          },
        },
      }).success,
    ).toBe(true)
  })

  it("accepts native-compatible numeric allowlist entries", () => {
    expect(
      InlineConfigSchema.safeParse({
        allowFrom: [51, "52", "accessGroup:operators"],
        groupAllowFrom: [61, "62"],
        reactionNotifications: "allowlist",
        reactionAllowlist: [71, "72", "accessGroup:operators"],
        accounts: {
          work: {
            allowFrom: [81, "82"],
            groupAllowFrom: [91, "92"],
            groups: {
              "chat:100": {
                allowFrom: [93, "94"],
              },
            },
            reactionNotifications: "allowlist",
            reactionAllowlist: [101, "102"],
          },
        },
      }).success,
    ).toBe(true)
  })

  it("accepts top-level and account-level native exec approval config", () => {
    expect(
      InlineConfigSchema.safeParse({
        execApprovals: {
          enabled: "auto",
          approvers: [51, "user:52", "inline:user:53"],
          agentFilter: ["main"],
          sessionFilter: ["inline:"],
          target: "both",
        },
        accounts: {
          work: {
            execApprovals: {
              enabled: true,
              approvers: ["54"],
              target: "dm",
            },
          },
        },
      }).success,
    ).toBe(true)
    expect(
      InlineConfigSchema.safeParse({
        execApprovals: { enabled: "yes" },
      }).success,
    ).toBe(false)
    expect(
      InlineConfigSchema.safeParse({
        execApprovals: { target: "thread" },
      }).success,
    ).toBe(false)
  })

  it("accepts native-compatible default outbound targets", () => {
    expect(
      InlineConfigSchema.safeParse({
        defaultTo: 51,
        accounts: {
          work: {
            defaultTo: "chat:52",
          },
        },
      }).success,
    ).toBe(true)
    expect(InlineConfigSchema.safeParse({ defaultTo: false }).success).toBe(false)
  })

  it("accepts native-compatible reaction notification modes", () => {
    for (const mode of ["off", "own", "all", "allowlist"]) {
      expect(InlineConfigSchema.safeParse({ reactionNotifications: mode }).success).toBe(true)
      expect(
        InlineConfigSchema.safeParse({
          accounts: {
            work: { reactionNotifications: mode, reactionAllowlist: ["51"] },
          },
        }).success,
      ).toBe(true)
    }

    expect(InlineConfigSchema.safeParse({ reactionNotifications: "mentions" }).success).toBe(false)
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

  it("accepts mention-only group entries written by setup defaults", () => {
    expect(
      InlineConfigSchema.safeParse({
        groups: {
          "*": { requireMention: true },
          "123": { requireMention: false },
        },
      }).success,
    ).toBe(true)
  })
})
