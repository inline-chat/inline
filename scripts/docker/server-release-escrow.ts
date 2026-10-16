import { createHash } from "node:crypto"
import { constants } from "node:fs"
import { lstat, mkdir, open, readdir } from "node:fs/promises"
import { basename, resolve } from "node:path"
import { isBuildInput, prepareServerContext } from "./server-context"

type FileIdentity = { path: string; bytes: number; sha256: string }
type ImageIdentity = {
  path: string
  platform: "linux/amd64" | "linux/arm64"
  target: "runtime" | "coolify"
  configSha256: string
}
type EscrowManifest = {
  version: 1
  sourceRevision: string
  verification: "archive-bytes-and-image-config-only"
  files: FileIdentity[]
  images: ImageIdentity[]
}

const archivePaths = ["images/runtime-amd64.tar", "images/coolify-arm64.tar"] as const
const toolPaths = ["tools/server-release-escrow.ts", "tools/server-context.ts"] as const
const hex = (value: unknown, length: number): value is string =>
  typeof value === "string" && new RegExp(`^[a-f0-9]{${length}}$`).test(value)
const sha256 = (bytes: Uint8Array) => createHash("sha256").update(bytes).digest("hex")

function object(value: unknown): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) throw new Error("Expected an object")
  return value as Record<string, unknown>
}

function safeRelative(path: string): boolean {
  return path.length > 0 && !path.includes("\\") && path.split("/").every((part) => part !== "" && part !== "." && part !== "..")
}

function allowedFile(path: string): boolean {
  if (!safeRelative(path)) return false
  if (archivePaths.some((entry) => entry === path) || toolPaths.some((entry) => entry === path)) return true
  return path.startsWith("source/") && isBuildInput(path.slice("source/".length))
}

// Bounded memory, no symlink following, and exclusive destination creation.
// Leave a failed capture in place for inspection; only a final manifest marks completion.
async function fingerprint(path: string, destination?: string): Promise<Omit<FileIdentity, "path">> {
  const source = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW)
  let output: Awaited<ReturnType<typeof open>> | undefined
  try {
    const before = await source.stat()
    if (!before.isFile() || !Number.isSafeInteger(before.size)) throw new Error("Expected a regular file")
    if (destination) output = await open(destination, "wx", 0o600)
    const hash = createHash("sha256")
    const buffer = Buffer.alloc(1024 * 1024)
    let bytes = 0
    for (;;) {
      const chunk = await source.read(buffer, 0, buffer.length, null)
      if (chunk.bytesRead === 0) break
      const data = buffer.subarray(0, chunk.bytesRead)
      hash.update(data)
      if (output) await output.writeFile(data)
      bytes += chunk.bytesRead
      if (bytes > before.size) throw new Error("File changed during capture")
    }
    const after = await source.stat()
    if (bytes !== before.size || before.mtimeMs !== after.mtimeMs || before.ctimeMs !== after.ctimeMs)
      throw new Error("File changed during capture")
    if (output) await output.sync()
    return { bytes, sha256: hash.digest("hex") }
  } finally {
    await output?.close()
    await source.close()
  }
}

async function readSmall(path: string, maximum = 1024 * 1024): Promise<Buffer> {
  const file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW)
  try {
    const metadata = await file.stat()
    if (!metadata.isFile() || metadata.size > maximum) throw new Error("Oversized or non-regular metadata")
    const buffer = Buffer.alloc(maximum + 1)
    let bytes = 0
    while (bytes <= maximum) {
      const chunk = await file.read(buffer, bytes, buffer.length - bytes, null)
      if (!chunk.bytesRead) return buffer.subarray(0, bytes)
      bytes += chunk.bytesRead
    }
    throw new Error("Oversized metadata")
  } finally {
    await file.close()
  }
}

async function syncFile(path: string) {
  const file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW)
  try { await file.sync() } finally { await file.close() }
}

async function tar(archive: string, member?: string): Promise<string> {
  const child = Bun.spawn(member ? ["tar", "-xOf", archive, "--", member] : ["tar", "-tf", archive], {
    env: { PATH: process.env.PATH, LANG: "C" },
    stdout: "pipe",
    stderr: "ignore",
  })
  const timer = setTimeout(() => child.kill("SIGKILL"), 120_000)
  try {
    const chunks: Uint8Array[] = []
    let bytes = 0
    for await (const chunk of child.stdout) {
      bytes += chunk.length
      if (bytes > 2 * 1024 * 1024) throw new Error("Oversized archive metadata")
      chunks.push(chunk)
    }
    if ((await child.exited) !== 0) throw new Error("Cannot inspect Docker-save archive")
    return Buffer.concat(chunks).toString("utf8")
  } finally {
    clearTimeout(timer)
    child.kill("SIGKILL")
    await child.exited
  }
}

