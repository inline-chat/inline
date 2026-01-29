import { copyFile, mkdir, readFile, rm } from "fs/promises"
import { dirname, relative, resolve } from "path"
import { fileURLToPath } from "url"

type WorkspacesField = string[] | { packages?: string[] }

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..")
const outputArg = process.argv[2]
const outputDir = resolve(root, outputArg ?? "build/docker-workspaces")

const rootPackageJsonPath = resolve(root, "package.json")
const rootPackageJson = JSON.parse(await readFile(rootPackageJsonPath, "utf8")) as {
  workspaces?: WorkspacesField
}
const workspacesField = rootPackageJson.workspaces
const workspacePatterns = Array.isArray(workspacesField) ? workspacesField : workspacesField?.packages ?? []

if (workspacePatterns.length === 0) {
  console.error("No workspaces found in root package.json.")
  process.exit(1)
}

await rm(outputDir, { recursive: true, force: true })
await mkdir(outputDir, { recursive: true })

const seen = new Set<string>()
let copied = 0

for (const pattern of workspacePatterns) {
  const normalized = pattern.replace(/\/$/, "")
  const manifestPattern = normalized.endsWith("package.json") ? normalized : `${normalized}/package.json`
  const glob = new Bun.Glob(manifestPattern)

  for await (const match of glob.scan({ cwd: root, absolute: true, onlyFiles: true })) {
    const relPath = relative(root, match)
    if (seen.has(relPath)) continue

    const destPath = resolve(outputDir, relPath)
    await mkdir(dirname(destPath), { recursive: true })
    await copyFile(match, destPath)
    seen.add(relPath)
    copied += 1
  }
}

if (copied === 0) {
  console.error("No workspace package.json files matched the workspaces configuration.")
  process.exit(1)
}

const relativeOutput = relative(root, outputDir) || "."
console.info(`Copied ${copied} workspace package.json file(s) to ${relativeOutput}.`)
