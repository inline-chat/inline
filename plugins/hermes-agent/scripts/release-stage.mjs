import { chmod, cp, mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises"
import { createHash } from "node:crypto"
import os from "node:os"
import path from "node:path"
import { execFileSync } from "node:child_process"
import { fileURLToPath } from "node:url"

const packageRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")
const repoRoot = path.resolve(packageRoot, "..", "..")
const { mode, outputDir: requestedOutputDir, candidateSdkTarball, candidateProtocolTarball } = parseArgs(process.argv.slice(2))
const stageRoot = await mkdtemp(path.join(os.tmpdir(), "inline-hermes-release-"))
const stagePackageRoot = path.join(stageRoot, "plugins", "hermes-agent")
const outputDir = requestedOutputDir == null
  ? path.join(stageRoot, "artifact")
  : path.resolve(requestedOutputDir)
const packageJson = JSON.parse(await readFile(path.join(packageRoot, "package.json"), "utf8"))
const prereleaseTag = String(packageJson.version || "").split("-", 2)[1]?.split(".", 1)[0]

const stageEntries = [
  "LICENSE",
  "README.md",
  "RELEASE.md",
  "package.json",
  "plugin",
  "scripts",
  "src",
  "tests",
  "tsconfig.json",
  "vitest.config.ts",
]

await mkdir(stagePackageRoot, { recursive: true })
await mkdir(outputDir, { recursive: true })
for (const entry of stageEntries) {
  await cp(path.join(packageRoot, entry), path.join(stagePackageRoot, entry), {
    recursive: true,
    filter(source) {
      const relative = path.relative(packageRoot, source)
      const parts = relative.split(path.sep)
      if (parts.some((part) => part === ".env" || part.startsWith(".env."))) {
        return false
      }
      return relative !== path.join("plugin", "inline", "sidecar", "index.mjs")
    },
  })
}
await cp(path.join(repoRoot, ".oxlintignore"), path.join(stageRoot, ".oxlintignore"))

if (candidateSdkTarball || candidateProtocolTarball) {
  if (!candidateSdkTarball || !candidateProtocolTarball) {
    throw new Error("candidate staging requires both SDK and protocol tarballs")
  }
  await writeFile(path.join(stagePackageRoot, "package.json"), JSON.stringify({
    ...packageJson,
    dependencies: {
      ...packageJson.dependencies,
      "@inline-chat/realtime-sdk": `file:${path.resolve(candidateSdkTarball)}`,
      "@inline-chat/protocol": `file:${path.resolve(candidateProtocolTarball)}`,
    },
  }, null, 2))
}
execFileSync("npm", ["install", "--ignore-scripts", "--no-audit", "--no-fund"], {
  cwd: stagePackageRoot,
  stdio: "inherit",
})
if (candidateSdkTarball || candidateProtocolTarball) {
  // Restore publishable registry specs before checking and packing. Only the
  // disposable install graph uses local files from this source SHA.
  await writeFile(path.join(stagePackageRoot, "package.json"), JSON.stringify(packageJson, null, 2) + "\n")
  const installedSdk = JSON.parse(await readFile(path.join(stagePackageRoot, "node_modules", "@inline-chat", "realtime-sdk", "package.json"), "utf8"))
  const installedProtocol = JSON.parse(await readFile(path.join(stagePackageRoot, "node_modules", "@inline-chat", "protocol", "package.json"), "utf8"))
  if (installedSdk.version !== packageJson.dependencies["@inline-chat/realtime-sdk"] ||
      installedProtocol.version !== JSON.parse(await readFile(path.join(repoRoot, "packages", "protocol", "package.json"), "utf8")).version) {
    throw new Error("candidate dependency versions do not match the release manifest")
  }
}
execFileSync("bun", ["run", "check"], {
  cwd: stagePackageRoot,
  stdio: "inherit",
})

const packed = JSON.parse(execFileSync("npm", [
  "pack",
  "--ignore-scripts",
  "--json",
  "--silent",
  "--pack-destination",
  outputDir,
], {
  cwd: stagePackageRoot,
  encoding: "utf8",
  stdio: ["ignore", "pipe", "pipe"],
}))[0]
if (!packed?.filename || !Array.isArray(packed.files)) {
  throw new Error("npm pack did not return one artifact manifest")
}
const artifactPath = path.join(outputDir, packed.filename)
const artifactBytes = await readFile(artifactPath)
const artifactSha256 = createHash("sha256").update(artifactBytes).digest("hex")
await chmod(artifactPath, 0o444)

if (mode === "--dry-run") {
  const publishArgs = ["publish", "--dry-run", "--ignore-scripts", "--access", "public", artifactPath]
  if (prereleaseTag) publishArgs.push("--tag", prereleaseTag)
  execFileSync("npm", publishArgs, {
    cwd: outputDir,
    stdio: "inherit",
  })
}

console.log(`Hermes release stage: ${stagePackageRoot}`)
console.log(`Hermes release artifact: ${artifactPath}`)
console.log(`Hermes release artifact sha256: ${artifactSha256}`)
console.log(`Hermes release artifact files: ${packed.files.map((file) => file.path).sort().join(",")}`)

function parseArgs(argv) {
  let mode = "--dry-run"
  let outputDir
  let candidateSdkTarball
  let candidateProtocolTarball
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index]
    if (arg === "--dry-run" || arg === "--prepare-only") {
      mode = arg
      continue
    }
    if (arg === "--output-dir") {
      const value = argv[++index]
      if (!value || value.startsWith("--")) throw new Error("--output-dir requires a path")
      outputDir = value
      continue
    }
    if (arg === "--candidate-sdk-tarball" || arg === "--candidate-protocol-tarball") {
      const value = argv[++index]
      if (!value || value.startsWith("--")) throw new Error(`${arg} requires a path`)
      if (arg === "--candidate-sdk-tarball") candidateSdkTarball = value
      else candidateProtocolTarball = value
      continue
    }
    throw new Error(`unknown argument: ${arg}`)
  }
  return { mode, outputDir, candidateSdkTarball, candidateProtocolTarball }
}
