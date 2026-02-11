import { describe, expect, it } from "vitest"
import { readFile } from "node:fs/promises"
import path from "node:path"

describe("plugin manifest", () => {
  it("openclaw.plugin.json declares the inline plugin + channel", async () => {
    const manifestPath = path.resolve(__dirname, "..", "openclaw.plugin.json")
    const raw = await readFile(manifestPath, "utf8")
    const json = JSON.parse(raw) as { id?: unknown; channels?: unknown }

    expect(json.id).toBe("openclaw-inline")
    expect(json.channels).toEqual(["inline"])
  })
})
