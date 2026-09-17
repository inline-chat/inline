import { dirname, join, resolve } from "node:path"
import { existsSync, realpathSync } from "node:fs"

type Manifest = { name: string; version: string; private?: boolean; dependencies?: Record<string, string>;
  optionalDependencies?: Record<string, string>; peerDependencies?: Record<string, string> }
type Advisory = { id: number; severity: string; vulnerable_versions: string; url: string; title: string }

const locate = (name: string, from: string): string | undefined => {
  for (let current = from; ; current = dirname(current)) {
    const path = join(current, "node_modules", name, "package.json")
    if (existsSync(path)) return realpathSync(path)
    if (dirname(current) === current) return undefined
  }
}

async function main() {
  const root = resolve(import.meta.dir, "../package.json")
  const pending = [root]
  const visited = new Set<string>()
  const installed = new Map<string, Set<string>>()
  while (pending.length) {
    const path = pending.pop()!
    if (visited.has(path)) continue
    visited.add(path)
    const manifest = await Bun.file(path).json() as Manifest
    if (!manifest.private && !manifest.name.startsWith("@inline-chat/")) {
      const versions = installed.get(manifest.name) ?? new Set<string>()
      versions.add(manifest.version)
      installed.set(manifest.name, versions)
    }
    for (const name of Object.keys({ ...manifest.dependencies, ...manifest.optionalDependencies, ...manifest.peerDependencies })) {
      const dependency = locate(name, dirname(path))
      if (dependency) pending.push(dependency)
      else if (manifest.dependencies?.[name] && !manifest.optionalDependencies?.[name]) {
        throw new Error(`Required dependency is not installed: ${name}`)
      }
    }
  }
  const response = await fetch("https://registry.npmjs.org/-/npm/v1/security/advisories/bulk", {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify(Object.fromEntries([...installed].map(([name, versions]) => [name, [...versions]]))),
    signal: AbortSignal.timeout(30_000),
  })
  if (!response.ok) throw new Error(`Advisory service returned ${response.status}`)
  const advisories = await response.json() as Record<string, Advisory[]>
  let blocking = 0
  for (const [name, entries] of Object.entries(advisories)) {
    for (const advisory of entries) {
      const affected = [...(installed.get(name) ?? [])].filter((version) => Bun.semver.satisfies(version, advisory.vulnerable_versions))
      if (!affected.length || !["high", "critical"].includes(advisory.severity)) continue
      blocking++
      console.error(JSON.stringify({ package: name, versions: affected, severity: advisory.severity, advisory: advisory.url, title: advisory.title }))
    }
  }
  console.log(JSON.stringify({ packages: installed.size, blockingAdvisories: blocking }))
  if (blocking) process.exitCode = 1
}

await main().catch((error: unknown) => {
  console.error("Server dependency audit failed:", error instanceof Error ? error.message : "unknown error")
  process.exitCode = 1
})
