import { resolve } from "node:path"
import { mkdirSync, writeFileSync } from "node:fs"
import { createTestEnvironment } from "./test-environment"
import { discoverTests } from "./test-discovery"

const serverRoot = resolve(import.meta.dir, "..")
const selected = discoverTests(serverRoot).filter((file) => file.lane === "effect").map((file) => file.path)
const reportDir = resolve(serverRoot, ".test-results")
const writeManifest = (status: "running" | "complete", exitCode: number | null) => {
  if (!process.env["CI"]) return
  mkdirSync(reportDir, { recursive: true })
  writeFileSync(resolve(reportDir, "effect-run.json"), JSON.stringify({
    lane: "effect", status, selected, batches: [{ report: "effect.xml", files: selected, exitCode }],
  }, null, 2) + "\n")
}
writeManifest("running", null)
const child = Bun.spawn({
  cmd: [resolve(serverRoot, "node_modules/.bin/vitest"), "run", "--config", "vitest.effect.config.ts", ...process.argv.slice(2)],
  cwd: serverRoot,
  env: createTestEnvironment(process.env),
  stdin: "inherit", stdout: "inherit", stderr: "inherit",
})
process.on("SIGINT", () => child.kill("SIGINT"))
process.on("SIGTERM", () => child.kill("SIGTERM"))
const exitCode = await child.exited
writeManifest("complete", exitCode)
process.exit(exitCode)
