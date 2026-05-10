import { describe, expect, it } from "vitest"
import { readFile } from "node:fs/promises"
import path from "node:path"

describe("plugin manifest", () => {
  it("openclaw.plugin.json declares the inline plugin + channel", async () => {
    const manifestPath = path.resolve(__dirname, "..", "openclaw.plugin.json")
    const raw = await readFile(manifestPath, "utf8")
    const json = JSON.parse(raw) as {
      id?: unknown
      channels?: unknown
      contracts?: { tools?: unknown }
      channelConfigs?: {
        inline?: {
          schema?: {
            additionalProperties?: unknown
            properties?: Record<string, { additionalProperties?: unknown; properties?: Record<string, unknown> }>
          }
        }
      }
    }

    expect(json.id).toBe("inline")
    expect(json.channels).toEqual(["inline"])
    expect(json.contracts?.tools).toContain("inline_members")
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

    expect(schema?.properties).toHaveProperty("accounts")
    expect(schema?.properties).toHaveProperty("streaming")
    expect(schema?.additionalProperties).not.toBe(false)
    expect(streamingObject?.additionalProperties).not.toBe(false)
    expect(preview?.additionalProperties).not.toBe(false)
    expect(preview?.properties?.chunk?.additionalProperties).not.toBe(false)
    expect(progress?.additionalProperties).not.toBe(false)
    expect(block?.additionalProperties).not.toBe(false)
    expect(block?.properties?.coalesce?.additionalProperties).not.toBe(false)
  })

  it("declares the minimum OpenClaw host required by the Inline metadata path", async () => {
    const packagePath = path.resolve(__dirname, "..", "package.json")
    const raw = await readFile(packagePath, "utf8")
    const json = JSON.parse(raw) as {
      openclaw?: { install?: { minHostVersion?: unknown } }
      peerDependencies?: { openclaw?: unknown }
    }

    expect(json.openclaw?.install?.minHostVersion).toBe(">=2026.4.26")
    expect(json.peerDependencies?.openclaw).toBe(">=2026.4.26")
  })
})
