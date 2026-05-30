import { describe, expect, it } from "vitest"
import { readFile } from "node:fs/promises"
import path from "node:path"
import { buildJsonChannelConfigSchema } from "openclaw/plugin-sdk/core"

describe("plugin manifest", () => {
  it("openclaw.plugin.json declares the inline plugin + channel", async () => {
    const manifestPath = path.resolve(__dirname, "..", "openclaw.plugin.json")
    const raw = await readFile(manifestPath, "utf8")
    const json = JSON.parse(raw) as {
      id?: unknown
      description?: unknown
      channels?: unknown
      contracts?: { tools?: unknown }
      channelEnvVars?: { inline?: unknown }
      channelConfigs?: {
        inline?: {
          description?: unknown
          schema?: {
            $defs?: Record<string, unknown>
            additionalProperties?: unknown
            properties?: Record<string, { $ref?: unknown; additionalProperties?: unknown; properties?: Record<string, unknown> }>
          }
          uiHints?: {
            ""?: { help?: unknown }
            accounts?: { help?: unknown }
            token?: { help?: unknown }
            [key: string]: { help?: unknown } | undefined
          }
        }
      }
    }

    expect(json.id).toBe("inline")
    expect(json.description).toBe("Use OpenClaw from Inline DMs and chats with an Inline bot token.")
    expect(json.channels).toEqual(["inline"])
    expect(json.contracts?.tools).toContain("inline_members")
    expect(json.channelEnvVars?.inline).toEqual(["INLINE_TOKEN", "INLINE_BOT_TOKEN"])
    const schema = json.channelConfigs?.inline?.schema
    const streaming = schema?.properties?.streaming as
      | {
          anyOf?: Array<{
            additionalProperties?: unknown
            properties?: Record<string, { additionalProperties?: unknown; properties?: Record<string, unknown> }>
          }>
        }
      | undefined
    const streamingObject = streaming?.anyOf?.find((entry) => entry.properties?.mode)
    const preview = streamingObject?.properties?.preview as
      | { additionalProperties?: unknown; properties?: Record<string, { additionalProperties?: unknown }> }
      | undefined
    const progress = streamingObject?.properties?.progress as
      | { additionalProperties?: unknown }
      | undefined
    const block = streamingObject?.properties?.block as
      | { additionalProperties?: unknown; properties?: Record<string, { additionalProperties?: unknown }> }
      | undefined
    const accounts = schema?.properties?.accounts as
      | {
          additionalProperties?: {
            type?: unknown
            additionalProperties?: unknown
            properties?: Record<string, { $ref?: unknown }>
          }
        }
      | undefined

    expect(schema?.properties).toHaveProperty("accounts")
    expect(schema?.properties).toHaveProperty("streaming")
    expect(schema?.$defs).toHaveProperty("secretInput")
    expect(schema?.properties?.token?.$ref).toBe("#/$defs/secretInput")
    expect(schema?.additionalProperties).not.toBe(false)
    expect(accounts?.additionalProperties?.type).toBe("object")
    expect(accounts?.additionalProperties?.additionalProperties).toBe(true)
    expect(accounts?.additionalProperties?.properties?.token?.$ref).toBe("#/properties/token")
    expect(accounts?.additionalProperties?.properties?.capabilities?.$ref).toBe(
      "#/properties/capabilities",
    )
    expect(accounts?.additionalProperties?.properties?.replyThreadMode?.$ref).toBe(
      "#/properties/replyThreadMode",
    )
    expect(accounts?.additionalProperties?.properties?.replyThreadAutoCreateMinMessages?.$ref).toBe(
      "#/properties/replyThreadAutoCreateMinMessages",
    )
    expect(accounts?.additionalProperties?.properties?.replyThreadRequireExplicitMention?.$ref).toBe(
      "#/properties/replyThreadRequireExplicitMention",
    )
    expect(accounts?.additionalProperties?.properties?.replyThreadParentHistoryLimit?.$ref).toBe(
      "#/properties/replyThreadParentHistoryLimit",
    )
    expect(accounts?.additionalProperties?.properties?.dmPolicy?.$ref).toBe(
      "#/properties/dmPolicy",
    )
    expect(accounts?.additionalProperties?.properties?.defaultTo?.$ref).toBe(
      "#/properties/defaultTo",
    )
    expect(accounts?.additionalProperties?.properties?.streaming?.$ref).toBe(
      "#/properties/streaming",
    )
    expect(accounts?.additionalProperties?.properties?.reactionNotifications?.$ref).toBe(
      "#/properties/reactionNotifications",
    )
    expect(accounts?.additionalProperties?.properties?.reactionAllowlist?.$ref).toBe(
      "#/properties/reactionAllowlist",
    )
    expect(accounts?.additionalProperties?.properties?.commands?.$ref).toBe(
      "#/properties/commands",
    )
    expect(streamingObject?.additionalProperties).not.toBe(false)
    expect(preview?.additionalProperties).not.toBe(false)
    expect(preview?.properties?.chunk?.additionalProperties).not.toBe(false)
    expect(progress?.additionalProperties).not.toBe(false)
    expect(block?.additionalProperties).not.toBe(false)
    expect(block?.properties?.coalesce?.additionalProperties).not.toBe(false)
    expect(json.channelConfigs?.inline?.description).toBe(
      "Use OpenClaw from Inline DMs and chats with an Inline bot token.",
    )
    expect(json.channelConfigs?.inline?.uiHints?.[""]?.help).toBe(
      "Inline channel configuration for bot tokens, direct messages, group chats, and Inline-specific reply behavior.",
    )
    expect(json.channelConfigs?.inline?.uiHints?.accounts?.help).toContain(
      "Named Inline bot accounts",
    )
    expect(json.channelConfigs?.inline?.uiHints?.token?.help).toContain("INLINE_BOT_TOKEN")
    expect(schema?.properties?.allowFrom).toEqual({
      type: "array",
      items: { anyOf: [{ type: "string" }, { type: "number" }] },
    })
    expect(schema?.properties?.defaultTo).toEqual({
      anyOf: [{ type: "string" }, { type: "number" }],
    })
    expect(schema?.properties?.replyThreadMode).toEqual({
      type: "string",
      enum: ["auto", "thread", "main"],
    })
    expect(schema?.properties?.replyThreadAutoCreateMinMessages).toEqual({
      type: "integer",
      minimum: 0,
    })
    expect(schema?.properties?.replyThreadRequireExplicitMention).toEqual({
      type: "boolean",
    })
    expect(schema?.properties?.replyThreadParentHistoryLimit).toEqual({
      type: "integer",
      minimum: 0,
    })
    expect(schema?.properties?.groupAllowFrom).toEqual({
      type: "array",
      items: { anyOf: [{ type: "string" }, { type: "number" }] },
    })
    expect(schema?.properties?.reactionAllowlist).toEqual({
      type: "array",
      items: { anyOf: [{ type: "string" }, { type: "number" }] },
    })
    const hintCopy = Object.values(json.channelConfigs?.inline?.uiHints ?? {})
      .map((hint) => String(hint?.help ?? ""))
      .join("\n")
    expect(hintCopy).not.toMatch(/native channels|native slash|slash command/i)
  })

  it("manifest schema validates named account fields without closing future host fields", async () => {
    const manifestPath = path.resolve(__dirname, "..", "openclaw.plugin.json")
    const raw = await readFile(manifestPath, "utf8")
    const json = JSON.parse(raw) as {
      channelConfigs?: {
        inline?: {
          schema?: Record<string, unknown>
        }
      }
    }
    const schema = json.channelConfigs?.inline?.schema
    expect(schema).toBeTruthy()

    const runtime = buildJsonChannelConfigSchema(schema ?? {}, {
      cacheKey: "inline-manifest-test",
    }).runtime
    expect(
      runtime.safeParse({
        defaultTo: 43,
        accounts: {
          work: {
            token: { source: "env", provider: "default", id: "INLINE_TOKEN" },
            capabilities: { replyThreads: true },
            replyThreadMode: "thread",
            replyThreadAutoCreateMinMessages: 50,
            replyThreadRequireExplicitMention: false,
            replyThreadParentHistoryLimit: 0,
            streaming: {
              mode: "progress",
              futureModeOption: "host-owned",
            },
            reactionNotifications: "allowlist",
            allowFrom: [41],
            defaultTo: "chat:44",
            groupAllowFrom: [42],
            groups: {
              "chat:44": {
                allowFrom: [43],
                replyThreadMode: "main",
                replyThreadAutoCreateMinMessages: 0,
                replyThreadRequireExplicitMention: true,
                replyThreadParentHistoryLimit: 2,
              },
            },
            reactionAllowlist: [51],
            futureAccountField: true,
          },
        },
      }).success,
    ).toBe(true)

    const invalid = runtime.safeParse({
      accounts: {
        work: {
          reactionNotifications: "mentions",
        },
      },
    })
    expect(invalid.success).toBe(false)
    expect(
      invalid.issues.some((issue) => issue.path.join(".") === "accounts.work.reactionNotifications"),
    ).toBe(true)
  })

  it("declares the minimum OpenClaw host required by the Inline metadata path", async () => {
    const packagePath = path.resolve(__dirname, "..", "package.json")
    const raw = await readFile(packagePath, "utf8")
    const json = JSON.parse(raw) as {
      openclaw?: {
        install?: { minHostVersion?: unknown }
        compat?: { pluginApi?: unknown }
        build?: { openclawVersion?: unknown }
        release?: { publishToClawHub?: unknown; publishToNpm?: unknown }
        setupEntry?: unknown
        channel?: {
          quickstartAllowFrom?: unknown
          doctorCapabilities?: {
            dmAllowFromMode?: unknown
            groupModel?: unknown
            groupAllowFromFallbackToAllowFrom?: unknown
            warnOnEmptyGroupSenderAllowlist?: unknown
          }
          configuredState?: {
            env?: { anyOf?: unknown }
            specifier?: unknown
            exportName?: unknown
          }
        }
      }
      peerDependencies?: { openclaw?: unknown }
      peerDependenciesMeta?: { openclaw?: { optional?: unknown } }
      moltbot?: unknown
    }

    expect(json.openclaw?.install?.minHostVersion).toBe(">=2026.5.18")
    expect(json.peerDependencies?.openclaw).toBe(">=2026.5.18")
    expect(json.peerDependenciesMeta?.openclaw?.optional).toBe(true)
    expect(json.openclaw?.compat?.pluginApi).toBe(">=2026.5.18")
    expect(json.openclaw?.build?.openclawVersion).toBe("2026.5.18")
    expect(json.openclaw?.release?.publishToClawHub).toBe(true)
    expect(json.openclaw?.release?.publishToNpm).toBe(true)
    expect(json.moltbot).toBeUndefined()
    expect(json.openclaw?.setupEntry).toBe("./dist/setup-entry.js")
    expect(json.openclaw?.channel?.quickstartAllowFrom).toBe(true)
    expect(json.openclaw?.channel?.doctorCapabilities).toEqual({
      dmAllowFromMode: "topOrNested",
      groupModel: "hybrid",
      groupAllowFromFallbackToAllowFrom: false,
      warnOnEmptyGroupSenderAllowlist: true,
    })
    expect(json.openclaw?.channel?.configuredState?.env?.anyOf).toEqual([
      "INLINE_TOKEN",
      "INLINE_BOT_TOKEN",
    ])
    expect(json.openclaw?.channel?.configuredState?.specifier).toBe("./dist/configured-state.js")
    expect(json.openclaw?.channel?.configuredState?.exportName).toBe("hasInlineConfiguredState")
  })
})
