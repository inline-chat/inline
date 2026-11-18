import { execFileSync } from "node:child_process"
import { createHash } from "node:crypto"
import { mkdir, readFile, writeFile } from "node:fs/promises"
import path from "node:path"
import { pathToFileURL } from "node:url"

export function readPackageManifest(archive) {
  return JSON.parse(execFileSync("tar", ["-xOzf", archive, "package/package.json"], { encoding: "utf8" }))
}

export async function packPublished(directory, spec) {
  const [packed] = JSON.parse(execFileSync("npm", ["pack", spec, "--ignore-scripts", "--json", "--pack-destination", directory], {
    encoding: "utf8", timeout: 60_000,
  }))
  const archive = path.join(directory, packed.filename)
  return { name: packed.name, version: packed.version, file: packed.filename,
    sha256: createHash("sha256").update(await readFile(archive)).digest("hex") }
}

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  if (!process.argv[2]) throw new Error("usage: pack-published-openclaw.mjs OUTPUT_DIR [PACKAGE_SPEC]")
  const directory = path.resolve(process.argv[2])
  await mkdir(directory, { recursive: true })
  const plugin = await packPublished(directory, process.argv[3] ?? "@inline-openclaw/inline@latest")
  const packages = [plugin]
  let parent = plugin
  for (const name of ["@inline-chat/realtime-sdk", "@inline-chat/protocol"]) {
    const pkg = readPackageManifest(path.join(directory, parent.file))
    parent = await packPublished(directory, `${name}@${pkg.dependencies[name]}`)
    packages.push(parent)
  }
  await writeFile(path.join(directory, "manifest.json"), JSON.stringify({ sourceSha: "published-npm", packages }, null, 2) + "\n")
}
