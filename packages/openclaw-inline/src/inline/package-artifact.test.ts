import { mkdtemp, readdir, readFile } from "node:fs/promises"
import path from "node:path"
import { tmpdir } from "node:os"
import { execFile as execFileCallback } from "node:child_process"
import { promisify } from "node:util"
import { describe, expect, it } from "vitest"

const execFile = promisify(execFileCallback)

async function listJsFiles(dir: string): Promise<string[]> {
  const entries = await readdir(dir, { withFileTypes: true })
  const files = await Promise.all(
    entries.map(async (entry) => {
      const entryPath = path.join(dir, entry.name)
      if (entry.isDirectory()) {
        return listJsFiles(entryPath)
      }
      if (entry.isFile() && entry.name.endsWith(".js")) {
        return [entryPath]
      }
      return []
    }),
  )
  return files.flat()
}

describe("packed artifact", () => {
  it("does not ship unresolved runtime package imports beyond the OpenClaw peer", async () => {
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
    const jsFiles = await listJsFiles(distDir)
    expect(jsFiles.length).toBeGreaterThan(0)

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
          specifier === "openclaw/plugin-sdk"
        ) {
          continue
        }
        unresolvedBareImports.add(specifier)
      }
    }

    expect([...unresolvedBareImports]).toEqual([])
  })
})