async function inspectArchive(archive: string, path: string, revision: string, index: number): Promise<ImageIdentity> {
  const members = (await tar(archive)).trimEnd().split("\n")
  if (new Set(members).size !== members.length || members.some((entry) => !safeRelative(entry.replace(/\/$/, ""))))
    throw new Error("Unsafe or duplicate archive member")
  if (!members.includes("manifest.json")) throw new Error("Expected an uncompressed Docker-save archive")
  const manifest: unknown = JSON.parse(await tar(archive, "manifest.json"))
  if (!Array.isArray(manifest) || manifest.length !== 1) throw new Error("Archive must contain exactly one image")
  const image = object(manifest[0])
  const configPath = image.Config
  if (typeof configPath !== "string" || !/^(?:blobs\/sha256\/[a-f0-9]{64}|[a-f0-9]{64}\.json)$/.test(configPath))
    throw new Error("Invalid image config path")
  if (!members.includes(configPath) || !Array.isArray(image.Layers) || image.Layers.length === 0 ||
    image.Layers.some((layer) => typeof layer !== "string" || !safeRelative(layer) || !members.includes(layer)))
    throw new Error("Missing image config or layers")
  const configText = await tar(archive, configPath)
  const configHash = sha256(Buffer.from(configText))
  if (configHash !== basename(configPath).replace(/\.json$/, "")) throw new Error("Image config checksum mismatch")
  const config = object(JSON.parse(configText))
  const platform = index === 0 ? "linux/amd64" : "linux/arm64"
  if (`${config.os}/${config.architecture}` !== platform) throw new Error(`Expected ${platform}`)
  const labels = object(object(config.config).Labels)
  if (labels["org.opencontainers.image.revision"] !== revision) throw new Error("Image source revision mismatch")
  return { path, platform, target: index === 0 ? "runtime" : "coolify", configSha256: configHash }
}

async function listFiles(root: string, prefix = ""): Promise<string[]> {
  const metadata = await lstat(resolve(root, prefix))
  if (!metadata.isDirectory() || metadata.isSymbolicLink()) throw new Error("Expected a real directory")
  const files: string[] = []
  for (const name of (await readdir(resolve(root, prefix))).sort()) {
    const path = prefix ? `${prefix}/${name}` : name
    const entry = await lstat(resolve(root, path))
    if (entry.isSymbolicLink()) throw new Error("Symlinks are not permitted")
    if (entry.isDirectory()) {
      if (!["source", "images", "tools"].some((base) => path === base || path.startsWith(`${base}/`)) ||
        (path.startsWith("source/") && !isBuildInput(`${path.slice(7)}/placeholder`)))
        throw new Error("Unexpected escrow directory")
      files.push(...await listFiles(root, path))
    } else {
      if (!entry.isFile() || (path !== "escrow.json" && !allowedFile(path))) throw new Error("Unexpected escrow file")
      files.push(path)
    }
  }
  return files.sort()
}

export async function captureEscrow(options: {
  root: string
  revision: string
  amd64Archive: string
  arm64Archive: string
  destination: string
}): Promise<{ manifestSha256: string; sourceRevision: string }> {
  for (const archive of [options.amd64Archive, options.arm64Archive]) {
    if (!allowedFile(`source/${basename(archive)}`) || !archive.endsWith(".tar"))
      throw new Error("Supply explicit non-hidden .tar image archives")
  }
  const destination = resolve(options.destination)
  await mkdir(destination, { mode: 0o700 })
  const source = await prepareServerContext(options.root, options.revision, resolve(destination, "source"))
  await mkdir(resolve(destination, "images"), { mode: 0o700 })
  await mkdir(resolve(destination, "tools"), { mode: 0o700 })
  const files: FileIdentity[] = []
  const images: ImageIdentity[] = []
  for (const [index, archive] of [options.amd64Archive, options.arm64Archive].entries()) {
    const path = archivePaths[index]!
    files.push({ path, ...await fingerprint(archive, resolve(destination, path)) })
    images.push(await inspectArchive(resolve(destination, path), path, source.commit, index))
  }
  // Tool bytes are separately hashed; they are not claimed to belong to the image commit.
  for (const path of toolPaths) {
    files.push({ path, ...await fingerprint(resolve(import.meta.dir, basename(path)), resolve(destination, path)) })
  }
  for (const path of await listFiles(destination)) {
    if (!files.some((file) => file.path === path)) {
      files.push({ path, ...await fingerprint(resolve(destination, path)) })
      await syncFile(resolve(destination, path))
    }
  }
  const manifest: EscrowManifest = {
    version: 1,
    sourceRevision: source.commit,
    verification: "archive-bytes-and-image-config-only",
    files: files.sort((a, b) => a.path.localeCompare(b.path)),
    images,
  }
  const content = Buffer.from(`${JSON.stringify(manifest, null, 2)}\n`)
  const completion = await open(resolve(destination, "escrow.json"), "wx", 0o600)
  try {
    await completion.writeFile(content)
    await completion.sync()
  } finally { await completion.close() }
  return { manifestSha256: sha256(content), sourceRevision: source.commit }
}

