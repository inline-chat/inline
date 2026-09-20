import { copyFile, cp, mkdir, readFile, stat, writeFile } from "fs/promises"
import { basename, dirname, relative, resolve } from "path"
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
const [workspaceName, outputArg, mode] = process.argv.slice(2)
const manifestsOnly = mode === "--manifests-only"
if (mode && !manifestsOnly) throw new Error(`Unknown option: ${mode}`)

if (!workspaceName || !outputArg) {
  console.error("Usage: bun scripts/docker/prune-workspace.ts <workspace-name> <output-dir>")
  process.exit(1)
}

const outputDir = resolve(repoRoot, outputArg)
const jsonDir = resolve(outputDir, "json")
const fullDir = resolve(outputDir, "full")
const rootPackageJsonPath = resolve(repoRoot, "package.json")
const rootPackageJson = JSON.parse(await readFile(rootPackageJsonPath, "utf8")) as PackageJson
const allWorkspaces = await loadWorkspacePackages(rootPackageJson.workspaces)
const targetWorkspace = allWorkspaces.byName.get(workspaceName)

if (!targetWorkspace) {
  console.error(`Workspace not found: ${workspaceName}`)
  process.exit(1)
}

const selectedWorkspacePaths = collectWorkspaceClosure(targetWorkspace.name, allWorkspaces.byName)

if (await exists(outputDir)) throw new Error(`Output directory already exists: ${outputDir}`)
await mkdir(jsonDir, { recursive: true })
await mkdir(fullDir, { recursive: true })

// Keep the complete manifest graph and committed resolutions. Filtering the
// install is safe; resolving a new lockfile here silently upgrades dependencies.
const installPackageJson = {
  ...rootPackageJson,
  trustedDependencies: ["esbuild", "msgpackr-extract", "sharp"],
}
await writeJson(resolve(jsonDir, "package.json"), installPackageJson)
await writeJson(resolve(fullDir, "package.json"), installPackageJson)
for (const name of ["bun.lock", "bunfig.toml"]) {
  await copyFile(resolve(repoRoot, name), resolve(jsonDir, name))
  await copyFile(resolve(repoRoot, name), resolve(fullDir, name))
}

for (const { relPath } of allWorkspaces.byName.values()) {
  const dest = resolve(jsonDir, relPath, "package.json")
  await mkdir(dirname(dest), { recursive: true })
  await copyFile(resolve(repoRoot, relPath, "package.json"), dest)
}

if (!manifestsOnly) {
  for (const workspacePath of selectedWorkspacePaths) {
    await cp(resolve(repoRoot, workspacePath), resolve(fullDir, workspacePath), {
      recursive: true,
      dereference: true,
      filter: shouldCopyWorkspaceEntry,
    })
  }
  const smokePath = "scripts/docker/smoke-artifact.ts"
  await mkdir(dirname(resolve(fullDir, smokePath)), { recursive: true })
  await copyFile(resolve(repoRoot, smokePath), resolve(fullDir, smokePath))
}
console.info(`Prepared ${workspaceName} with the committed lockfile (${selectedWorkspacePaths.length} source workspaces).`)

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
    const packageJsonPath = `${normalized}/package.json`

    if (!hasGlob(normalized)) {
      if (!(await exists(resolve(repoRoot, packageJsonPath)))) {
        throw new Error(`Missing workspace manifest: ${packageJsonPath}`)
      }
      await addWorkspacePackage(byName, packageJsonPath)
      continue
    }

    const glob = new Bun.Glob(`${normalized}/package.json`)

    for await (const match of glob.scan({ cwd: repoRoot, onlyFiles: true })) {
      await addWorkspacePackage(byName, match)
    }
  }

  return { byName }
}

async function addWorkspacePackage(
  byName: Map<string, { name: string; relPath: string; packageJson: PackageJson }>,
  packageJsonRelPath: string,
) {
  const relPath = relative(repoRoot, resolve(repoRoot, packageJsonRelPath))
  const workspacePath = dirname(relPath)
  const packageJson = JSON.parse(await readFile(resolve(repoRoot, relPath), "utf8")) as PackageJson

  if (!packageJson.name) {
    return
  }

  byName.set(packageJson.name, {
    name: packageJson.name,
    relPath: workspacePath,
    packageJson,
  })
}

async function exists(path: string): Promise<boolean> {
  try {
    await stat(path)
    return true
  } catch {
    return false
  }
}

function hasGlob(pattern: string): boolean {
  return /[*?[\]{}]/.test(pattern)
}

function shouldCopyWorkspaceEntry(path: string): boolean {
  const name = basename(path)
  return !name.startsWith(".env") && name !== ".output" && name !== ".git" && name !== ".build" && name !== "target" && name !== "node_modules" && name !== "dist" && name !== ".turbo" && name !== ".DS_Store" && !name.endsWith(".tsbuildinfo")
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
