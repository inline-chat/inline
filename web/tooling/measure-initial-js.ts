/**
 * The canonical bundle measurement (web/docs/performance.md, "Measuring the
 * initial JavaScript"). It builds nothing: it reads a production build.
 *
 *   bunx vite build --outDir <dir> --manifest
 *   bun run size <dir> [--check] [--json] [--out <file>] [--modules] [--budget <kB>]
 *
 * What it computes, all gzip level 9, kB of 1,000 bytes:
 *
 * - entry: the classic and module scripts and the modulepreloads in
 *   `index.html`, each followed through its static imports.
 * - signed in: the entry plus the chunks the boot path requests before the
 *   shell's first paint, each followed through its static imports.
 * - signed out: the entry plus the chunks requested before the sign-in
 *   screen paints, likewise.
 * - deferred: every other dynamically imported chunk, with its own cost (its
 *   static closure minus the signed-in set; a file two deferred chunks share
 *   counts in both).
 *
 * Which chunks a phase requests before its first paint is not a list here:
 * it is `firstPaint` in `src/app/view-chunks.ts`, the table `boot.ts` loads
 * from. Each name there is a literal `import("...")` in the same file; the
 * specifier is resolved to a source path and the source path to its output
 * file through the build's Vite manifest (`.vite/manifest.json`, hence
 * `--manifest`).
 *
 * `--modules` adds the per-module and per-package breakdown of the signed-in
 * set, from `bundle-modules.json` (written by `measure-analysis.config.ts`).
 */

import { existsSync, readdirSync, readFileSync, writeFileSync } from "node:fs"
import { join, posix } from "node:path"
import { gzipSync } from "node:zlib"

// MARK: The import graph of a build

/** Static imports of an ES module chunk (relative specifiers only), resolved against `file`. */
export const staticImports = (code: string, file: string): string[] => {
  const found = new Set<string>()
  // Bundled output hoists every import to the top; re-exports may sit at the end.
  const pattern = /(?:^|[;}\n])\s*(?:import|export)\s*(?:[\w$*{}\s,]*?\s*from\s*)?["'`](\.{1,2}\/[^"'`]+?\.m?js)["'`]/g
  for (const match of code.matchAll(pattern)) found.add(resolveAsset(file, match[1] ?? ""))
  return [...found]
}

/** Dynamic `import("./x.js")` targets of a chunk, resolved against `file`. */
export const dynamicImports = (code: string, file: string): string[] => {
  const found = new Set<string>()
  for (const match of code.matchAll(/\bimport\(\s*["'`](\.{1,2}\/[^"'`]+?\.m?js)["'`]\s*\)/g)) {
    found.add(resolveAsset(file, match[1] ?? ""))
  }
  return [...found]
}

const resolveAsset = (from: string, specifier: string): string => posix.normalize(posix.join(posix.dirname(from), specifier))

export type BuildFiles = {
  /** File contents by path relative to the build directory (`assets/x.js`). */
  read(file: string): string
  exists(file: string): boolean
}

export const directoryFiles = (directory: string): BuildFiles => ({
  read: (file) => readFileSync(join(directory, file), "utf8"),
  exists: (file) => existsSync(join(directory, file)),
})

/** Every file reachable from `starts` through static imports. */
export const staticClosure = (files: BuildFiles, starts: Iterable<string>): Set<string> => {
  const seen = new Set<string>()
  const stack = [...starts]
  while (stack.length > 0) {
    const file = stack.pop()
    if (file === undefined || seen.has(file) || !files.exists(file)) continue
    seen.add(file)
    if (!file.endsWith(".js") && !file.endsWith(".mjs")) continue
    for (const next of staticImports(files.read(file), file)) stack.push(next)
  }
  return seen
}

/** The scripts `index.html` runs or preloads before anything else: classic scripts, module scripts, modulepreloads. */
export const htmlEntries = (html: string): string[] => {
  const out: string[] = []
  for (const match of html.matchAll(/<script\b[^>]*\bsrc="([^"]+)"/g)) out.push(stripSlash(match[1] ?? ""))
  for (const match of html.matchAll(/<link\b[^>]*\brel="modulepreload"[^>]*\bhref="([^"]+)"/g)) out.push(stripSlash(match[1] ?? ""))
  return out.filter((file) => file.endsWith(".js") || file.endsWith(".mjs"))
}