function parseManifest(content: Buffer): EscrowManifest {
  const value = object(JSON.parse(content.toString("utf8")))
  if (value.version !== 1 || !hex(value.sourceRevision, 40) ||
    value.verification !== "archive-bytes-and-image-config-only" || !Array.isArray(value.files) || !Array.isArray(value.images))
    throw new Error("Invalid escrow manifest")
  const files = value.files.map((entry): FileIdentity => {
    const file = object(entry)
    if (typeof file.path !== "string" || !allowedFile(file.path) || !hex(file.sha256, 64) ||
      typeof file.bytes !== "number" || !Number.isSafeInteger(file.bytes) || file.bytes < 0) throw new Error("Invalid file identity")
    return { path: file.path, bytes: file.bytes, sha256: file.sha256 }
  })
  if (new Set(files.map((file) => file.path)).size !== files.length) throw new Error("Duplicate file identity")
  const required = [...archivePaths, ...toolPaths, "source/source.json"]
  if (required.some((path) => !files.some((file) => file.path === path))) throw new Error("Missing required artifact")
  const images = value.images.map((entry, index): ImageIdentity => {
    const image = object(entry)
    const platform = index === 0 ? "linux/amd64" : "linux/arm64"
    const target = index === 0 ? "runtime" : "coolify"
    if (image.path !== archivePaths[index] || image.platform !== platform || image.target !== target || !hex(image.configSha256, 64))
      throw new Error("Invalid image identity")
    return { path: archivePaths[index]!, platform, target, configSha256: image.configSha256 }
  })
  if (images.length !== 2) throw new Error("Both image architectures are required")
  return { version: 1, sourceRevision: value.sourceRevision, verification: "archive-bytes-and-image-config-only", files, images }
}

export async function verifyEscrow(directory: string, expectedManifestSha256: string): Promise<EscrowManifest> {
  if (!hex(expectedManifestSha256, 64)) throw new Error("Supply an independently retained manifest SHA-256")
  const root = resolve(directory)
  const inventory = await listFiles(root)
  const content = await readSmall(resolve(root, "escrow.json"))
  if (sha256(content) !== expectedManifestSha256) throw new Error("Manifest checksum mismatch")
  const manifest = parseManifest(content)
  const expected = [...manifest.files.map((file) => file.path), "escrow.json"].sort()
  if (JSON.stringify(inventory) !== JSON.stringify(expected)) throw new Error("Escrow inventory mismatch")
  for (const file of manifest.files) {
    const actual = await fingerprint(resolve(root, file.path))
    if (actual.bytes !== file.bytes || actual.sha256 !== file.sha256) throw new Error(`Artifact checksum mismatch: ${file.path}`)
  }
  for (const [index, image] of manifest.images.entries()) {
    const actual = await inspectArchive(resolve(root, image.path), image.path, manifest.sourceRevision, index)
    if (actual.configSha256 !== image.configSha256) throw new Error("Image identity mismatch")
  }
  const source = object(JSON.parse((await readSmall(resolve(root, "source/source.json"))).toString("utf8")))
  if (source.commit !== manifest.sourceRevision) throw new Error("Source identity mismatch")
  return manifest
}

if (import.meta.main) {
  const [command, ...args] = process.argv.slice(2)
  if (command === "capture" && args.length === 4) {
    const result = await captureEscrow({
      root: resolve(import.meta.dir, "../.."), revision: args[0]!, amd64Archive: resolve(args[1]!),
      arm64Archive: resolve(args[2]!), destination: resolve(args[3]!),
    })
    console.info(JSON.stringify(result))
  } else if (command === "verify" && args.length === 2) {
    const manifest = await verifyEscrow(args[0]!, args[1]!)
    console.info(JSON.stringify({ sourceRevision: manifest.sourceRevision, files: manifest.files.length, verification: manifest.verification }))
  } else {
    throw new Error("Usage: bun --no-env-file server-release-escrow.ts capture <commit> <amd64.tar> <arm64.tar> <new-directory> | verify <directory> <independent-manifest-sha256>")
  }
}
