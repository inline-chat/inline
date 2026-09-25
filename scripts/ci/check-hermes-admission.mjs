import assert from "node:assert/strict"
import { execFileSync } from "node:child_process"
import { createHash } from "node:crypto"
import { createRequire } from "node:module"
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises"
import os from "node:os"
import path from "node:path"

const [artifactDir, hermesBin, pythonBin] = process.argv.slice(2)
if (!artifactDir || !hermesBin || !pythonBin) throw new Error("usage: check-hermes-admission.mjs ARTIFACT_DIR HERMES_BIN PYTHON_BIN")
const manifest = JSON.parse(await readFile(path.join(artifactDir, "manifest.json"), "utf8"))
const selected = ["@inline-chat/protocol", "@inline-chat/realtime-sdk", "@inline-chat/hermes-agent-adapter"]
const packages = selected.map((name) => {
  const item = manifest.packages.find((entry) => entry.name === name)
  assert.ok(item, `missing ${name} candidate`)
  return item
})
for (const pkg of packages) {
  assert.equal(createHash("sha256").update(await readFile(path.join(artifactDir, pkg.file))).digest("hex"), pkg.sha256)
}
const scratch = await mkdtemp(path.join(os.tmpdir(), "inline-hermes-admission-"))
const consumer = path.join(scratch, "consumer")
const home = path.join(scratch, "hermes")
await mkdir(consumer, { recursive: true })
await mkdir(home, { recursive: true })
await writeFile(path.join(consumer, "package.json"), JSON.stringify({ private: true, type: "module" }))
execFileSync("npm", ["install", "--ignore-scripts", "--no-audit", "--no-fund", ...packages.map((pkg) => path.join(artifactDir, pkg.file))], {
  cwd: consumer, stdio: "inherit", timeout: 180_000,
})
const installedHermes = path.join(consumer, "node_modules/@inline-chat/hermes-agent-adapter")
const hermesRequire = createRequire(path.join(installedHermes, "package.json"))
const sdkEntry = hermesRequire.resolve("@inline-chat/realtime-sdk")
const protocolEntry = createRequire(sdkEntry).resolve("@inline-chat/protocol")
for (const [pkg, installedEntry, archivedEntry] of [
  [packages[0], protocolEntry, "package/dist/index.js"],
  [packages[1], sdkEntry, "package/dist/index.js"],
  [packages[2], path.join(installedHermes, "dist/install.js"), "package/dist/install.js"],
]) {
  const candidateBytes = execFileSync("tar", ["-xOzf", path.join(artifactDir, pkg.file), archivedEntry])
  assert.deepEqual(await readFile(installedEntry), candidateBytes, `${pkg.name} runtime bytes differ from this SHA`)
}
const env = { ...process.env, HERMES_HOME: home, HOME: scratch, INLINE_NODE_BIN: process.execPath }
const adapterBin = path.join(consumer, "node_modules/.bin/inline-hermes")
const run = (bin, args) => execFileSync(bin, args, { cwd: consumer, env, encoding: "utf8", timeout: 60_000 })
assert.match(run(adapterBin, ["help"]), /inline-hermes install/)
console.log(run(adapterBin, ["install", "--hermes-home", home, "--force", "--json"]))
const before = run(hermesBin, ["plugins", "list", "--plain", "--no-bundled"])
assert.match(before, /inline-platform/)
console.log(run(hermesBin, ["plugins", "enable", "inline-platform"]))
const after = run(hermesBin, ["plugins", "list", "--plain", "--no-bundled"])
assert.match(after, /enabled\s+user\s+\S+\s+inline-platform/)
const pythonCheck = `import sys; from pathlib import Path; sys.path.insert(0, str(Path(${JSON.stringify(home)}) / 'plugins')); from inline.adapter import InlineAdapter; from inline.tools import INLINE_TOOL_SCHEMA; assert INLINE_TOOL_SCHEMA['name'] == 'inline'`
console.log(run(pythonBin, ["-c", pythonCheck]))
console.log(`Hermes native admission passed from ${manifest.sourceSha}; ${packages.at(-1).version}`)
