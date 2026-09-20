import { expect, test } from "bun:test"
import { mkdtemp, readFile, readdir } from "node:fs/promises"
import { tmpdir } from "node:os"
import { resolve } from "node:path"

const root = resolve(import.meta.dir, "../..")

test("Docker preparation preserves the complete manifest graph and exact lockfile without installing", async () => {
  const temp = await mkdtemp(resolve(tmpdir(), "inline-docker-contract-"))
  const lock = await readFile(resolve(root, "bun.lock"), "utf8")
  const manifest = JSON.parse(await readFile(resolve(root, "package.json"), "utf8"))
  for (const target of ["landing", "server", "mcp"]) {
    const output = resolve(temp, target)
    const child = Bun.spawn([process.execPath, "scripts/docker/prune-workspace.ts", `@inline-chat/${target}`, output, "--manifests-only"], {
      cwd: root, stdout: "pipe", stderr: "pipe",
    })
    const error = await new Response(child.stderr).text()
    expect(await child.exited, error).toBe(0)
    expect(await readFile(resolve(output, "json/bun.lock"), "utf8")).toBe(lock)
    expect(await readFile(resolve(output, "json/bunfig.toml"), "utf8")).toBe(await readFile(resolve(root, "bunfig.toml"), "utf8"))
    expect(JSON.parse(await readFile(resolve(output, "json/package.json"), "utf8")).workspaces).toEqual(manifest.workspaces)
    for (const pattern of manifest.workspaces) {
      for await (const path of new Bun.Glob(`${pattern}/package.json`).scan({ cwd: root })) {
        expect(await readFile(resolve(output, "json", path), "utf8")).toBe(await readFile(resolve(root, path), "utf8"))
      }
    }
    expect((await readdir(resolve(output, "full"))).sort()).toEqual(["bun.lock", "bunfig.toml", "package.json"])
    const repeat = Bun.spawn([process.execPath, "scripts/docker/prune-workspace.ts", `@inline-chat/${target}`, output, "--manifests-only"], {
      cwd: root, stdout: "ignore", stderr: "pipe",
    })
    expect(await new Response(repeat.stderr).text()).toContain("Output directory already exists")
    expect(await repeat.exited).not.toBe(0)
    expect(await readFile(resolve(output, "json/bun.lock"), "utf8")).toBe(lock)
  }
})
