import { spawnSync } from "node:child_process"
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import path from "node:path"
import { describe, expect, it } from "vitest"

const protocolSource = path.resolve(__dirname, "../../../../../../packages/protocol/src")
const transportDirectory = __dirname

const importPattern = /(?:^|[\s;])(?:import|export)\s+(?:type\s+)?(?:[^"';]*?\sfrom\s+)?["']([^"']+)["']/g

const stripComments = (source: string) =>
  source.replace(/\/\*[\s\S]*?\*\//g, "").replace(/(^|[^:"'`])\/\/.*$/gm, "$1")

const resolveRelative = (from: string, specifier: string): string => {
  const base = path.resolve(path.dirname(from), specifier)
  for (const candidate of [base.replace(/\.js$/, ".ts"), `${base}.ts`, path.join(base, "index.ts")]) {
    if (existsSync(candidate)) return candidate
  }
  throw new Error(`Cannot resolve ${specifier} from ${from}`)
}

const resolveProtocol = (specifier: string): string => {
  const subpath = specifier.slice("@inline-chat/protocol".length).replace(/^\//, "") || "index"
  return resolveRelative(path.join(protocolSource, "entry.ts"), `./${subpath}`)
}

/** Walks static imports, returning every file reached and every bare package specifier. */
const moduleGraph = (entries: string[], external: (specifier: string) => boolean) => {
  const files = new Set<string>()
  const packages = new Set<string>()
  const queue = [...entries]
  while (queue.length > 0) {
    const file = queue.pop()!
    if (files.has(file)) continue
    files.add(file)
    const source = stripComments(readFileSync(file, "utf8"))
    for (const match of source.matchAll(importPattern)) {
      const specifier = match[1]!
      if (specifier.startsWith(".")) queue.push(resolveRelative(file, specifier))
      else if (specifier.startsWith("@inline-chat/protocol")) queue.push(resolveProtocol(specifier))
      else if (!external(specifier)) packages.add(specifier)
    }
  }
  return { files, packages }
}

const nodeOnly = /(?<![.\w$#])(?:Buffer\b|process\s*\.|__dirname\b|setImmediate\b|require\s*\(\s*["'])/

describe("portable V3 entry", () => {
  it("reaches no Node module, no ws, and no Node global from @inline-chat/protocol/secure/connection", () => {
    const { files, packages } = moduleGraph([path.join(protocolSource, "secure/connection.ts")], () => false)
    expect(files.size).toBeGreaterThan(10)
    expect([...files].some((file) => file.endsWith("secure/node.ts"))).toBe(false)
    for (const specifier of packages) {
      expect(specifier, specifier).toMatch(/^(@noble\/(ciphers|hashes)\/|@protobuf-ts\/runtime$)/)
    }
    for (const file of files) {
      const source = stripComments(readFileSync(file, "utf8")).replace(/(["'`])(?:\\.|(?!\1).)*\1/g, "\"\"")
      expect(nodeOnly.test(source), path.relative(protocolSource, file)).toBe(false)
    }
  })

  it("keeps the browser transport files free of Node modules", () => {
    const entries = ["v3-browser-runtime.ts", "v3-transport.ts", "negotiating-transport.ts", "v3-session-upgrade.ts",
      "v3-credentials.ts", "v3-connection-init.ts"].map((file) => path.join(transportDirectory, file))
    const { packages } = moduleGraph(entries, (specifier) => specifier.startsWith("@inline/"))
    for (const specifier of packages) expect(specifier, specifier).not.toMatch(/^(node:|ws$)/)
  })

  it("typechecks for a worker with no Node types", () => {
    const tsc = path.resolve(protocolSource, "../node_modules/.bin/tsc")
    const directory = mkdtempSync(path.join(tmpdir(), "inline-v3-portable-"))
    try {
      const config = path.join(directory, "tsconfig.json")
      writeFileSync(config, JSON.stringify({
        compilerOptions: {
          target: "ES2022", module: "NodeNext", moduleResolution: "NodeNext", strict: true, skipLibCheck: true,
          noEmit: true, types: [], lib: ["ES2022", "WebWorker"], verbatimModuleSyntax: true,
        },
        files: [path.join(protocolSource, "secure/connection.ts")],
      }))
      const result = spawnSync(tsc, ["-p", config], { encoding: "utf8" })
      expect(`${result.stdout}${result.stderr}`).toBe("")
      expect(result.status).toBe(0)
    } finally {
      rmSync(directory, { recursive: true, force: true })
    }
  }, 60_000)
})
