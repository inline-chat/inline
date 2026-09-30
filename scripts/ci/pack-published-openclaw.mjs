import { execFileSync } from "node:child_process"
import { createHash } from "node:crypto"
import { mkdir, readFile, writeFile } from "node:fs/promises"
import path from "node:path"

const directory = path.resolve(process.argv[2] ?? "")
if (!process.argv[2]) throw new Error("usage: pack-published-openclaw.mjs OUTPUT_DIR")
await mkdir(directory, { recursive: true })
const packages = []
async function pack(spec) {
  const packed = JSON.parse(execFileSync("npm", ["pack", spec, "--ignore-scripts", "--json", "--pack-destination", directory], { encoding: "utf8", timeout: 60_000 }))[0]
  const archive = path.join(directory, packed.filename)
  packages.push({ name: packed.name, version: packed.version, file: packed.filename,
    sha256: createHash("sha256").update(await readFile(archive)).digest("hex") })
  return JSON.parse(execFileSync("tar", ["-xOzf", archive, "package/package.json"], { encoding: "utf8" }))
}
const plugin = await pack("@inline-openclaw/inline@latest")
const sdk = await pack(`@inline-chat/realtime-sdk@${plugin.dependencies["@inline-chat/realtime-sdk"]}`)
await pack(`@inline-chat/protocol@${sdk.dependencies["@inline-chat/protocol"]}`)
await writeFile(path.join(directory, "manifest.json"), JSON.stringify({ sourceSha: "published-npm", packages }, null, 2) + "\n")
