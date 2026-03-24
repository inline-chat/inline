import { access, readFile, writeFile } from "fs/promises"
import { dirname, resolve } from "path"
import { fileURLToPath } from "url"

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..")
const [workspaceName, outputArg] = process.argv.slice(2)

if (!workspaceName || !outputArg) {
  console.error("Usage: bun scripts/docker/prune-workspace.ts <workspace-name> <output-dir>")
  process.exit(1)
}

const outputDir = resolve(repoRoot, outputArg)

const prune = Bun.spawn(["bunx", "turbo", "prune", workspaceName, "--docker", "--out-dir", outputDir], {
  cwd: repoRoot,
  stdout: "inherit",
  stderr: "inherit",
})

const exitCode = await prune.exited
if (exitCode !== 0) {
  process.exit(exitCode)
}

await patchWorkspaces(resolve(outputDir, "json/package.json"))
await patchWorkspaces(resolve(outputDir, "full/package.json"))

async function patchWorkspaces(packageJsonPath: string) {
  const packageJson = JSON.parse(await readFile(packageJsonPath, "utf8")) as {
    workspaces?: string[] | { packages?: string[] }
  }

  if (!packageJson.workspaces) {
    return
  }

  const packages = Array.isArray(packageJson.workspaces)
    ? packageJson.workspaces
    : packageJson.workspaces.packages ?? []

  const prunedRoot = dirname(packageJsonPath)
  const filtered = []

  for (const workspace of packages) {
    const exists = workspace.includes("*")
      ? await pathExists(resolve(prunedRoot, workspace.slice(0, workspace.indexOf("*")).replace(/\/$/, "")))
      : await pathExists(resolve(prunedRoot, workspace, "package.json"))

    if (exists) {
      filtered.push(workspace)
    }
  }

  packageJson.workspaces = Array.isArray(packageJson.workspaces)
    ? filtered
    : { ...packageJson.workspaces, packages: filtered }

  await writeFile(packageJsonPath, `${JSON.stringify(packageJson, null, 2)}\n`)
}

async function pathExists(path: string) {
  try {
    await access(path)
    return true
  } catch {
    return false
  }
}
