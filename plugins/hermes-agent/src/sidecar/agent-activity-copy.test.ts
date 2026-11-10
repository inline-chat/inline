import { existsSync, readdirSync, readFileSync } from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"
import { describe, expect, it } from "vitest"

// The renderer is a generated copy of packages/agent-activity (see its
// scripts/sync.mjs). Isolated release staging has no packages/ tree; skip there.
const here = path.dirname(fileURLToPath(import.meta.url))
const sourceDir = path.resolve(here, "../../../../packages/agent-activity/src")
const copyDir = path.resolve(here, "../vendor/agent-activity")
const HEADER = "// Generated from packages/agent-activity/src by `bun run sync` there. Edit the source, not this copy.\n"
const vendored = (source: string) => HEADER + source.replaceAll('from "@inline-chat/protocol"', 'from "@inline-chat/realtime-sdk"')
const sourceFiles = (dir: string) => readdirSync(dir).filter((name) => name.endsWith(".ts") && !name.endsWith(".test.ts")).sort()

describe.skipIf(!existsSync(sourceDir))("agent-activity copy", () => {
  it("matches packages/agent-activity (run `bun run sync` there)", () => {
    expect(sourceFiles(copyDir)).toEqual(sourceFiles(sourceDir))
    for (const name of sourceFiles(sourceDir)) {
      expect(readFileSync(path.join(copyDir, name), "utf8"), name).toBe(vendored(readFileSync(path.join(sourceDir, name), "utf8")))
    }
  })
})
