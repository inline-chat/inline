// Native Git/subdirectory installation, matching the Hermes source catalog.
// Transport checks below are offline; no live Inline account or provider is used.
import assert from "node:assert/strict"
import { execFileSync, spawn } from "node:child_process"
import { cp, mkdir, mkdtemp, readFile, readdir, stat } from "node:fs/promises"
import net from "node:net"
import os from "node:os"
import path from "node:path"
import { fileURLToPath, pathToFileURL } from "node:url"
import { once } from "node:events"

const [sourceArg, hermesBin, pythonBin, publicIdentifier, publicRevision] = process.argv.slice(2)
if (!sourceArg || !hermesBin || !pythonBin || Boolean(publicIdentifier) !== Boolean(publicRevision)) {
  throw new Error("usage: check-hermes-source.mjs SOURCE_PLUGIN_DIR HERMES_BIN PYTHON_BIN [GIT_IDENTIFIER EXACT_SHA]")
}
const source = path.resolve(sourceArg)
const scratch = await mkdtemp(path.join(os.tmpdir(), "inline-hermes-source-"))
const home = path.join(scratch, "hermes")
await mkdir(home)
let identifier = publicIdentifier
let revision = publicRevision
if (!identifier) {
  // Native install consumes Git, so freeze current source bytes in a disposable
  // local repository. This neither commits nor modifies the working repository.
  const fixture = path.join(scratch, "fixture")
  await cp(source, path.join(fixture, "plugin"), {
    recursive: true,
    filter: (file) => !file.split(path.sep).some((part) => part === ".env" || part.startsWith(".env.") || part === "__pycache__"),
  })
  const git = (args) => execFileSync("git", args, { cwd: fixture, encoding: "utf8" })
  git(["init", "-q"])
  git(["add", "plugin"])
  git(["-c", "user.name=Hermes CI", "-c", "user.email=hermes-ci@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "freeze source plugin test fixture"])
  revision = git(["rev-parse", "HEAD"]).trim()
  identifier = `${pathToFileURL(fixture).href}#plugin`
}
assert.match(revision, /^[a-f0-9]{40}$/)
const env = {
  ...process.env, HOME: scratch, HERMES_HOME: home, INLINE_NODE_BIN: process.execPath,
  INLINE_TOKEN: "offline-test-token", INLINE_BOT_TOKEN: "", INLINE_BASE_URL: "http://127.0.0.1:1",
  INLINE_PLUGIN_TELEMETRY: "0", DO_NOT_TRACK: "1",
}
const run = (bin, args, timeout = 180_000) => execFileSync(bin, args, {
  cwd: scratch, env, encoding: "utf8", timeout, stdio: ["ignore", "pipe", "pipe"],
})
// No --force, --no-deps, reviewed-pin shortcut, or disabled security scanner.
console.log(run(hermesBin, ["plugins", "install", identifier, "--ref", revision, "--enable"]))
const installed = path.join(home, "plugins", "inline-platform")
assert.ok((await stat(installed)).isDirectory())
assert.ok(!(await readdir(path.join(home, "plugins"))).includes("inline"), "native install created legacy inline directory")
for (const file of ["__init__.py", "adapter.py", "cli.py", "tools.py", "plugin.yaml", "README.md", "LICENSE", "sidecar/index.mjs"]) {
  assert.deepEqual(await readFile(path.join(installed, file)), await readFile(path.join(source, file)), `native install changed ${file}`)
}
const metadata = JSON.parse(await readFile(path.join(home, "plugins", ".install-metadata.json"), "utf8"))
assert.equal(metadata["inline-platform"].revision, revision)
assert.equal(metadata["inline-platform"].pinned, true)
assert.equal(typeof metadata["inline-platform"].source, "string")
const expectedVersion = /^version:\s*[\'"]?([^\'"\n#]+)/m.exec(await readFile(path.join(source, "plugin.yaml"), "utf8"))?.[1]?.trim()
assert.ok(expectedVersion)
// The host test below invokes validate_plugin_dir when the host provides it,
// then always exercises the real loader and message flow. Native source install
// exists in Hermes 0.21.0 before the separate `plugins validate` CLI command.
const hostTest = path.join(path.dirname(fileURLToPath(import.meta.url)), "check-hermes-host.py")
console.log(run(pythonBin, [hostTest, installed], 60_000))

const listener = net.createServer()
listener.listen(0, "127.0.0.1")
await once(listener, "listening")
const port = listener.address().port
await new Promise((resolve, reject) => listener.close((error) => error ? reject(error) : resolve()))
const sidecarToken = "offline-sidecar-token"
const child = spawn(process.execPath, [path.join(installed, "sidecar/index.mjs")], {
  cwd: scratch, env: {
    ...env, INLINE_SIDECAR_TOKEN: sidecarToken, INLINE_SIDECAR_PORT: String(port),
    INLINE_SIDECAR_BIND: "127.0.0.1", INLINE_STATE_PATH: path.join(scratch, "state.json"),
    INLINE_SIDECAR_TEST_MOCK: "1", INLINE_SIDECAR_TEST_ALLOW_MOCK: "1",
  }, stdio: ["ignore", "pipe", "pipe"],
})
const exited = once(child, "exit")
let output = ""
child.stdout.on("data", (chunk) => { output += chunk })
child.stderr.on("data", (chunk) => { output += chunk })
const post = (endpoint, body = {}, authenticated = true) => fetch(`http://127.0.0.1:${port}${endpoint}`, {
  method: "POST", headers: { "content-type": "application/json", ...(authenticated ? { "x-hermes-sidecar-token": sidecarToken } : {}) },
  body: JSON.stringify(body), signal: AbortSignal.timeout(2_000),
})
try {
  const deadline = Date.now() + 10_000
  let connected = false
  let health
  while (Date.now() < deadline) {
    assert.equal(child.exitCode, null, output)
    try { health = await (await post("/healthz")).json(); connected = health.result?.connected === true } catch {}
    if (connected) break
    await new Promise((resolve) => setTimeout(resolve, 100))
  }
  assert.ok(connected, `installed source sidecar did not connect to offline mock: ${output}`)
  assert.equal(health.result.version, expectedVersion, "source sidecar lost plugin version metadata")
  assert.equal((await post("/healthz", {}, false)).status, 401)
  assert.equal((await post("/inbound/ack", { deliveryId: "offline-receipt" }, false)).status, 401)
  // ACK retries are harmless even after the original receipt has been retired.
  for (let attempt = 0; attempt < 2; attempt++) {
    assert.equal((await post("/inbound/ack", { deliveryId: "offline-receipt" })).status, 200)
  }
  const sent = await (await post("/send", { target: { chatId: "123" }, text: "source catalog smoke", parseMarkdown: false })).json()
  assert.equal(sent.ok, true)
  assert.ok(sent.result.messageId)
  await post("/shutdown")
} finally {
  child.kill("SIGTERM")
  await exited
}
console.log(`Native source admission + installed bundled sidecar offline smoke passed: ${identifier} @ ${revision}`)
console.log(`Isolated Hermes home: ${home}`)
