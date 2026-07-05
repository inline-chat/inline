import { readdirSync, readFileSync } from "node:fs"
import path from "node:path"
import { describe, expect, it } from "vitest"

function listRuntimeSourceFiles(rootDir: string): string[] {
  const out: string[] = []
  const stack = [rootDir]

  while (stack.length > 0) {
    const current = stack.pop()
    if (!current) continue
    for (const entry of readdirSync(current, { withFileTypes: true })) {
      const absolute = path.join(current, entry.name)
      if (entry.isDirectory()) {
        stack.push(absolute)
        continue
      }
      if (!entry.isFile()) continue
      if (!absolute.endsWith(".ts")) continue
      if (absolute.endsWith(".test.ts")) continue
      out.push(absolute)
    }
  }

  return out.sort((left, right) => left.localeCompare(right))
}

describe("plugin sdk runtime imports", () => {
  it("does not use runtime named imports from the root openclaw/plugin-sdk barrel", () => {
    const srcRoot = path.join(import.meta.dirname, ".")
    const files = listRuntimeSourceFiles(srcRoot)
    const offenders: string[] = []
    const runtimeNamedRootImportRe = /import\s*\{[\s\S]*?\}\s*from\s*"openclaw\/plugin-sdk"/gu

    for (const filePath of files) {
      const text = readFileSync(filePath, "utf8")
      if (runtimeNamedRootImportRe.test(text)) {
        offenders.push(path.relative(srcRoot, filePath))
      }
    }

    expect(offenders).toEqual([])
  })
})
