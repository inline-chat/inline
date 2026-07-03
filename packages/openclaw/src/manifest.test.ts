import { describe, expect, it } from "vitest"
import { readFile } from "node:fs/promises"
import path from "node:path"
import { buildJsonChannelConfigSchema } from "openclaw/plugin-sdk/core"

function collectRefs(value: unknown, path: string[] = []): string[] {
  if (!value || typeof value !== "object") {
    return []
  }
  if (Array.isArray(value)) {
    return value.flatMap((entry, index) => collectRefs(entry, [...path, String(index)]))
  }
  const record = value as Record<string, unknown>
  const own = typeof record.$ref === "string" ? [path.join(".") || "<root>"] : []
  return own.concat(
    Object.entries(record).flatMap(([key, entry]) => collectRefs(entry, [...path, key])),
  )
}

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
            additionalProperties?: unknown
            properties?: Record<string, { additionalProperties?: unknown; properties?: Record<string, unknown> }>
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
    expect(json.contracts?.tools).toEqual(
      expect.arrayContaining([
        "inline_members",
        "inline_update_profile",
        "inline_bot_avatar",
        "inline_bot_commands",
        "inline_nudge",
        "inline_forward",
        "inline_bot_presence",
        "inline_parent_context",
      ]),
    )
    expect(json.channelEnvVars?.inline).toEqual(["INLINE_TOKEN", "INLINE_BOT_TOKEN"])
    const schema = json.channelConfigs?.inline?.schema
    const streaming = schema?.properties?.streaming as
      | {
          anyOf?: Array<{
            type?: unknown
            additionalProperties?: unknown
            properties?: Record<string, { additionalProperties?: unknown; properties?: Record<string, unknown> }>
          }>
        }
      | undefined
    const streamingObject = streaming?.anyOf?.find((entry) => entry.properties?.mode)
    const streamingString = streaming?.anyOf?.find((entry) => entry.type === "string")
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
    expect(collectRefs(schema)).toEqual([])
    expect(schema?.additionalProperties).not.toBe(false)
    expect(accounts?.additionalProperties?.type).toBe("object")
    expect(accounts?.additionalProperties?.additionalProperties).toBe(true)
    expect(accounts?.additionalProperties?.properties?.token).toEqual(schema?.properties?.token)
    expect(accounts?.additionalProperties?.properties?.capabilities).toEqual(
      schema?.properties?.capabilities,
    )
    expect(accounts?.additionalProperties?.properties?.replyThreadMode).toEqual(
      schema?.properties?.replyThreadMode,
    )
    expect(accounts?.additionalProperties?.properties?.replyThreadAutoCreateMinMessages).toEqual(
      schema?.properties?.replyThreadAutoCreateMinMessages,
    )
    expect(accounts?.additionalProperties?.properties?.replyThreadRequireExplicitMention).toEqual(
      schema?.properties?.replyThreadRequireExplicitMention,
    )
    expect(accounts?.additionalProperties?.properties?.replyThreadParentHistoryLimit).toEqual(
      schema?.properties?.replyThreadParentHistoryLimit,
    )
    expect(accounts?.additionalProperties?.properties?.dmPolicy).toEqual(
      schema?.properties?.dmPolicy,
    )
    expect(accounts?.additionalProperties?.properties?.defaultTo).toEqual(
      schema?.properties?.defaultTo,
    )
    expect(accounts?.additionalProperties?.properties?.streaming).toEqual(
      schema?.properties?.streaming,
    )
    expect(streamingString).toEqual({ type: "string" })
    expect(accounts?.additionalProperties?.properties?.reactionNotifications).toEqual(
      schema?.properties?.reactionNotifications,
    )
    expect(accounts?.additionalProperties?.properties?.reactionAllowlist).toEqual(
      schema?.properties?.reactionAllowlist,
    )
    expect(accounts?.additionalProperties?.properties?.debounceMs).toEqual(
      schema?.properties?.debounceMs,
    )
    expect(accounts?.additionalProperties?.properties?.voiceTranscriptWaitMs).toEqual(
      schema?.properties?.voiceTranscriptWaitMs,
    )
    expect(accounts?.additionalProperties?.properties?.commands).toEqual(
      schema?.properties?.commands,
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
    expect(schema?.properties?.debounceMs).toEqual({
      type: "integer",
      minimum: 0,
    })
    expect(schema?.properties?.voiceTranscriptWaitMs).toEqual({
      type: "integer",
      minimum: 0,
      maximum: 60000,
    })
    expect(schema?.properties?.actions?.properties?.translate).toEqual({
      type: "boolean",
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
    expect(json.channelConfigs?.inline?.uiHints?.replyThreadParentHistoryLimit?.help).toContain(
      "Defaults to 10",
    )
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

    expect(json.openclaw?.install?.minHostVersion).toBe(">=2026.6.11")
    expect(json.peerDependencies?.openclaw).toBe(">=2026.6.11")
    expect(json.peerDependenciesMeta?.openclaw?.optional).toBe(true)
    expect(json.openclaw?.compat?.pluginApi).toBe(">=2026.6.11")
    expect(json.openclaw?.build?.openclawVersion).toBe("2026.6.11")
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
