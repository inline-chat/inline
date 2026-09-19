import { existsSync, readFileSync, readdirSync, statSync } from "node:fs"
import { dirname, join, relative, resolve } from "node:path"
import { execFileSync } from "node:child_process"

export type TestLane = "bun" | "effect" | "effect-bun" | "preview"
export type TestRecord = { path: string; lane: TestLane; usesDatabase: boolean }
const testFile = /\.(test|spec)\.tsx?$/

function imports(text: string, path: string): string[] {
  return new Bun.Transpiler({ loader: path.endsWith(".tsx") ? "tsx" : "ts" }).scanImports(text).map((entry) => entry.path)
}

export function classifyTest(path: string, text: string): TestLane {
  const dependencies = imports(text, path)
  const bun = dependencies.includes("bun:test")
  const effect = dependencies.some((id) => id === "vitest" || id === "@effect/vitest")
  if (bun === effect) throw new Error(`${path}: import exactly one test runner (bun:test or vitest/@effect/vitest).`)
  if (/\.effect\.bun\.(test|spec)\.tsx?$/.test(path)) {
    if (!bun) throw new Error(`${path}: Effect Bun tests must import bun:test.`)
    return "effect-bun"
  }
  if (path.startsWith("packages/url-preview/")) {
    if (!bun) throw new Error(`${path}: URL preview tests must import bun:test.`)
    return "preview"
  }
  return effect ? "effect" : "bun"
}

export function discoverTests(root: string): TestRecord[] {
  const files: string[] = []
  const walk = (directory: string) => {
    if (!existsSync(directory)) return
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      if (entry.name.startsWith(".") || ["node_modules", "dist", "fixtures"].includes(entry.name)) continue
      const path = join(directory, entry.name)
      if (entry.isDirectory()) walk(path)
      else if (testFile.test(entry.name)) files.push(path)
    }
  }
  for (const directory of ["src", "scripts", "packages/url-preview/src"]) walk(resolve(root, directory))
  const graph = new Map<string, string[]>()
  const dependencies = (path: string): string[] => {
    const cached = graph.get(path)
    if (cached) return cached
    const resolved = imports(readFileSync(path, "utf8"), path).flatMap((id) => {
      const base = id.startsWith("@in/server/") ? resolve(root, "src", id.slice("@in/server/".length))
        : id.startsWith(".") ? resolve(dirname(path), id) : undefined
      if (!base) return []
      return [base, `${base}.ts`, `${base}.tsx`, join(base, "index.ts")].filter((candidate) =>
        !candidate.endsWith(".d.ts") && /\.tsx?$/.test(candidate) && existsSync(candidate) && statSync(candidate).isFile(),
      ).slice(0, 1)
    })
    graph.set(path, resolved)
    return resolved
  }
  const usesDatabase = (path: string, seen = new Set<string>()): boolean => {
    if (seen.has(path)) return false
    seen.add(path)
    if (path === resolve(root, "src/__tests__/database.ts") || path === resolve(root, "scripts/test-database-template.ts")) return true
    return dependencies(path).some((dependency) => usesDatabase(dependency, seen))
  }
  return files.sort().map((path) => ({
    path: relative(root, path).split("\\").join("/"),
    lane: classifyTest(relative(root, path), readFileSync(path, "utf8")),
    usesDatabase: usesDatabase(path),
  }))
}

// Vitest runs on Node. Use Bun's own TS import scanner for the same inventory;
// no production module is evaluated and no second set of glob rules can drift.
export const effectVitestInclude = (root: string): string[] => {
  if (typeof Bun === "undefined") {
    return JSON.parse(execFileSync("bun", ["--no-env-file", resolve(root, "scripts/test-discovery.ts")], {
      cwd: root, encoding: "utf8",
    })) as string[]
  }
  return discoverTests(root).filter((file) => file.lane === "effect").map((file) => file.path)
}

if (import.meta.main) console.log(JSON.stringify(effectVitestInclude(resolve(import.meta.dir, ".."))))
