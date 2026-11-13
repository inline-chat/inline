import { execFileSync } from "node:child_process"
import { mkdir, mkdtemp, readFile } from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { fileURLToPath } from "node:url"

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..")
if (process.argv.length > 3) throw new Error("usage: prepare-hermes-candidate.mjs [OUTPUT_DIR]")
const outputDir = process.argv[2] ? path.resolve(process.argv[2]) : await mkdtemp(path.join(os.tmpdir(), "inline-hermes-candidate-"))
await mkdir(outputDir, { recursive: true })
const manifest = async (relative) => JSON.parse(await readFile(path.join(repoRoot, relative, "package.json"), "utf8"))
const [hermes, sdk, protocol] = await Promise.all([
  manifest("plugins/hermes-agent"), manifest("packages/sdk"), manifest("packages/protocol"),
])
const candidates = []
if (hermes.dependencies["@inline-chat/realtime-sdk"] === sdk.version) {
  if (sdk.dependencies["@inline-chat/protocol"] !== protocol.version) {
    throw new Error("The candidate SDK must pin the candidate protocol version")
  }
  execFileSync("bun", ["install", "--frozen-lockfile"], { cwd: repoRoot, stdio: "inherit" })
  for (const [relative, flag] of [
    ["packages/protocol", "--candidate-protocol-tarball"],
    ["packages/sdk", "--candidate-sdk-tarball"],
  ]) {
    const cwd = path.join(repoRoot, relative)
    execFileSync("bun", ["run", "build"], { cwd, stdio: "inherit" })
    const packed = JSON.parse(execFileSync("npm", ["pack", "--ignore-scripts", "--json", "--pack-destination", outputDir], {
      cwd, encoding: "utf8", stdio: ["ignore", "pipe", "inherit"],
    }))
    if (packed.length !== 1 || path.basename(packed[0]?.filename ?? "") !== packed[0]?.filename) {
      throw new Error(`Expected one candidate tarball from ${relative}`)
    }
    candidates.push(flag, path.join(outputDir, packed[0].filename))
  }
}
// Tagged publication uses release-stage directly, with registry dependencies.
// Source CI can compare the tracked bundle before these exact candidates ship.
execFileSync("node", [path.join(repoRoot, "plugins/hermes-agent/scripts/release-stage.mjs"),
  "--prepare-only", "--verify-source-bundle", "--output-dir", outputDir, ...candidates], {
  cwd: repoRoot, stdio: "inherit",
})
