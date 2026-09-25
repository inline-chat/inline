import assert from "node:assert/strict"
import { execFileSync } from "node:child_process"
import { createHash } from "node:crypto"
import { mkdir, mkdtemp, readFile, readdir, writeFile } from "node:fs/promises"
import { createRequire } from "node:module"
import os from "node:os"
import path from "node:path"

const [artifactDir, hostVersion] = process.argv.slice(2)
if (!artifactDir || !hostVersion) throw new Error("usage: check-openclaw-admission.mjs ARTIFACT_DIR HOST_VERSION")
const manifest = JSON.parse(await readFile(path.join(artifactDir, "manifest.json"), "utf8"))
const plugin = manifest.packages.find((entry) => entry.name === "@inline-openclaw/inline")
assert.ok(plugin)
const archive = path.join(artifactDir, plugin.file)
assert.equal(createHash("sha256").update(await readFile(archive)).digest("hex"), plugin.sha256)
const scratch = await mkdtemp(path.join(os.tmpdir(), "inline-openclaw-admission-"))
const hostDir = path.join(scratch, "host")
const home = path.join(scratch, "home")
await mkdir(hostDir, { recursive: true })
await mkdir(home, { recursive: true })
await writeFile(path.join(hostDir, "package.json"), JSON.stringify({ private: true, dependencies: { openclaw: hostVersion } }))
execFileSync("npm", ["install", "--ignore-scripts", "--no-audit", "--no-fund"], {
  cwd: hostDir, stdio: "inherit", timeout: 180_000,
})
const installedHost = JSON.parse(await readFile(path.join(hostDir, "node_modules/openclaw/package.json"), "utf8"))
if (hostVersion !== "latest") assert.equal(installedHost.version, hostVersion)
const executable = path.join(hostDir, "node_modules/openclaw/openclaw.mjs")
const env = { ...process.env, HOME: home, OPENCLAW_STATE_DIR: path.join(home, "state") }
const cli = (args) => execFileSync(process.execPath, [executable, ...args], {
  env, cwd: hostDir, encoding: "utf8", timeout: 90_000,
})
console.log(`OpenClaw host ${installedHost.version}; plugin ${plugin.version}; source ${manifest.sourceSha}`)
console.log(cli(["plugins", "install", `npm-pack:${archive}`, "--force", "--accept-capabilities"]))
const projectsRoot = path.join(home, "state/npm/projects")
const projects = await readdir(projectsRoot)
assert.equal(projects.length, 1, "one disposable OpenClaw plugin project")
const project = path.join(projectsRoot, projects[0])
const pluginRoot = path.join(project, "node_modules/@inline-openclaw/inline")
const candidateDeps = ["@inline-chat/realtime-sdk", "@inline-chat/protocol"].map((name) => {
  const item = manifest.packages.find((entry) => entry.name === name)
  assert.ok(item, `missing ${name} candidate`)
  return item
})
execFileSync("npm", ["install", "--no-save", "--ignore-scripts", "--no-audit", "--no-fund",
  ...candidateDeps.map((item) => path.join(artifactDir, item.file))], {
  cwd: project, stdio: "inherit", timeout: 120_000,
})
const pluginRequire = createRequire(path.join(pluginRoot, "package.json"))
const sdkEntry = pluginRequire.resolve("@inline-chat/realtime-sdk")
const sdkRequire = createRequire(sdkEntry)
const protocolEntry = sdkRequire.resolve("@inline-chat/protocol")
for (const [item, installedEntry] of [[plugin, path.join(pluginRoot, "dist/index.js")],
  [candidateDeps[0], sdkEntry], [candidateDeps[1], protocolEntry]]) {
  const candidateEntry = execFileSync("tar", ["-xOzf", path.join(artifactDir, item.file), "package/dist/index.js"])
  assert.deepEqual(await readFile(installedEntry), candidateEntry, `${item.name} runtime bytes differ from this SHA`)
}
const list = JSON.parse(cli(["plugins", "list", "--json"]))
const entry = list.plugins?.find((item) => item.id === "inline")
assert.ok(entry, "Inline must be discovered by the installed host")
assert.notEqual(entry.status, "error", "Inline host registry error")
const inspect = JSON.parse(cli(["plugins", "inspect", "inline", "--json"]))
assert.equal(inspect.plugin?.id, "inline")
assert.notEqual(inspect.plugin?.status, "error")
assert.equal(inspect.plugin?.version, plugin.version)
console.log(`Installed host registered Inline: ${JSON.stringify({ id: entry.id, status: entry.status, version: inspect.plugin.version })}`)
