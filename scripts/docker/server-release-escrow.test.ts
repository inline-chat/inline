import { expect, test } from "bun:test"
import { createHash } from "node:crypto"
import { mkdtemp, mkdir, readFile, rm, symlink, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { resolve } from "node:path"
import { captureEscrow, verifyEscrow } from "./server-release-escrow"

const hash = (content: string | Buffer) => createHash("sha256").update(content).digest("hex")

async function run(args: string[], cwd: string): Promise<string> {
  const child = Bun.spawn(args, {
    cwd,
    env: { PATH: process.env.PATH, GIT_CONFIG_NOSYSTEM: "1", GIT_CONFIG_GLOBAL: "/dev/null" },
    stdout: "pipe", stderr: "pipe",
  })
  const [output, error] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text()])
  expect(await child.exited, error).toBe(0)
  return output.trim()
}

async function fixture() {
  const temp = await mkdtemp(resolve(tmpdir(), "inline-escrow-"))
  const root = resolve(temp, "repo")
  await mkdir(root)
  const files: Record<string, string> = {
    "package.json": JSON.stringify({ workspaces: ["server"] }),
    "bun.lock": "synthetic lock", "bunfig.toml": "",
    "server/package.json": JSON.stringify({ name: "@inline-chat/server" }),
    "server/src/index.ts": "export const committed = true",
    "server/Dockerfile": "FROM scratch", "server/Dockerfile.dockerignore": "**/.env*",
    "scripts/docker/prune-workspace.ts": "", "scripts/docker/smoke-artifact.ts": "",
  }
  for (const [path, content] of Object.entries(files)) {
    await mkdir(resolve(root, path, ".."), { recursive: true })
    await writeFile(resolve(root, path), content)
  }
  await run(["git", "init"], root)
  await run(["git", "add", "."], root)
  await run(["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "-m", "fixture"], root)
  const revision = await run(["git", "rev-parse", "HEAD"], root)
  const archive = async (architecture: string, imageRevision = revision, modern = false) => {
    const folder = await mkdtemp(resolve(temp, "image-"))
    // Intentionally not runnable: escrow identity is distinct from runtime qualification.
    const config = JSON.stringify({ os: "linux", architecture, config: { Labels: { "org.opencontainers.image.revision": imageRevision } } })
    const configPath = modern ? `blobs/sha256/${hash(config)}` : `${hash(config)}.json`
    const layer = Buffer.alloc(2 * 1024 * 1024 + 19, 65)
    const layerPath = modern ? `blobs/sha256/${hash(layer)}` : "layer.tar"
    await mkdir(resolve(folder, configPath, ".."), { recursive: true })
    await writeFile(resolve(folder, configPath), config)
    await writeFile(resolve(folder, layerPath), layer)
    await writeFile(resolve(folder, "manifest.json"), JSON.stringify([{ Config: configPath, Layers: [layerPath], RepoTags: ["fixture:synthetic"] }]))
    const path = `${folder}.tar`
    await run(["tar", "-cf", path, "manifest.json", configPath, layerPath], folder)
    return path
  }
  const amd64Archive = await archive("amd64")
  const arm64Archive = await archive("arm64", revision, true)
  const destination = resolve(temp, "escrow")
  return { temp, root, revision, amd64Archive, arm64Archive, destination, archive }
}

test("retains committed source and two platform identities; verifies offline from a moved directory", async () => {
  const f = await fixture()
  try {
    await writeFile(resolve(f.root, "server/src/index.ts"), "dirty source is excluded")
    const result = await captureEscrow(f)
    expect(result.sourceRevision).toBe(f.revision)
    expect(await readFile(resolve(f.destination, "source/server/src/index.ts"), "utf8")).toBe("export const committed = true")
    const moved = resolve(f.temp, "independent-copy")
    await run(["cp", "-R", f.destination, moved], f.temp)
    await rm(f.root, { recursive: true })
    await rm(f.destination, { recursive: true })
    await rm(f.amd64Archive)
    await rm(f.arm64Archive)
    const manifest = await verifyEscrow(moved, result.manifestSha256)
    expect(manifest.images.map((image) => [image.platform, image.target])).toEqual([["linux/amd64", "runtime"], ["linux/arm64", "coolify"]])
    expect(manifest.verification).toBe("archive-bytes-and-image-config-only")
    const output = await run([process.execPath, "--no-env-file", resolve(moved, "tools/server-release-escrow.ts"), "verify", moved, result.manifestSha256], f.temp)
    expect(JSON.parse(output).sourceRevision).toBe(f.revision)
  } finally { await rm(f.temp, { recursive: true, force: true }) }
})

test("rejects archive and source corruption, manifest replacement and unexpected files", async () => {
  const f = await fixture()
  try {
    const result = await captureEscrow(f)
    for (const path of ["source/server/src/index.ts", "images/runtime-amd64.tar", "escrow.json"]) {
      const file = resolve(f.destination, path)
      const original = await readFile(file)
      await writeFile(file, Buffer.concat([original, Buffer.from("corruption")]))
      await expect(verifyEscrow(f.destination, result.manifestSha256)).rejects.toThrow("checksum mismatch")
      await writeFile(file, original)
    }
    await writeFile(resolve(f.destination, "source/private.key"), "synthetic forbidden file")
    await expect(verifyEscrow(f.destination, result.manifestSha256)).rejects.toThrow("Unexpected escrow file")
    await rm(resolve(f.destination, "source/private.key"))
    await writeFile(resolve(f.destination, "source/extra.ts"), "unrecorded")
    await expect(verifyEscrow(f.destination, result.manifestSha256)).rejects.toThrow("inventory mismatch")
  } finally { await rm(f.temp, { recursive: true, force: true }) }
})

test("refuses symlinked inputs, output reuse and symlinks in a recovered escrow", async () => {
  const f = await fixture()
  try {
    const result = await captureEscrow(f)
    await expect(captureEscrow(f)).rejects.toThrow()
    const archived = resolve(f.destination, "images/runtime-amd64.tar")
    await rm(archived)
    await symlink(f.amd64Archive, archived)
    await expect(verifyEscrow(f.destination, result.manifestSha256)).rejects.toThrow("Symlinks")
    const link = resolve(f.temp, "input-link.tar")
    await symlink(f.amd64Archive, link)
    await expect(captureEscrow({ ...f, amd64Archive: link, destination: resolve(f.temp, "rejected") })).rejects.toThrow()
    expect(await Bun.file(resolve(f.temp, "rejected/escrow.json")).exists()).toBe(false)
  } finally { await rm(f.temp, { recursive: true, force: true }) }
})

test("refuses mismatched source/platform and incomplete images before writing completion manifest", async () => {
  const f = await fixture()
  try {
    const wrongRevision = await f.archive("amd64", "f".repeat(40))
    for (const [name, archive] of [["platform", f.arm64Archive], ["source", wrongRevision]]) {
      const destination = resolve(f.temp, name!)
      await expect(captureEscrow({ ...f, amd64Archive: archive!, destination })).rejects.toThrow(name === "platform" ? "linux/amd64" : "source revision")
      expect(await Bun.file(resolve(destination, "escrow.json")).exists()).toBe(false)
    }
    const invalid = resolve(f.temp, "invalid.tar")
    await writeFile(invalid, "not a docker archive")
    await expect(captureEscrow({ ...f, amd64Archive: invalid, destination: resolve(f.temp, "invalid") })).rejects.toThrow()
  } finally { await rm(f.temp, { recursive: true, force: true }) }
})

test("rejects manifest path traversal and duplicate identities even with a supplied matching checksum", async () => {
  const f = await fixture()
  try {
    await captureEscrow(f)
    const path = resolve(f.destination, "escrow.json")
    const original = await readFile(path, "utf8")
    for (const kind of ["traversal", "duplicate"]) {
      const manifest = JSON.parse(original)
      if (kind === "traversal") manifest.files[0].path = "../outside"
      else manifest.files.push(manifest.files[0])
      const content = JSON.stringify(manifest)
      await writeFile(path, content)
      await expect(verifyEscrow(f.destination, hash(content))).rejects.toThrow(kind === "traversal" ? "Invalid file identity" : "Duplicate file identity")
    }
  } finally { await rm(f.temp, { recursive: true, force: true }) }
})

test("rejects duplicate archive members, multiple images and a spoofed config filename checksum", async () => {
  const f = await fixture()
  try {
    for (const kind of ["duplicate", "multiple", "config"]) {
      const archive = await f.archive("amd64")
      const folder = archive.slice(0, -4)
      const manifestPath = resolve(folder, "manifest.json")
      const images = JSON.parse(await readFile(manifestPath, "utf8"))
      if (kind === "duplicate") {
        await run(["tar", "-rf", archive, "manifest.json"], folder)
      } else {
        if (kind === "multiple") await writeFile(manifestPath, JSON.stringify([...images, ...images]))
        else await writeFile(resolve(folder, images[0].Config), "{}")
        await run(["tar", "-cf", archive, "manifest.json", images[0].Config, "layer.tar"], folder)
      }
      await expect(captureEscrow({ ...f, amd64Archive: archive, destination: resolve(f.temp, kind) })).rejects.toThrow(
        kind === "duplicate" ? "duplicate archive member" : kind === "multiple" ? "exactly one image" : "config checksum mismatch",
      )
    }
  } finally { await rm(f.temp, { recursive: true, force: true }) }
})
