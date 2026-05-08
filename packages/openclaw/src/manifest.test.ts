import { describe, expect, it } from "vitest"
import { readFile } from "node:fs/promises"
import path from "node:path"

describe("plugin manifest", () => {
  it("openclaw.plugin.json declares the inline plugin + channel", async () => {
    const manifestPath = path.resolve(__dirname, "..", "openclaw.plugin.json")
    const raw = await readFile(manifestPath, "utf8")
    const json = JSON.parse(raw) as { id?: unknown; channels?: unknown }

    expect(json.id).toBe("inline")
    expect(json.channels).toEqual(["inline"])
  })

  it("declares the minimum OpenClaw host that has the sender metadata prompt path", async () => {
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
