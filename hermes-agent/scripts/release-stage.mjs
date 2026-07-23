import { cp, mkdir, mkdtemp } from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { execFileSync } from "node:child_process"
import { fileURLToPath } from "node:url"

const packageRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")
const repoRoot = path.resolve(packageRoot, "..")
const stageRoot = await mkdtemp(path.join(os.tmpdir(), "inline-hermes-release-"))
const stagePackageRoot = path.join(stageRoot, "hermes-agent")
const mode = process.argv[2] ?? "--dry-run"

if (mode !== "--dry-run" && mode !== "--prepare-only") {
  throw new Error("Usage: node scripts/release-stage.mjs [--dry-run|--prepare-only]")
}

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
execFileSync("bun", ["run", "build"], {
  cwd: stagePackageRoot,
  stdio: "inherit",
})

if (mode === "--dry-run") {
  execFileSync("npm", ["publish", "--dry-run", "--access", "public"], {
    cwd: stagePackageRoot,
    stdio: "inherit",
  })
}

console.log(`Hermes release stage: ${stagePackageRoot}`)
