import { copyFile, cp, mkdir, readFile, rm, writeFile } from "fs/promises"
import { dirname, relative, resolve } from "path"
import { fileURLToPath } from "url"

type WorkspacesField = string[] | { packages?: string[] }
type PackageJson = {
  name?: string
  workspaces?: WorkspacesField
  dependencies?: Record<string, string>
  devDependencies?: Record<string, string>
  optionalDependencies?: Record<string, string>
  peerDependencies?: Record<string, string>
}

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..")
const [workspaceName, outputArg] = process.argv.slice(2)

if (!workspaceName || !outputArg) {
  console.error("Usage: bun scripts/docker/prune-workspace.ts <workspace-name> <output-dir>")
  process.exit(1)
}

const outputDir = resolve(repoRoot, outputArg)
const jsonDir = resolve(outputDir, "json")
const fullDir = resolve(outputDir, "full")
const rootPackageJsonPath = resolve(repoRoot, "package.json")
const rootLockfilePath = resolve(repoRoot, "bun.lock")
const rootPackageJson = JSON.parse(await readFile(rootPackageJsonPath, "utf8")) as PackageJson
const allWorkspaces = await loadWorkspacePackages(rootPackageJson.workspaces)
const targetWorkspace = allWorkspaces.byName.get(workspaceName)

if (!targetWorkspace) {
  console.error(`Workspace not found: ${workspaceName}`)
  process.exit(1)
}

const selectedWorkspacePaths = collectWorkspaceClosure(targetWorkspace.name, allWorkspaces.byName)

await rm(outputDir, { recursive: true, force: true })
await mkdir(jsonDir, { recursive: true })
await mkdir(fullDir, { recursive: true })

const prunedRootPackageJson = {
  ...rootPackageJson,
  workspaces: selectedWorkspacePaths,
}

await writeJson(resolve(jsonDir, "package.json"), prunedRootPackageJson)
await writeJson(resolve(fullDir, "package.json"), prunedRootPackageJson)

for (const workspacePath of selectedWorkspacePaths) {
  const jsonPackagePath = resolve(jsonDir, workspacePath, "package.json")
  await mkdir(dirname(jsonPackagePath), { recursive: true })
  await copyFile(resolve(repoRoot, workspacePath, "package.json"), jsonPackagePath)
  await cp(resolve(repoRoot, workspacePath), resolve(fullDir, workspacePath), { recursive: true })
}

await regenerateLockfile(jsonDir, resolve(outputDir, "bun.lock"))

async function regenerateLockfile(installDir: string, outputLockfilePath: string) {
  await copyFile(rootLockfilePath, resolve(installDir, "bun.lock"))

  const install = Bun.spawn(["bun", "install", "--lockfile-only"], {
    cwd: installDir,
    stdout: "inherit",
    stderr: "inherit",
  })

  const exitCode = await install.exited
  if (exitCode !== 0) {
    process.exit(exitCode)
  }

  await copyFile(resolve(installDir, "bun.lock"), outputLockfilePath)
}

async function loadWorkspacePackages(workspacesField: WorkspacesField | undefined) {
  const patterns = Array.isArray(workspacesField) ? workspacesField : workspacesField?.packages ?? []
  const byName = new Map<
    string,
    {
      name: string
      relPath: string
      packageJson: PackageJson
    }
  >()

  for (const pattern of patterns) {
    const normalized = pattern.replace(/\/$/, "")
    const glob = new Bun.Glob(`${normalized}/package.json`)

    for await (const match of glob.scan({ cwd: repoRoot, onlyFiles: true })) {
      const relPath = relative(repoRoot, resolve(repoRoot, match))
      const workspacePath = dirname(relPath)
      const packageJson = JSON.parse(await readFile(resolve(repoRoot, relPath), "utf8")) as PackageJson

      if (!packageJson.name) {
        continue
      }

      byName.set(packageJson.name, {
        name: packageJson.name,
        relPath: workspacePath,
        packageJson,
      })
    }
  }

  return { byName }
}

function collectWorkspaceClosure(
  entryName: string,
  byName: Map<string, { name: string; relPath: string; packageJson: PackageJson }>,
) {
  const selected = new Set<string>()
  const queue = [entryName]

  while (queue.length > 0) {
    const currentName = queue.shift()
    if (!currentName) continue

    const workspace = byName.get(currentName)
    if (!workspace || selected.has(workspace.relPath)) {
      continue
    }

    selected.add(workspace.relPath)

    for (const section of [
      workspace.packageJson.dependencies,
      workspace.packageJson.devDependencies,
      workspace.packageJson.optionalDependencies,
      workspace.packageJson.peerDependencies,
    ]) {
      for (const dependencyName of Object.keys(section ?? {})) {
        if (byName.has(dependencyName)) {
          queue.push(dependencyName)
        }
      }
    }
  }

  return [...selected].sort()
}

async function writeJson(path: string, data: unknown) {
  await mkdir(dirname(path), { recursive: true })
  await writeFile(path, `${JSON.stringify(data, null, 2)}\n`)
}
