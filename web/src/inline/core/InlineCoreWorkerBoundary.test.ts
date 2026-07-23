import { existsSync, readFileSync, statSync } from "node:fs"
import { dirname, extname, relative, resolve } from "node:path"
import { fileURLToPath } from "node:url"
import { describe, expect, it } from "vitest"

const webRoot = resolve(
  dirname(fileURLToPath(import.meta.url)),
  "../../..",
)

const packageEntrypoints = new Map([
  [
    "@inline/client/core",
    resolve(webRoot, "packages/client/src/core.ts"),
  ],
  [
    "@inline/auth/core",
    resolve(webRoot, "packages/auth/src/core.ts"),
  ],
])

const sourceCandidates = (path: string) => {
  if (extname(path)) return [path]
  return [
    `${path}.ts`,
    `${path}.tsx`,
    resolve(path, "index.ts"),
    resolve(path, "index.tsx"),
    path,
  ]
}

const isFile = (path: string) =>
  existsSync(path) && statSync(path).isFile()

const resolveSource = (
  importer: string,
  specifier: string,
): string | undefined => {
  const packageEntrypoint = packageEntrypoints.get(specifier)
  if (packageEntrypoint) return packageEntrypoint
  if (!specifier.startsWith(".")) return undefined

  return sourceCandidates(
    resolve(dirname(importer), specifier),
  ).find(isFile)
}

const moduleSpecifiers = (source: string) => {
  const specifiers = new Set<string>()
  for (const match of source.matchAll(
    /\bfrom\s*["']([^"']+)["']/g,
  )) {
    if (match[1]) specifiers.add(match[1])
  }
  for (const match of source.matchAll(
    /\bimport\s*\(\s*["']([^"']+)["']/g,
  )) {
    if (match[1]) specifiers.add(match[1])
  }
  for (const match of source.matchAll(
    /\bimport\s*["']([^"']+)["']/g,
  )) {
    if (match[1]) specifiers.add(match[1])
  }
  return [...specifiers]
}

const isRendererOnlyImport = (specifier: string) =>
  specifier === "react" ||
  specifier.startsWith("react/") ||
  specifier === "react-dom" ||
  specifier.startsWith("react-dom/") ||
  specifier === "@inline/client" ||
  specifier.startsWith("@inline/client/react") ||
  specifier === "@inline/auth" ||
  specifier.startsWith("@inline/auth/react")

const dependencyGraph = (entry: string) => {
  const pending = [entry]
  const visited = new Set<string>()
  const imports = new Map<string, string[]>()

  while (pending.length > 0) {
    const path = pending.pop()
    if (!path || visited.has(path)) continue
    visited.add(path)

    const specifiers = moduleSpecifiers(
      readFileSync(path, "utf8"),
    )
    imports.set(path, specifiers)
    for (const specifier of specifiers) {
      const dependency = resolveSource(path, specifier)
      if (dependency && !visited.has(dependency)) {
        pending.push(dependency)
      }
    }
  }

  return { imports, visited }
}

describe("Inline SharedWorker module boundary", () => {
  it("keeps the worker dependency graph free of renderer modules", () => {
    const entry = resolve(
      webRoot,
      "src/inline/core/InlineCore.shared-worker.ts",
    )
    const { imports, visited } = dependencyGraph(entry)
    const violations: string[] = []

    for (const [path, specifiers] of imports) {
      for (const specifier of specifiers) {
        if (isRendererOnlyImport(specifier)) {
          violations.push(
            `${relative(webRoot, path)} imports ${specifier}`,
          )
        }
      }
    }

    expect(violations).toEqual([])
    expect(
      [...visited].map((path) => relative(webRoot, path)),
    ).not.toContain("packages/client/src/react/index.tsx")
    expect(
      [...visited].map((path) => relative(webRoot, path)),
    ).not.toContain("packages/auth/src/react.tsx")
  })

  it("keeps unselected SQLite code outside the production owner graph", () => {
    const entry = resolve(
      webRoot,
      "src/inline/core/InlineCore.shared-worker.ts",
    )
    const { imports, visited } = dependencyGraph(entry)
    const paths = [...visited].map((path) =>
      relative(webRoot, path),
    )
    const sqliteImports = [...imports.entries()].flatMap(
      ([path, specifiers]) =>
        specifiers
          .filter(
            (specifier) =>
              specifier === "@inline/client/sqlite" ||
              specifier === "@sqlite.org/sqlite-wasm",
          )
          .map(
            (specifier) =>
              `${relative(webRoot, path)} imports ${specifier}`,
          ),
    )

    expect(sqliteImports).toEqual([])
    expect(
      paths.some((path) =>
        path.includes("packages/client/src/database/sqlite/"),
      ),
    ).toBe(false)
  })

  it("uses only the SharedWorker registry in the product runtime", () => {
    const entry = resolve(
      webRoot,
      "src/inline/runtime/InlineRuntimeCore.ts",
    )
    const { imports, visited } = dependencyGraph(entry)
    const specifiers = [...imports.values()].flat()
    const paths = [...visited].map((path) =>
      relative(webRoot, path),
    )

    expect(specifiers).not.toContain(
      "../core/InlineBroadcastCoreRegistry",
    )
    expect(paths).not.toContain(
      "src/inline/core/InlineBroadcastCoreRegistry.ts",
    )
    expect(paths).toContain(
      "src/inline/core/createInlineCoreRendererClient.ts",
    )
  })
})
