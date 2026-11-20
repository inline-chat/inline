import { execFileSync } from "node:child_process"
import { mkdir, mkdtemp, readFile } from "node:fs/promises"
import { createRegistry } from "./publish-npm-release.mjs"
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
const sdkPin = hermes.dependencies["@inline-chat/realtime-sdk"]
const registry = createRegistry()
// Published pins are immutable, even if the workspace has moved on without a
// version bump. Use local candidates only while qualifying an unpublished pin.
if (sdkPin === sdk.version && await registry.version(sdk.name, sdkPin) === null) {
  const protocolPin = sdk.dependencies["@inline-chat/protocol"]
  const publishedProtocol = await registry.version(protocol.name, protocolPin)
  if (!publishedProtocol && protocolPin !== protocol.version) {
    throw new Error("The unpublished protocol pin must match the workspace candidate")
  }
  execFileSync("bun", ["install", "--frozen-lockfile"], { cwd: repoRoot, stdio: "inherit" })
  for (const [relative, flag, registrySpec] of [
    ["packages/protocol", "--candidate-protocol-tarball", publishedProtocol && `${protocol.name}@${protocolPin}`],
    ["packages/sdk", "--candidate-sdk-tarball", null],
  ]) {
    const cwd = path.join(repoRoot, relative)
    execFileSync("bun", ["run", "build"], { cwd, stdio: "inherit" })
    const args = ["pack", "--ignore-scripts", "--json", "--pack-destination", outputDir]
    if (registrySpec) args.push(registrySpec, "--registry=https://registry.npmjs.org")
    const packed = JSON.parse(execFileSync("npm", args, {
      cwd, encoding: "utf8", stdio: ["ignore", "pipe", "inherit"],
    }))
    if (packed.length !== 1 || path.basename(packed[0]?.filename ?? "") !== packed[0]?.filename) {
      throw new Error(`Expected one candidate tarball from ${registrySpec || relative}`)
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
