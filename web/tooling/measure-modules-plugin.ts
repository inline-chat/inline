/**
 * Analysis only: writes `bundle-modules.json` next to the build, with every
 * chunk's file name, its static and dynamic imports, and each module's
 * rendered code length (after tree shaking, before minification). The
 * measurement script (`measure-initial-js.ts --modules`) attributes each
 * chunk's real gzip size to its modules in proportion to their own gzip
 * size, which gives a per-module and per-package breakdown of any set of
 * chunks.
 *
 * Used by `measure-analysis.config.ts` only, never by `bun run build`.
 * The modules map is the bundle's own (`OutputChunk.modules`, Rolldown's
 * `RenderedModule`): no extra dependency.
 */

import { readFileSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { gzipSync } from "node:zlib"
import type { Plugin } from "vite"

export type AnalyzedModule = {
  /** Module id relative to the web directory (`src/app/Shell.tsx`, `node_modules/react-dom/...`). */
  readonly id: string
  /** Rendered (tree-shaken, unminified) length in bytes. */
  readonly rendered: number
  /** Gzip size of the module's rendered code alone, level 9. */
  readonly gzip: number
}

export type AnalyzedChunk = {
  readonly fileName: string
  readonly isEntry: boolean
  readonly isDynamicEntry: boolean
  readonly facadeModuleId: string | null
  readonly imports: readonly string[]
  readonly dynamicImports: readonly string[]
  readonly modules: readonly AnalyzedModule[]
}

export const MODULES_FILE = "bundle-modules.json"

/** `/abs/web/node_modules/.bun/react-dom@19/node_modules/react-dom/x.js` → `node_modules/react-dom/x.js`. */
export const shortModuleId = (id: string, root: string): string => {
  const clean = (id.startsWith("\u0000") ? id.slice(1) : id).replace(/\?.*$/, "")
  const nodeModules = clean.lastIndexOf("/node_modules/")
  if (nodeModules >= 0) return `node_modules/${clean.slice(nodeModules + "/node_modules/".length)}`
  const base = root.endsWith("/") ? root : `${root}/`
  if (clean.startsWith(base)) return clean.slice(base.length)
  const parent = base.replace(/[^/]+\/$/, "")
  if (clean.startsWith(parent)) return `../${clean.slice(parent.length)}`
  return clean
}

export const measureModulesPlugin = (): Plugin => {
  let root = process.cwd()
  let outDir = "dist"
  const chunks: AnalyzedChunk[] = []
  return {
    name: "inline-measure-modules",
    apply: "build",
    configResolved(config) {
      root = config.root
      outDir = config.build.outDir
    },
    generateBundle(_options, bundle) {
      chunks.length = 0
      for (const output of Object.values(bundle)) {
        if (output.type !== "chunk") continue
        chunks.push({
          fileName: output.fileName,
          isEntry: output.isEntry,
          isDynamicEntry: output.isDynamicEntry,
          facadeModuleId: output.facadeModuleId ? shortModuleId(output.facadeModuleId, root) : null,
          imports: output.imports,
          dynamicImports: output.dynamicImports,
          modules: Object.entries(output.modules).map(([id, module]) => ({
            id: shortModuleId(id, root),
            rendered: module.renderedLength,
            gzip: module.code ? gzipSync(module.code, { level: 9 }).length : 0,
          })),
        })
      }
    },
    writeBundle() {
      const directory = outDir.startsWith("/") ? outDir : join(root, outDir)
      writeFileSync(join(directory, MODULES_FILE), JSON.stringify({ chunks }, null, 1))
    },
  }
}

/** The names a module exports (declarations and export lists; `export *` is not followed). */
export const exportedNames = (source: string): string[] => {
  const names = new Set<string>()
  for (const match of source.matchAll(/^export\s+(?:declare\s+)?(?:async\s+)?(?:function\*?|const|let|var|class|abstract\s+class)\s+([\w$]+)/gm)) {
    names.add(match[1] ?? "")
  }
  for (const match of source.matchAll(/^export\s*\{([^}]*)\}/gm)) {
    for (const part of (match[1] ?? "").split(",")) {
      const item = part.trim()
      if (!item || item.startsWith("type ")) continue
      const alias = item.split(/\s+as\s+/).pop()?.trim()
      if (alias) names.add(alias)
    }
  }
  if (/^export\s+default\b/m.test(source)) names.add("default")
  names.delete("")
  return [...names]
}

/**
 * Experiments only: each listed module (a path suffix) loads as a stand-in
 * that exports the same names as no-op functions, so a build shows what the
 * initial set would weigh with that module deferred.
 */
export const stubModulesPlugin = (suffixes: readonly string[]): Plugin => ({
  name: "inline-measure-stub",
  apply: "build",
  enforce: "pre",
  load(id) {
    const path = id.replace(/\?.*$/, "")
    if (!suffixes.some((suffix) => path.endsWith(suffix))) return null
    const names = exportedNames(readFileSync(path, "utf8"))
    const lines = names.map((name) => (name === "default" ? "export default function stub() {}" : `export function ${name}() {}`))
    return { code: lines.join("\n") || "export {}", moduleSideEffects: false }
  },
})