const stripSlash = (path: string): string => path.replace(/^\//, "")

/** Every file reachable from `starts` through static and dynamic imports, and the dynamic import targets among them. */
export const reachable = (files: BuildFiles, starts: Iterable<string>): { files: Set<string>; dynamicTargets: Set<string> } => {
  const visited = new Set<string>()
  const dynamicTargets = new Set<string>()
  const queue = [...starts]
  while (queue.length > 0) {
    const file = queue.pop()
    if (file === undefined || visited.has(file)) continue
    visited.add(file)
    if (!file.endsWith(".js") && !file.endsWith(".mjs")) continue
    const code = files.read(file)
    for (const next of staticImports(code, file)) if (files.exists(next)) queue.push(next)
    for (const next of dynamicImports(code, file)) {
      if (!files.exists(next)) continue
      dynamicTargets.add(next)
      queue.push(next)
    }
  }
  return { files: visited, dynamicTargets }
}

// MARK: The boot path

export type ManifestEntry = {
  readonly file: string
  readonly src?: string
  readonly isEntry?: boolean
  readonly isDynamicEntry?: boolean
}
export type Manifest = Readonly<Record<string, ManifestEntry>>

/** `name: () => import("spec")` lines of the view chunk table (`src/app/view-chunks.ts`). */
export const chunkSpecifiers = (source: string): Map<string, string> => {
  const out = new Map<string, string>()
  for (const match of source.matchAll(/^\s*(\w+):\s*\(\)\s*=>\s*import\(\s*["']([^"']+)["']\s*\)/gm)) {
    out.set(match[1] ?? "", match[2] ?? "")
  }
  return out
}

/** `@inline/<name>/<sub>`'s file from the package's `exports` (`default`), as a path under `web/`; undefined without one. */
const packageExport = (name: string, sub: string | undefined): string | undefined => {
  try {
    const manifest = JSON.parse(readFileSync(new URL(`../packages/${name}/package.json`, import.meta.url), "utf8")) as {
      exports?: Record<string, string | { default?: string }>
    }
    const entry = manifest.exports?.[sub ? `./${sub}` : "."]
    const target = typeof entry === "string" ? entry : entry?.default
    return target ? posix.normalize(posix.join(`packages/${name}`, target)) : undefined
  } catch {
    return undefined
  }
}

/**
 * A specifier from `src/app/view-chunks.ts` to the manifest key of its
 * source (`./Shell` → `src/app/Shell.tsx`, `@inline/auth/flows` →
 * `packages/auth/src/flows/index.ts`).
 */
export const manifestKeyFor = (specifier: string, manifest: Manifest, from = "src/app"): string | undefined => {
  let base: string
  if (specifier.startsWith(".")) base = posix.normalize(posix.join(from, specifier))
  else {
    const match = /^@inline\/([^/]+)(?:\/(.+))?$/.exec(specifier)
    if (!match) return undefined
    // The package's own `exports` first (`@inline/ui/menu-kit` is `src/react/menu-kit.tsx`), then the source layout.
    const exported = packageExport(match[1] ?? "", match[2])
    if (exported && manifest[exported]) return exported
    base = `packages/${match[1]}/src${match[2] ? `/${match[2]}` : "/index"}`
  }
  for (const candidate of [base, `${base}.ts`, `${base}.tsx`, `${base}/index.ts`, `${base}/index.tsx`]) {
    if (manifest[candidate]) return candidate
  }
  return undefined
}

export type BootPath = {
  /** View chunk name to its import specifier. */
  readonly specifiers: ReadonlyMap<string, string>
  /** What each phase requests before its first paint, by name. */
  readonly firstPaint: { readonly signedIn: readonly string[]; readonly signedOut: readonly string[] }
  /** Names loaded on the idle lane right after the first paint. */
  readonly afterFirstPaint: readonly string[]
}

const viewChunksPath = new URL("../src/app/view-chunks.ts", import.meta.url).pathname

/** Reads the boot path from `src/app/view-chunks.ts`: the table itself (imported) and its specifiers (parsed). */
export const readBootPath = async (path = viewChunksPath): Promise<BootPath> => {
  const module = (await import(path)) as {
    firstPaint: BootPath["firstPaint"]
    afterFirstPaint: BootPath["afterFirstPaint"]
  }
  return {
    specifiers: chunkSpecifiers(readFileSync(path, "utf8")),
    firstPaint: module.firstPaint,
    afterFirstPaint: module.afterFirstPaint,
  }
}

// MARK: Measuring

export const gzipSize = (content: string | Uint8Array): number => gzipSync(content, { level: 9 }).length

export type SetMeasure = {
  readonly bytes: number
  readonly gzip: number
  readonly files: readonly { readonly file: string; readonly bytes: number; readonly gzip: number }[]
}

export type DeferredMeasure = {
  readonly name: string
  readonly file: string
  readonly source: string | null
  /** Loaded on the idle lane after the first paint (else on first intent). */
  readonly warmed: boolean
  readonly gzip: number
  readonly files: number
}

export type Measurement = {
  readonly unit: "kB gzip -9 (1,000 bytes)"
  readonly budget: number
  readonly entry: SetMeasure
  readonly signedIn: SetMeasure & { readonly chunks: readonly string[] }
  readonly signedOut: SetMeasure & { readonly chunks: readonly string[] }
  readonly deferred: readonly DeferredMeasure[]
}

export const measureSet = (files: BuildFiles, set: Iterable<string>, sizes = new Map<string, { bytes: number; gzip: number }>()): SetMeasure => {
  const rows = [...set].map((file) => {
    let size = sizes.get(file)
    if (!size) {
      const content = files.read(file)
      size = { bytes: Buffer.byteLength(content), gzip: gzipSize(content) }
      sizes.set(file, size)
    }
    return { file, ...size }
  })
  rows.sort((a, b) => b.gzip - a.gzip)
  return {
    bytes: rows.reduce((sum, row) => sum + row.bytes, 0),
    gzip: rows.reduce((sum, row) => sum + row.gzip, 0),
    files: rows,
  }
}

export type MeasureInput = {
  readonly files: BuildFiles
  readonly manifest: Manifest
  readonly boot: BootPath
  readonly budget?: number
}

export const measure = (input: MeasureInput): Measurement => {
  const { files, manifest, boot } = input
  const sizes = new Map<string, { bytes: number; gzip: number }>()
  const fileFor = (name: string): string => {
    const specifier = boot.specifiers.get(name)
    if (!specifier) throw new Error(`view-chunks.ts has no importer named "${name}"`)
    const key = manifestKeyFor(specifier, manifest)
    const entry = key ? manifest[key] : undefined
    if (!entry) throw new Error(`"${name}" (${specifier}) is not in the build's manifest`)
    return entry.file
  }
  const entryFiles = htmlEntries(files.read("index.html"))
  const missing = entryFiles.filter((file) => !files.exists(file))
  if (missing.length > 0) throw new Error(`index.html names files the build does not have: ${missing.join(", ")}`)
  const entry = staticClosure(files, entryFiles)
  const phase = (names: readonly string[]) => {
    const chunks = names.map(fileFor)
    const set = staticClosure(files, [...entry, ...chunks])
    return { ...measureSet(files, set, sizes), chunks }
  }
  const signedIn = phase(boot.firstPaint.signedIn)
  const signedOut = phase(boot.firstPaint.signedOut)
  const initial = new Set(signedIn.files.map((row) => row.file))

  // Every dynamic import target reachable from the entry that the signed-in set does not hold.
  const { dynamicTargets: targets } = reachable(files, entry)
  const sourceOf = new Map(Object.entries(manifest).map(([key, value]) => [value.file, value.src ?? key]))
  const nameOf = new Map<string, string>()
  for (const name of boot.specifiers.keys()) {
    try {
      nameOf.set(fileFor(name), name)
    } catch {
      // A name the build does not contain (dev-only importers): not measured.
    }
  }
  const warmed = new Set(boot.afterFirstPaint.map((name) => safe(() => fileFor(name))))
  const deferred: DeferredMeasure[] = []
  for (const file of targets) {
    if (initial.has(file)) continue
    const own = [...staticClosure(files, [file])].filter((member) => !initial.has(member))
    const size = measureSet(files, own, sizes)
    const source = sourceOf.get(file) ?? null
    deferred.push({
      name: nameOf.get(file) ?? source ?? file,
      file,
      source,
      warmed: warmed.has(file),
      gzip: size.gzip,
      files: own.length,
    })
  }
  deferred.sort((a, b) => b.gzip - a.gzip)
  return {
    unit: "kB gzip -9 (1,000 bytes)",
    budget: input.budget ?? 200,
    entry: measureSet(files, entry, sizes),
    signedIn,
    signedOut,
    deferred,
  }
}

const safe = <T>(fn: () => T): T | undefined => {
  try {
    return fn()
  } catch {
    return undefined
  }
}

// MARK: Entry isolation

/**
 * What every HTML page of a build may execute, from the module map:
 *
 * - An entry module's top-level code runs for its own page only: the app's
 *   `src/main.tsx` (it boots and renders the app) is in no other page's
 *   static closure, and a lab's `src/lab/<name>/main.ts(x)` in no page but
 *   `lab-<name>.html`. A shared chunk that swallowed an entry module fails
 *   this.
 * - Without lab pages (a production build), nothing under `src/lab/` or
 *   `src/core/demo/` is reachable from `index.html`, statically or
 *   dynamically, and neither are the demo's switches in the app
 *   (`productionForbidden`: the `__inlineApp` hook and the demo parameter),
 *   which only the dev server and the labs build compile in. With lab pages
 *   (the labs build, which enables the demo), only `src/lab/` is checked for
 *   `index.html`.
 */
const productionForbidden = new Set(["src/app/dev-snapshot.ts", "src/app/demo-params.ts"])

export const checkEntries = (files: BuildFiles, pages: readonly string[], modules: ModulesFile): string[] => {
  const modulesOf = new Map(modules.chunks.map((chunk) => [chunk.fileName, chunk.modules.map((module) => module.id)]))
  const idsIn = (set: Iterable<string>) => [...set].flatMap((file) => modulesOf.get(file) ?? [])
  const problems: string[] = []
  const hasLabs = pages.some((page) => page !== "index.html")
  for (const page of pages) {
    const ids = idsIn(staticClosure(files, htmlEntries(files.read(page))))
    for (const id of ids) {
      if (id === "src/main.tsx" && page !== "index.html") problems.push(`${page} loads the app entry (src/main.tsx)`)
      const lab = /^src\/lab\/([^/]+)\/main\.tsx?$/.exec(id)
      if (lab && page !== `lab-${lab[1]}.html`) problems.push(`${page} loads another page's entry (${id})`)
    }
    if (page !== "index.html") continue
    const everything = idsIn(reachable(files, htmlEntries(files.read(page))).files)
    for (const id of new Set(everything)) {
      if (id.startsWith("src/lab/")) problems.push(`index.html can reach lab code (${id})`)
      if (!hasLabs && (id.startsWith("src/core/demo/") || productionForbidden.has(id))) {
        problems.push(`index.html can reach demo code (${id})`)
      }
    }
  }
  return problems
}

// MARK: Per-module breakdown

export type ModuleShare = { readonly id: string; readonly gzip: number; readonly rendered: number }
export type ModulesFile = {
  readonly chunks: readonly {
    readonly fileName: string
    readonly modules: readonly { readonly id: string; readonly rendered: number; readonly gzip: number }[]
  }[]
}

/**
 * Each chunk's real gzip size shared out to its modules in proportion to
 * each module's own gzip size (a module's code compresses with its chunk's
 * neighbors, so this is an attribution, not a measurement of the module
 * alone; the shares of one chunk add up to the chunk).
 */
export const moduleShares = (modules: ModulesFile, set: SetMeasure): ModuleShare[] => {
  const byFile = new Map(modules.chunks.map((chunk) => [chunk.fileName, chunk]))
  const out: ModuleShare[] = []
  for (const row of set.files) {
    const chunk = byFile.get(row.file)
    if (!chunk) {
      out.push({ id: `(${row.file})`, gzip: row.gzip, rendered: row.bytes })
      continue
    }
    const total = chunk.modules.reduce((sum, module) => sum + module.gzip, 0)
    for (const module of chunk.modules) {
      out.push({ id: module.id, gzip: total > 0 ? (row.gzip * module.gzip) / total : 0, rendered: module.rendered })
    }
  }
  return out.sort((a, b) => b.gzip - a.gzip)
}

/** The package or app folder a module belongs to. */
export const packageOf = (id: string): string => {
  let match = /^node_modules\/((?:@[^/]+\/)?[^/]+)\//.exec(id)
  if (match) return match[1] ?? id
  match = /^packages\/([^/]+)\//.exec(id)
  if (match) return `@inline/${match[1]}`
  match = /^src\/features\/([^/]+)\//.exec(id)
  if (match) return `src/features/${match[1]}`
  match = /^src\/([^/]+)\//.exec(id)
  if (match) return `src/${match[1]}`
  if (/^src\/[^/]+$/.test(id)) return "src"
  match = /^\.\.\/packages\/([^/]+)\//.exec(id)
  if (match) return `@inline-chat/${match[1]}`
  return "(bundler)"
}

export const packageRollup = (shares: readonly ModuleShare[]): { readonly name: string; readonly gzip: number; readonly modules: number }[] => {
  const totals = new Map<string, { gzip: number; modules: number }>()
  for (const share of shares) {
    const name = packageOf(share.id)
    const total = totals.get(name) ?? { gzip: 0, modules: 0 }
    total.gzip += share.gzip
    total.modules += 1
    totals.set(name, total)
  }
  return [...totals].map(([name, total]) => ({ name, ...total })).sort((a, b) => b.gzip - a.gzip)
}

// MARK: Command line

const kB = (bytes: number): string => (bytes / 1000).toFixed(1).padStart(7)

export const formatTable = (result: Measurement): string => {
  const lines: string[] = []
  const line = (label: string, set: SetMeasure) =>
    lines.push(`${label.padEnd(12)} ${kB(set.gzip)} kB  ${String(set.files.length).padStart(3)} files  (${(set.gzip / 1024).toFixed(1)} KiB)`)
  lines.push(`Initial UI JavaScript, ${result.unit}, budget ${result.budget} kB`)
  line("entry", result.entry)
  line("signed in", result.signedIn)
  line("signed out", result.signedOut)
  lines.push("", "Signed-in set, largest files:")
  for (const row of result.signedIn.files.slice(0, 12)) lines.push(`  ${kB(row.gzip)} kB  ${row.file}`)
  lines.push("", "Deferred chunks (own cost beyond the signed-in set):")
  for (const chunk of result.deferred) {
    lines.push(`  ${kB(chunk.gzip)} kB  ${chunk.name.padEnd(36)} ${chunk.warmed ? "warmed after paint" : "on first use"}  (+${chunk.files - 1} files)`)
  }
  return lines.join("\n")
}

export const formatModules = (shares: readonly ModuleShare[], count = 40): string => {
  const lines = ["Signed-in set by package (attributed gzip):"]
  for (const row of packageRollup(shares)) lines.push(`  ${kB(row.gzip)} kB  ${row.name}  (${row.modules} modules)`)
  lines.push("", `Top ${count} modules:`)
  for (const share of shares.slice(0, count)) lines.push(`  ${kB(share.gzip)} kB  ${share.id}`)
  return lines.join("\n")
}

const main = async (args: string[]): Promise<number> => {
  const flag = (name: string) => args.includes(name)
  const option = (name: string) => {
    const index = args.indexOf(name)
    return index >= 0 ? args[index + 1] : undefined
  }
  const directory = args.find((arg, index) => !arg.startsWith("--") && !["--out", "--budget"].includes(args[index - 1] ?? ""))
  if (!directory) {
    console.error("usage: bun run size <build dir> [--check] [--json] [--out <file>] [--modules] [--entries] [--budget <kB>]")
    return 2
  }
  const modulesPath = join(directory, "bundle-modules.json")
  if (flag("--entries")) {
    if (!existsSync(modulesPath)) {
      console.error(`${modulesPath} is missing: build with -c tooling/measure-analysis.config.ts (or the labs config)`)
      return 2
    }
    const pages = readdirSync(directory).filter((name) => name.endsWith(".html"))
    const problems = checkEntries(directoryFiles(directory), pages, JSON.parse(readFileSync(modulesPath, "utf8")) as ModulesFile)
    for (const problem of problems) console.error(problem)
    console.log(`entries: ${pages.length} pages, ${problems.length === 0 ? "isolated" : `${problems.length} problems`}`)
    if (problems.length > 0) return 1
    if (!existsSync(join(directory, ".vite/manifest.json"))) return 0
  }
  const manifestPath = join(directory, ".vite/manifest.json")
  if (!existsSync(manifestPath)) {
    console.error(`${manifestPath} is missing: build with --manifest (bunx vite build --outDir ${directory} --manifest)`)
    return 2
  }
  const budget = Number(option("--budget") ?? 200)
  const result = measure({
    files: directoryFiles(directory),
    manifest: JSON.parse(readFileSync(manifestPath, "utf8")) as Manifest,
    boot: await readBootPath(),
    budget,
  })
  const shares = flag("--modules") && existsSync(modulesPath)
    ? moduleShares(JSON.parse(readFileSync(modulesPath, "utf8")) as ModulesFile, result.signedIn)
    : undefined
  if (flag("--modules") && !shares) console.error(`${modulesPath} is missing: build with -c tooling/measure-analysis.config.ts`)
  const json = JSON.stringify({ ...result, ...(shares ? { modules: shares, packages: packageRollup(shares) } : {}) }, null, 1)
  const out = option("--out")
  if (out) writeFileSync(out, json)
  if (flag("--json")) console.log(json)
  else {
    console.log(formatTable(result))
    if (shares) console.log(`\n${formatModules(shares)}`)
  }
  if (flag("--check")) {
    const over = [result.signedIn, result.signedOut].filter((set) => set.gzip > budget * 1000)
    if (over.length > 0) {
      console.error(`over budget: signed in ${(result.signedIn.gzip / 1000).toFixed(1)} kB, signed out ${(result.signedOut.gzip / 1000).toFixed(1)} kB, budget ${budget} kB`)
      return 1
    }
  }
  return 0
}

if ((import.meta as ImportMeta & { main?: boolean }).main) process.exit(await main(process.argv.slice(2)))

