import { afterEach, beforeEach, describe, expect, it } from "bun:test"
import { createHash } from "node:crypto"
import { chmod, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { pathToFileURL } from "node:url"
import { parseStageArgs } from "./stage-npm-release.mjs"

const helper = pathToFileURL(path.resolve(import.meta.dir, "stage-npm-release.mjs")).href
const sha = "a".repeat(40)
const npm = String.raw`#!/usr/bin/env node
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const os = require('node:os')
const { execFileSync } = require('node:child_process')
const { createHash } = require('node:crypto')
const args = process.argv.slice(2)
const cwd = process.cwd()
const manifest = JSON.parse(fs.readFileSync('package.json', 'utf8'))
fs.appendFileSync(process.env.STAGE_TEST_CALLS, JSON.stringify({ args, manifest }) + '\n')
if (args[0] === 'install') {
  assert(args.includes('--ignore-scripts'))
  assert(args.includes('--registry=https://registry.npmjs.org'))
  for (const name of ['.env', '.env.production', '.npmrc', 'node_modules', 'dist', 'bun.lock', 'package-lock.json', 'tsconfig.tsbuildinfo', 'src/.env.test']) {
    assert(!fs.existsSync(name), name + ' must not be copied')
  }
  assert(!fs.existsSync(path.join(cwd, '..', 'package.json')), 'must be outside the source workspace')
  assert(!manifest.overrides && !manifest.workspaces)
  assert.equal(manifest.version, '0.0.72', 'install before stamping the disposable manifest')
  assert.equal(manifest.devDependencies.typescript, '5.8.3')
  const registry = JSON.parse(fs.readFileSync(process.env.STAGE_TEST_REGISTRY, 'utf8'))
  for (const [name, version] of Object.entries(manifest.dependencies)) {
    const published = registry[name + '@' + version]
    if (!published) { console.error('E404 missing declared registry dependency: ' + name + '@' + version); process.exit(17) }
    const target = path.join(cwd, 'node_modules', name)
    fs.mkdirSync(target, { recursive: true })
    fs.writeFileSync(path.join(target, 'package.json'), JSON.stringify({ name, version, main: 'index.js' }))
    fs.writeFileSync(path.join(target, 'index.js'), published)
  }
} else if (args[0] === 'run') {
  assert.equal(manifest.name, '@inline-openclaw/inline')
  assert(args.includes('--ignore-scripts'))
  assert(manifest.scripts.build.includes('--packages=bundle'))
  execFileSync('bun', ['run', 'build'], { stdio: 'inherit' })
} else if (args[0] === 'exec') {
  assert.equal(manifest.name, '@inline-chat/bot-client')
  assert.deepEqual(args, ['exec', '--offline', '--ignore-scripts', '--', 'tsc', '-p', 'tsconfig.json'])
  execFileSync('bun', ['compile'], { stdio: 'inherit' })
} else if (args[0] === 'pack') {
  assert(args.includes('--ignore-scripts'))
  const output = args[args.indexOf('--pack-destination') + 1]
  const filename = 'release-fixture.tgz'
  const packedRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'inline-stage-pack-fixture-'))
  try {
    fs.mkdirSync(path.join(packedRoot, 'package'))
    for (const name of ['package.json', 'dist']) fs.cpSync(name, path.join(packedRoot, 'package', name), { recursive: true })
    execFileSync('tar', ['-czf', path.join(output, filename), '-C', packedRoot, 'package'])
  } finally { fs.rmSync(packedRoot, { recursive: true, force: true }) }
  const bytes = fs.readFileSync(path.join(output, filename))
  const integrity = 'sha512-' + createHash('sha512').update(bytes).digest('base64')
  console.log(JSON.stringify([{ name: manifest.name, version: manifest.version, filename,
    integrity: process.env.STAGE_TEST_BAD_INTEGRITY ? 'sha512-wrong' : integrity }]))
} else { throw new Error('Unexpected npm operation: ' + args.join(' ')) }
`
const bun = String.raw`#!/usr/bin/env node
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const manifest = JSON.parse(fs.readFileSync('package.json', 'utf8'))
assert.equal(manifest.version, '0.0.73-alpha.1')
assert.equal(manifest.gitHead, 'a'.repeat(40))
assert.deepEqual(manifest.inlineRelease, { tag: process.env.STAGE_TEST_TAG, sha: 'a'.repeat(40) })
const source = fs.readFileSync(path.join('node_modules', '@inline-chat/realtime-sdk', 'index.js'), 'utf8')
assert.equal(source, 'published-sdk-code')
fs.mkdirSync('dist', { recursive: true })
fs.writeFileSync('dist/index.js', source)
`

describe("isolated npm release staging", () => {
  let directory: string
  let repoRoot: string
  let packageRoot: string
  let outputDir: string
  let bin: string
  let calls: string
  let registry: string
  let manifest: Record<string, unknown>

  beforeEach(async () => {
    directory = await mkdtemp(path.join(os.tmpdir(), "inline-stage-release-test-"))
    repoRoot = path.join(directory, "source")
    packageRoot = path.join(repoRoot, "plugins/openclaw")
    outputDir = path.join(directory, "artifacts")
    bin = path.join(directory, "bin")
    calls = path.join(directory, "calls.jsonl")
    registry = path.join(directory, "registry.json")
    await mkdir(packageRoot, { recursive: true })
    await mkdir(path.join(packageRoot, "src"))
    await mkdir(path.join(packageRoot, "dist"))
    await mkdir(path.join(packageRoot, "node_modules"))
    await mkdir(bin)
    await writeFile(path.join(repoRoot, "package.json"), JSON.stringify({ private: true,
      workspaces: ["packages/*", "plugins/*"], catalog: { typescript: "5.8.3" },
      overrides: { "@inline-chat/realtime-sdk": "workspace:*" } }))
    const workspaceSdk = path.join(repoRoot, "packages/sdk")
    await mkdir(workspaceSdk, { recursive: true })
    await writeFile(path.join(workspaceSdk, "index.js"), "unpublished-workspace-code")
    manifest = { name: "@inline-openclaw/inline", version: "0.0.72", type: "module",
      dependencies: { "@inline-chat/realtime-sdk": "0.0.19" },
      peerDependencies: { openclaw: ">=2026.8.2" }, peerDependenciesMeta: { openclaw: { optional: true } },
      devDependencies: { typescript: "catalog:" },
      scripts: { build: "bun build ./src/index.ts --outdir dist --packages=bundle" }, files: ["dist"] }
    await writeFile(path.join(packageRoot, "package.json"), JSON.stringify(manifest))
    await writeFile(path.join(packageRoot, "src/index.ts"), "export * from '@inline-chat/realtime-sdk'")
    for (const file of [".env", ".env.production", ".npmrc", "bun.lock", "package-lock.json", "tsconfig.tsbuildinfo", "src/.env.test", "dist/index.js"]) {
      await writeFile(path.join(packageRoot, file), "synthetic fixture; must not be copied")
    }
    await writeFile(registry, JSON.stringify({ "@inline-chat/realtime-sdk@0.0.19": "published-sdk-code" }))
    await writeFile(path.join(bin, "npm"), npm)
    await writeFile(path.join(bin, "bun"), bun)
    await chmod(path.join(bin, "npm"), 0o700)
    await chmod(path.join(bin, "bun"), 0o700)
  })

  afterEach(async () => { await rm(directory, { recursive: true, force: true }) })

  function stage(overrides: Record<string, unknown> = {}, environment: Record<string, string> = {}) {
    const options = { packageKey: "openclaw", version: "0.0.73-alpha.1", tag: "openclaw-v0.0.73-alpha.1", sha, outputDir, ...overrides }
    const script = `import { stageNpmRelease } from ${JSON.stringify(helper)}; await stageNpmRelease(${JSON.stringify(options)}, ${JSON.stringify({ repoRoot })})`
    const result = Bun.spawnSync(["node", "--input-type=module", "--eval", script], { cwd: directory, env: {
      ...process.env, PATH: `${bin}:${process.env.PATH}`, STAGE_TEST_CALLS: calls, STAGE_TEST_REGISTRY: registry,
      STAGE_TEST_TAG: String(options.tag), GITHUB_OUTPUT: path.join(directory, "outputs"), ...environment,
    } })
    return { code: result.exitCode, error: result.stderr.toString(), output: result.stdout.toString() }
  }

  it("rebuilds against declared published dependencies and stamps only the packed copy", async () => {
    const before = await readFile(path.join(packageRoot, "package.json"), "utf8")
    const result = stage()
    expect(result.code, result.error).toBe(0)
    expect(await readFile(path.join(packageRoot, "package.json"), "utf8")).toBe(before)
    const receipt = JSON.parse(await readFile(path.join(outputDir, "release-artifact.json"), "utf8"))
    const artifact = path.join(outputDir, receipt.file)
    const packed = Bun.spawnSync(["tar", "-xOzf", artifact, "package/package.json"])
    const staged = JSON.parse(packed.stdout.toString())
    expect(staged).toMatchObject({ name: manifest.name, version: "0.0.73-alpha.1", gitHead: sha,
      inlineRelease: { tag: "openclaw-v0.0.73-alpha.1", sha }, dependencies: manifest.dependencies,
      peerDependencies: manifest.peerDependencies, peerDependenciesMeta: manifest.peerDependenciesMeta,
      devDependencies: { typescript: "5.8.3" } })
    expect(staged.overrides).toBeUndefined()
    const bundled = Bun.spawnSync(["tar", "-xOzf", artifact, "package/dist/index.js"])
    expect(bundled.stdout.toString()).toBe("published-sdk-code")
    const bytes = await readFile(artifact)
    expect(receipt).toEqual({ name: manifest.name, version: "0.0.73-alpha.1", tag: "openclaw-v0.0.73-alpha.1", sha,
      file: "release-fixture.tgz", sha256: createHash("sha256").update(bytes).digest("hex"),
      integrity: `sha512-${createHash("sha512").update(bytes).digest("base64")}` })
    expect(await readFile(path.join(directory, "outputs"), "utf8")).toContain(`artifact=${artifact}\nartifact-sha256=${receipt.sha256}\nintegrity=${receipt.integrity}\n`)
    const operations = (await readFile(calls, "utf8")).trim().split("\n").map((line) => JSON.parse(line))
    expect(operations.map((call) => call.args[0])).toEqual(["install", "run", "pack"])
    expect(operations[0].manifest.version).toBe("0.0.72")
  })

  it("fails on a missing declared dependency despite a same-named workspace override", async () => {
    await writeFile(registry, "{}")
    const result = stage()
    expect(result.code).not.toBe(0)
    expect(result.error).toContain("missing declared registry dependency: @inline-chat/realtime-sdk@0.0.19")
    expect(await Bun.file(path.join(outputDir, "release-artifact.json")).exists()).toBe(false)
    expect(JSON.parse(await readFile(path.join(packageRoot, "package.json"), "utf8")).version).toBe("0.0.72")
    expect((await readFile(calls, "utf8")).trim().split("\n")).toHaveLength(1)
  })

  it("compiles bot-client without rebuilding its workspace sibling", async () => {
    const botRoot = path.join(repoRoot, "packages/bot-client")
    await mkdir(path.dirname(botRoot), { recursive: true })
    await mkdir(botRoot)
    manifest = { ...manifest, name: "@inline-chat/bot-client", scripts: { build: "bun run --cwd ../bot-api-types build && tsc -p tsconfig.json" } }
    await writeFile(path.join(botRoot, "package.json"), JSON.stringify(manifest))
    const result = stage({ packageKey: "bot-client", tag: "bot-client-v0.0.73-alpha.1" })
    expect(result.code, result.error).toBe(0)
    const operations = (await readFile(calls, "utf8")).trim().split("\n").map((line) => JSON.parse(line))
    expect(operations.map((call) => call.args[0])).toEqual(["install", "exec", "pack"])
  })

  it("rejects inconsistent release identities and the special Hermes path before installing", async () => {
    for (const overrides of [{ packageKey: "unknown" }, { version: "0.0.74" }, { sha: "short" },
      { tag: "cli-v0.0.73-alpha.1" }, { packageKey: "hermes-agent", tag: "hermes-agent-v0.0.73-alpha.1" }]) {
      expect(stage(overrides).code).not.toBe(0)
    }
    expect(await Bun.file(calls).exists()).toBe(false)
  })

  it("refuses catalog or local runtime dependencies and package-local overrides", async () => {
    for (const extra of [
      { dependencies: { "@inline-chat/realtime-sdk": "workspace:*" } },
      { dependencies: { "@inline-chat/realtime-sdk": "file:../../packages/sdk" } },
      { dependencies: { "@inline-chat/realtime-sdk": "catalog:" } },
      { overrides: { "@inline-chat/realtime-sdk": "0.0.20" } },
      { devDependencies: { unknown: "catalog:" } },
    ]) {
      await writeFile(path.join(packageRoot, "package.json"), JSON.stringify({ ...manifest, ...extra }))
      expect(stage().code).not.toBe(0)
    }
    expect(await Bun.file(calls).exists()).toBe(false)
  })

  it("rejects source symlinks that could reach workspace code", async () => {
    await symlink(path.join(repoRoot, "packages/sdk/index.js"), path.join(packageRoot, "src/linked.js"))
    const result = stage()
    expect(result.code).not.toBe(0)
    expect(result.error).toContain("must not link outside the staged package")
    expect(await Bun.file(calls).exists()).toBe(false)
  })

  it("does not issue a receipt when packed bytes disagree with npm's integrity", async () => {
    const result = stage({}, { STAGE_TEST_BAD_INTEGRITY: "1" })
    expect(result.code).not.toBe(0)
    expect(result.error).toContain("Packed artifact integrity does not match its bytes")
    expect(await Bun.file(path.join(outputDir, "release-artifact.json")).exists()).toBe(false)
  })
})

it("requires every staging argument exactly once", () => {
  expect(parseStageArgs(["--package", "openclaw", "--version", "1.2.3", "--tag", "openclaw-v1.2.3", "--sha", sha, "--output-dir", "/tmp/output"]))
    .toEqual({ packageKey: "openclaw", version: "1.2.3", tag: "openclaw-v1.2.3", sha, outputDir: "/tmp/output" })
  for (const args of [[], ["--package", "openclaw"], ["--unknown", "value"], ["--package", "--version"], ["--package", "openclaw", "--package", "openclaw"]]) {
    expect(() => parseStageArgs(args)).toThrow()
  }
})
