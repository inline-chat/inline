import { createHash } from "node:crypto"
import { execFileSync } from "node:child_process"
import { mkdir, readFile, writeFile } from "node:fs/promises"
import path from "node:path"
import { fileURLToPath } from "node:url"

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..")
const outputDir = path.resolve(process.argv[2] ?? "")
if (!process.argv[2]) throw new Error("usage: pack-public-packages.mjs OUTPUT_DIR")
await mkdir(outputDir, { recursive: true })

const packages = [
  "packages/protocol",
  "packages/bot-api-types",
  "packages/sdk",
  "packages/bot-client",
  "plugins/openclaw",
  "plugins/chat-sdk-plugin",
]
const artifacts = []
for (const relative of packages) {
  const packageDir = path.join(repoRoot, relative)
  const packed = JSON.parse(execFileSync("npm", ["pack", "--ignore-scripts", "--json", "--pack-destination", outputDir], {
    cwd: packageDir, encoding: "utf8", stdio: ["ignore", "pipe", "inherit"],
  }))[0]
  if (!packed?.filename || !Array.isArray(packed.files)) throw new Error(`invalid npm pack manifest: ${relative}`)
  const manifest = JSON.parse(await readFile(path.join(packageDir, "package.json"), "utf8"))
  if (packed.name !== manifest.name || packed.version !== manifest.version) throw new Error(`identity mismatch: ${relative}`)
  artifacts.push(await receipt(relative, manifest, packed.filename, packed.files.map((file) => file.path)))
}

const sdk = artifacts.find((artifact) => artifact.name === "@inline-chat/realtime-sdk")
const protocol = artifacts.find((artifact) => artifact.name === "@inline-chat/protocol")
if (!sdk || !protocol) throw new Error("candidate SDK/protocol tarballs are missing")
execFileSync("node", [path.join(repoRoot, "plugins/hermes-agent/scripts/release-stage.mjs"),
  "--prepare-only", "--output-dir", outputDir,
  "--candidate-sdk-tarball", path.join(outputDir, sdk.file),
  "--candidate-protocol-tarball", path.join(outputDir, protocol.file)], {
  cwd: repoRoot, stdio: "inherit",
})
const hermesManifest = JSON.parse(await readFile(path.join(repoRoot, "plugins/hermes-agent/package.json"), "utf8"))
const hermesFile = `${hermesManifest.name.replace(/^@/, "").replace("/", "-")}-${hermesManifest.version}.tgz`
artifacts.push(await receipt("plugins/hermes-agent", hermesManifest, hermesFile))

await writeFile(path.join(outputDir, "manifest.json"), JSON.stringify({
  sourceSha: execFileSync("git", ["rev-parse", "HEAD"], { cwd: repoRoot, encoding: "utf8" }).trim(),
  packages: artifacts,
}, null, 2) + "\n")
console.log(`Packed ${artifacts.length} candidate packages from ${artifacts[0]?.file} through ${hermesFile}`)

async function receipt(relative, manifest, file, packedFiles) {
  const bytes = await readFile(path.join(outputDir, file))
  return {
    path: relative,
    name: manifest.name,
    version: manifest.version,
    file,
    sha256: createHash("sha256").update(bytes).digest("hex"),
    ...(packedFiles ? { fileCount: packedFiles.length } : {}),
  }
}
