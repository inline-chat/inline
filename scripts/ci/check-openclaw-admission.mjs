import assert from "node:assert/strict"
import { execFile, execFileSync } from "node:child_process"
import { createHash } from "node:crypto"
import { copyFile, mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises"
import { createRequire } from "node:module"
import os from "node:os"
import path from "node:path"
import { pathToFileURL } from "node:url"
import { promisify } from "node:util"
import { assertAdmissionSource, withCandidateRegistry } from "./npm-candidate-registry.mjs"
import { packPublished, readPackageManifest } from "./pack-published-openclaw.mjs"

const args = process.argv.slice(2)
const [artifactDir, hostVersion, mode] = args
if (!artifactDir || !hostVersion || args.length > 3 || (mode && mode !== "--candidate")) {
  throw new Error("usage: check-openclaw-admission.mjs ARTIFACT_DIR HOST_VERSION [--candidate]")
}
const manifest = JSON.parse(await readFile(path.join(artifactDir, "manifest.json"), "utf8"))
assertAdmissionSource(manifest, mode === "--candidate")
const plugin = manifest.packages.find((entry) => entry.name === "@inline-openclaw/inline")
assert.ok(plugin)
const archive = path.join(artifactDir, plugin.file)
assert.equal(createHash("sha256").update(await readFile(archive)).digest("hex"), plugin.sha256)
const scratch = await mkdtemp(path.join(os.tmpdir(), "inline-openclaw-admission-"))
const hostDir = path.join(scratch, "host")
const home = path.join(scratch, "home")
const exec = promisify(execFile)
try {
await mkdir(hostDir, { recursive: true })
await mkdir(home, { recursive: true })
await writeFile(path.join(hostDir, "package.json"), JSON.stringify({ private: true, dependencies: { openclaw: hostVersion } }))
execFileSync("npm", ["install", "--ignore-scripts", "--no-audit", "--no-fund"], {
  cwd: hostDir, stdio: "inherit", timeout: 180_000,
})
const installedHost = JSON.parse(await readFile(path.join(hostDir, "node_modules/openclaw/package.json"), "utf8"))
if (hostVersion !== "latest") assert.equal(installedHost.version, hostVersion)
const executable = path.join(hostDir, "node_modules/openclaw/openclaw.mjs")
// The CI matrix may export OPENCLAW_VERSION=latest, but OpenClaw treats it as
// its compatibility version. Give the real CLI the installed version, not an npm spec.
const env = { ...process.env, OPENCLAW_VERSION: installedHost.version, HOME: home, OPENCLAW_STATE_DIR: path.join(home, "state") }
const cli = async (args, registryEnv = {}) => {
  // Keep the event loop free while npm inside the real CLI fetches candidates.
  const result = await exec(process.execPath, [executable, ...args], {
    env: { ...env, ...registryEnv }, cwd: hostDir, encoding: "utf8", timeout: 90_000, maxBuffer: 10 * 1024 * 1024,
  })
  if (result.stderr) process.stderr.write(result.stderr)
  return result.stdout
}
console.log(`OpenClaw host ${installedHost.version}; plugin ${plugin.version}; source ${manifest.sourceSha}`)
const install = async (registryEnv = {}) => {
  console.log(await cli(["plugins", "install", `npm-pack:${archive}`, "--force", "--accept-capabilities"], registryEnv))
}
const dependencyDir = mode === "--candidate" ? path.join(scratch, "dependencies") : artifactDir
const dependencies = []
let parent = readPackageManifest(archive)
let useCandidates = mode === "--candidate"
if (useCandidates) await mkdir(dependencyDir)
for (const name of ["@inline-chat/realtime-sdk", "@inline-chat/protocol"]) {
  const pin = parent.dependencies[name]
  assert.match(pin, /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/, `expected exact ${name} pin`)
  const candidate = manifest.packages.find((item) => item.name === name && item.version === pin)
  let receipt = candidate
  if (mode === "--candidate") {
    // A released SDK carries its own published protocol, even if the workspace
    // happens to carry a protocol candidate with the same version.
    useCandidates = useCandidates && Boolean(candidate)
    if (useCandidates) {
      assert.equal(path.basename(candidate.file), candidate.file)
      await copyFile(path.join(artifactDir, candidate.file), path.join(dependencyDir, candidate.file))
    } else {
      receipt = await packPublished(dependencyDir, `${name}@${pin}`)
    }
  }
  assert.ok(receipt, `missing ${name}@${pin} artifact`)
  assert.equal(receipt.name, name)
  assert.equal(receipt.version, pin)
  dependencies.push(receipt)
  parent = readPackageManifest(path.join(dependencyDir, receipt.file))
}
if (mode === "--candidate") {
  await withCandidateRegistry(dependencyDir, { ...manifest, packages: dependencies }, ({ env }) => install(env))
} else {
  await install()
}
const projectsRoot = path.join(home, "state/npm/projects")
const projects = await readdir(projectsRoot)
assert.equal(projects.length, 1, "one disposable OpenClaw plugin project")
const project = path.join(projectsRoot, projects[0])
const pluginRoot = path.join(project, "node_modules/@inline-openclaw/inline")
// `plugins list/inspect` only evaluate the light entry; the gateway imports the channel
// entry lazily, so load it against this host to catch removed plugin-sdk exports. Run it
// while the host's peer link to openclaw exists.
const channelEntry = pathToFileURL(path.join(pluginRoot, "dist/channel-plugin-api.js")).href
const channel = JSON.parse(execFileSync(process.execPath, ["--input-type=module", "-e",
  `const { inlineChannelPlugin } = await import(${JSON.stringify(channelEntry)}); console.log(JSON.stringify({ id: inlineChannelPlugin?.id }))`,
], { env, cwd: hostDir, encoding: "utf8", timeout: 60_000 }).trim().split("\n").at(-1))
assert.equal(channel.id, "inline", "Inline channel entry must load against the installed host")
const pluginRequire = createRequire(path.join(pluginRoot, "package.json"))
const sdkEntry = pluginRequire.resolve("@inline-chat/realtime-sdk")
const sdkRequire = createRequire(sdkEntry)
const protocolEntry = sdkRequire.resolve("@inline-chat/protocol")
for (const [item, directory, installedEntry] of [[plugin, artifactDir, path.join(pluginRoot, "dist/index.js")],
  [dependencies[0], dependencyDir, sdkEntry], [dependencies[1], dependencyDir, protocolEntry]]) {
  const expectedArchive = path.join(directory, item.file)
  assert.equal(createHash("sha256").update(await readFile(expectedArchive)).digest("hex"), item.sha256)
  const expectedEntry = execFileSync("tar", ["-xOzf", expectedArchive, "package/dist/index.js"])
  assert.deepEqual(await readFile(installedEntry), expectedEntry, `${item.name}@${item.version} runtime bytes differ from its archive`)
}
const list = JSON.parse(await cli(["plugins", "list", "--json"]))
const entry = list.plugins?.find((item) => item.id === "inline")
assert.ok(entry, "Inline must be discovered by the installed host")
assert.notEqual(entry.status, "error", "Inline host registry error")
const inspect = JSON.parse(await cli(["plugins", "inspect", "inline", "--json"]))
assert.equal(inspect.plugin?.id, "inline")
assert.notEqual(inspect.plugin?.status, "error")
assert.equal(inspect.plugin?.version, plugin.version)
console.log(`Installed host registered Inline: ${JSON.stringify({ id: entry.id, status: entry.status, version: inspect.plugin.version, channel: channel.id })}`)
} finally {
  await rm(scratch, { recursive: true, force: true })
}
