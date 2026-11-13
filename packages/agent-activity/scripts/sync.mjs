// Copies the renderer into each plugin that bundles it. Published plugins
// resolve every dependency from the registry (scripts/ci/stage-npm-release.mjs,
// plugins/hermes-agent/scripts/release-stage.mjs), so they carry a copy instead
// of a workspace dependency. `--check` fails when a copy is out of date.
import { mkdir, readdir, readFile, rm, writeFile } from "node:fs/promises"
import path from "node:path"
import { fileURLToPath } from "node:url"

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..")
const sourceDir = path.join(repoRoot, "packages/agent-activity/src")
const targets = ["plugins/openclaw/src/vendor/agent-activity", "plugins/hermes-agent/src/vendor/agent-activity"]

// Keep in step with each plugin's agent-activity-copy test.
export const HEADER = "// Generated from packages/agent-activity/src by `bun run sync` there. Edit the source, not this copy.\n"
export const vendored = (source) => HEADER + source.replaceAll('from "@inline-chat/protocol"', 'from "@inline-chat/realtime-sdk"')

const check = process.argv.includes("--check")
const files = (await readdir(sourceDir)).filter((name) => name.endsWith(".ts") && !name.endsWith(".test.ts")).sort()
const stale = []
for (const target of targets) {
  const dir = path.join(repoRoot, target)
  await mkdir(dir, { recursive: true })
  const existing = new Set((await readdir(dir)).filter((name) => name.endsWith(".ts")))
  for (const name of files) {
    existing.delete(name)
    const expected = vendored(await readFile(path.join(sourceDir, name), "utf8"))
    const current = await readFile(path.join(dir, name), "utf8").catch(() => null)
    if (current === expected) continue
    stale.push(path.join(target, name))
    if (!check) await writeFile(path.join(dir, name), expected)
  }
  for (const name of existing) {
    stale.push(path.join(target, name))
    if (!check) await rm(path.join(dir, name))
  }
}
if (check && stale.length > 0) {
  console.error(`agent-activity copies are out of date (run \`bun run sync\` in packages/agent-activity):\n${stale.join("\n")}`)
  process.exitCode = 1
} else {
  console.log(stale.length > 0 ? `Updated:\n${stale.join("\n")}` : "agent-activity copies are up to date")
}
