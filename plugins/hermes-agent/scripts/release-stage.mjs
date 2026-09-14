import { chmod, cp, mkdir, mkdtemp, readFile } from "node:fs/promises"
import { createHash } from "node:crypto"
import os from "node:os"
import path from "node:path"
import { execFileSync } from "node:child_process"
import { fileURLToPath } from "node:url"

const packageRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")
const repoRoot = path.resolve(packageRoot, "..")
const { mode, outputDir: requestedOutputDir } = parseArgs(process.argv.slice(2))
const stageRoot = await mkdtemp(path.join(os.tmpdir(), "inline-hermes-release-"))
const stagePackageRoot = path.join(stageRoot, "hermes-agent")
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

execFileSync("npm", ["install", "--ignore-scripts", "--no-audit", "--no-fund"], {
  cwd: stagePackageRoot,
  stdio: "inherit",
})
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
    throw new Error(`unknown argument: ${arg}`)
  }
  return { mode, outputDir }
}
