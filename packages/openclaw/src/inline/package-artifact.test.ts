import { mkdtemp, readdir, readFile } from "node:fs/promises"
import path from "node:path"
import { tmpdir } from "node:os"
import { execFile as execFileCallback } from "node:child_process"
import { promisify } from "node:util"
import { describe, expect, it } from "vitest"

const execFile = promisify(execFileCallback)

async function listFiles(dir: string): Promise<string[]> {
  const entries = await readdir(dir, { withFileTypes: true })
  const files = await Promise.all(
    entries.map(async (entry) => {
      const entryPath = path.join(dir, entry.name)
      if (entry.isDirectory()) {
        return listFiles(entryPath)
      }
      if (entry.isFile()) {
        return [entryPath]
      }
      return []
    }),
  )
  return files.flat()
}

describe("packed artifact", () => {
  it("does not ship unresolved runtime package imports beyond OpenClaw SDK peers", async () => {
    const packDir = await mkdtemp(path.join(tmpdir(), "inline-openclaw-pack-"))
    const extractDir = await mkdtemp(path.join(tmpdir(), "inline-openclaw-extract-"))
    const packageDir = path.resolve(__dirname, "..", "..")

    const packResult = await execFile(
      "npm",
      ["pack", "--pack-destination", packDir],
      { cwd: packageDir },
    )
    const packedFile = packResult.stdout.trim().split("\n").at(-1)
    expect(packedFile).toBeTruthy()

    const tarballPath = path.join(packDir, packedFile!)
    await execFile("tar", ["-xzf", tarballPath, "-C", extractDir])

    const distDir = path.join(extractDir, "package", "dist")
    const files = await listFiles(distDir)
    const jsFiles = files.filter((file) => file.endsWith(".js"))
    expect(jsFiles.length).toBeGreaterThan(0)
    expect(files.some((file) => file.endsWith("index.d.ts"))).toBe(true)
    expect(files.some((file) => file.endsWith(".tsbuildinfo"))).toBe(false)

    const unresolvedBareImports = new Set<string>()
    const importPattern = /from\s+"([^"]+)"/g

    for (const file of jsFiles) {
      const contents = await readFile(file, "utf8")
      for (const match of contents.matchAll(importPattern)) {
        const specifier = match[1]
        if (
          specifier.startsWith("./") ||
          specifier.startsWith("../") ||
          specifier.startsWith("node:") ||
          specifier === "openclaw/plugin-sdk" ||
          specifier.startsWith("openclaw/plugin-sdk/")
        ) {
          continue
        }
        unresolvedBareImports.add(specifier)
      }
    }

    expect([...unresolvedBareImports]).toEqual([])
  }, 30_000)
})
