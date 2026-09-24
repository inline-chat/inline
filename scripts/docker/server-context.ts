import { mkdir, writeFile } from "node:fs/promises"
import { resolve } from "node:path"

// An immutable, source-only context. Inspect tree metadata before reading blobs;
// environment files and credentials never enter the archive, even if tracked.
export function isBuildInput(path: string): boolean {
  const parts = path.split("/")
  if (
    parts.some(
      (part) =>
        part.startsWith(".") ||
        ["node_modules", "dist", "target", "coverage", "build", "id_rsa", "id_ed25519"].includes(part),
    )
  ) {
    return path === "server/Dockerfile.dockerignore"
  }
  return !/\.(env|pem|key|p12|pfx|tsbuildinfo|log|sqlite|db)$/i.test(path)
}

type TreeEntry = { mode: string; oid: string; path: string }
type Manifest = {
  name?: string
  workspaces?: string[]
  dependencies?: Record<string, string>
  devDependencies?: Record<string, string>
  peerDependencies?: Record<string, string>
  optionalDependencies?: Record<string, string>
}

async function git(root: string, args: string[]): Promise<string> {
  const child = Bun.spawn(["git", "-C", root, ...args], {
    stdout: "pipe",
    stderr: "pipe",
  })
  const [output, error] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text()])
  if ((await child.exited) !== 0) throw new Error(`Git failed: ${error.trim()}`)
  return output
}

export async function prepareServerContext(root: string, revision: string, destination: string) {
  const commit = (await git(root, ["rev-parse", "--verify", "--end-of-options", `${revision}^{commit}`])).trim()
  const entries = (await git(root, ["ls-tree", "-rz", "--full-tree", commit]))
    .split("\0")
    .filter(Boolean)
    .map((line): TreeEntry => {
      const separator = line.indexOf("\t")
      const [mode, , oid] = line.slice(0, separator).split(" ")
      return { mode: mode!, oid: oid!, path: line.slice(separator + 1) }
    })
  const byPath = new Map(entries.map((entry) => [entry.path, entry]))
  const manifest = async (path: string): Promise<Manifest> => {
    const entry = byPath.get(path)
    if (!entry || entry.mode !== "100644") throw new Error(`Missing regular manifest: ${path}`)
    return JSON.parse(await git(root, ["cat-file", "blob", entry.oid]))
  }
  const rootManifest = await manifest("package.json")
  const workspaces = new Map<string, { path: string; manifest: Manifest }>()
  for (const pattern of rootManifest.workspaces ?? []) {
    const glob = new Bun.Glob(`${pattern}/package.json`)
    const matches = entries.filter((entry) => isBuildInput(entry.path) && glob.match(entry.path))
    if (!matches.length) throw new Error(`Missing workspace: ${pattern}`)
    for (const entry of matches) {
      const value = await manifest(entry.path)
      if (value.name)
        workspaces.set(value.name, {
          path: entry.path.slice(0, -13),
          manifest: value,
        })
    }
  }
  const sources = new Set<string>()
  const visit = (name: string) => {
    const workspace = workspaces.get(name)
    if (!workspace || sources.has(workspace.path)) return
    sources.add(workspace.path)
    for (const section of ["dependencies", "devDependencies", "peerDependencies", "optionalDependencies"] as const) {
      for (const dependency of Object.keys(workspace.manifest[section] ?? {})) visit(dependency)
    }
  }
  if (!workspaces.has("@inline-chat/server")) throw new Error("Server workspace is missing")
  visit("@inline-chat/server")
  const required = new Set([
    "package.json",
    "bun.lock",
    "bunfig.toml",
    "server/Dockerfile",
    "server/Dockerfile.dockerignore",
    "scripts/docker/prune-workspace.ts",
    "scripts/docker/smoke-artifact.ts",
    ...[...workspaces.values()].map((workspace) => `${workspace.path}/package.json`),
  ])
  for (const path of required) if (!byPath.has(path)) throw new Error(`Missing build input at ${commit}: ${path}`)
  const selected = entries.filter(
    ({ path }) =>
      isBuildInput(path) && (required.has(path) || [...sources].some((source) => path.startsWith(`${source}/`))),
  )
  for (const entry of selected) {
    if (!["100644", "100755"].includes(entry.mode)) throw new Error(`Build inputs must be regular files: ${entry.path}`)
  }
  const output = resolve(destination)
  // Refuse to merge with any pre-existing directory or symlink.
  await mkdir(output)
  // Read only selected blobs. Unlike git archive, this is unaffected by
  // export-ignore/export-subst attributes and never traverses working files.
  for (const entry of selected) {
    const file = resolve(output, entry.path)
    await mkdir(resolve(file, ".."), { recursive: true })
    const child = Bun.spawn(["git", "-C", root, "cat-file", "blob", entry.oid], { stdout: "pipe", stderr: "pipe" })
    const content = await new Response(child.stdout).arrayBuffer()
    if ((await child.exited) !== 0) throw new Error(`Cannot export ${entry.path}`)
    await writeFile(file, Buffer.from(content), {
      mode: entry.mode === "100755" ? 0o755 : 0o644,
    })
  }
  await writeFile(resolve(output, "source.json"), `${JSON.stringify({ commit, files: selected }, null, 2)}\n`)
  console.info(`Prepared ${selected.length} committed files at ${output}; SOURCE_COMMIT=${commit}`)
  return { commit, files: selected.map((entry) => entry.path) }
}

if (import.meta.main) {
  const [revision, destination, ...extra] = process.argv.slice(2)
  if (!revision || !destination || extra.length)
    throw new Error("Usage: bun --no-env-file scripts/docker/server-context.ts <commit> <new-directory>")
  await prepareServerContext(resolve(import.meta.dir, "../.."), revision, destination)
}
