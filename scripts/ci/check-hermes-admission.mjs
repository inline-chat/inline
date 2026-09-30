import assert from "node:assert/strict"
import { execFileSync } from "node:child_process"
import { createHash } from "node:crypto"
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises"
import os from "node:os"
import path from "node:path"

const args = process.argv.slice(2)
const mode = args.shift()
const artifact = mode === "--artifact" ? path.resolve(args.shift()) : undefined
const [hermesBin, pythonBin] = args
if (!mode || !hermesBin || !pythonBin) throw new Error("usage: check-hermes-admission.mjs {ARTIFACT_DIR|--latest|--artifact TARBALL} HERMES_BIN PYTHON_BIN")
let installSpec = "@inline-chat/hermes-agent-adapter@latest"
let provenance = "npm latest stable"
if (artifact) {
  installSpec = artifact
  provenance = `sha256:${createHash("sha256").update(await readFile(artifact)).digest("hex")}`
} else if (mode !== "--latest") {
  const artifactDir = path.resolve(mode)
  const manifest = JSON.parse(await readFile(path.join(artifactDir, "manifest.json"), "utf8"))
  const pkg = manifest.packages.find((entry) => entry.name === "@inline-chat/hermes-agent-adapter")
  assert.ok(pkg, "missing Hermes candidate")
  installSpec = path.join(artifactDir, pkg.file)
  assert.equal(createHash("sha256").update(await readFile(installSpec)).digest("hex"), pkg.sha256)
  provenance = `${manifest.sourceSha}; ${pkg.version}; sha256:${pkg.sha256}`
}
const scratch = await mkdtemp(path.join(os.tmpdir(), "inline-hermes-admission-"))
const consumer = path.join(scratch, "consumer")
const home = path.join(scratch, "hermes")
await mkdir(consumer, { recursive: true })
await mkdir(home, { recursive: true })
await writeFile(path.join(consumer, "package.json"), JSON.stringify({ private: true, type: "module" }))
execFileSync("npm", ["install", "--ignore-scripts", "--no-audit", "--no-fund", installSpec], {
  cwd: consumer, stdio: "inherit", timeout: 180_000,
})
const installedHermes = path.join(consumer, "node_modules/@inline-chat/hermes-agent-adapter")
const installedManifest = JSON.parse(await readFile(path.join(installedHermes, "package.json"), "utf8"))
console.log(`Testing installed adapter ${installedManifest.version}; ${provenance}`)
if (mode !== "--latest") {
  const bytes = execFileSync("tar", ["-xOzf", installSpec, "package/dist/install.js"])
  assert.deepEqual(await readFile(path.join(installedHermes, "dist/install.js")), bytes)
}
const env = { ...process.env, HERMES_HOME: home, HOME: scratch, INLINE_NODE_BIN: process.execPath }
const adapterBin = path.join(consumer, "node_modules/.bin/inline-hermes")
const run = (bin, args, timeout = 180_000) => execFileSync(bin, args, { cwd: consumer, env, encoding: "utf8", timeout })
assert.match(run(adapterBin, ["help"]), /inline-hermes install/)
console.log(run(adapterBin, ["install", "--hermes-home", home, "--force", "--json"]))
for (const file of ["adapter.py", "cli.py", "tools.py", "plugin.yaml", "sidecar/index.mjs"]) {
  assert.deepEqual(
    await readFile(path.join(home, "plugins/inline", file)),
    await readFile(path.join(installedHermes, "plugin/inline", file)),
    `installed plugin ${file} differs from packed package`,
  )
}
const before = run(hermesBin, ["plugins", "list", "--plain", "--no-bundled"])
assert.match(before, /inline-platform/)
console.log(run(hermesBin, ["plugins", "enable", "inline-platform"]))
const after = run(hermesBin, ["plugins", "list", "--plain", "--no-bundled"])
assert.match(after, /enabled\s+user\s+\S+\s+inline-platform/)
console.log(run(pythonBin, [path.resolve("scripts/ci/check-hermes-host.py")], 60_000))
console.log(`Hermes native admission passed: ${provenance}`)
