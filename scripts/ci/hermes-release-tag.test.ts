import { afterEach, beforeEach, describe, expect, it } from "bun:test"
import { createHash } from "node:crypto"
import { chmod, cp, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
import os from "node:os"
import path from "node:path"

const root = path.resolve(import.meta.dir, "../..")
const sha = "a".repeat(40)
const version = "0.0.23-alpha.1"
const tag = `hermes-agent-v${version}`
const releaseArgs = ["--version", version, "--tag", tag, "--sha", sha]
const runner = String.raw`#!/usr/bin/env node
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const { execFileSync } = require('node:child_process')
const { createHash } = require('node:crypto')
const program = path.basename(process.argv[1])
const args = process.argv.slice(2)
if (program === 'git') {
  assert.equal(args[0], 'ls-files')
  process.exit(0)
}
const publishing = program === 'npm' && args[0] === 'publish'
const manifest = publishing ? {} : JSON.parse(fs.readFileSync('package.json', 'utf8'))
const plugin = publishing ? '' : fs.readFileSync('plugin/inline/plugin.yaml', 'utf8')
const probe = publishing ? '' : fs.readFileSync('plugin/inline/cli.py', 'utf8')
fs.appendFileSync(process.env.HERMES_STAGE_CALLS, JSON.stringify({ program, args, manifest, plugin, probe }) + '\n')
if (program === 'npm' && args[0] === 'install') {
  assert.equal(manifest.version, '1.0.0')
  assert(args.includes('--ignore-scripts'))
  if (manifest.dependencies['@inline-chat/realtime-sdk'].startsWith('file:')) {
    for (const [name, version] of [['realtime-sdk', '0.0.18'], ['protocol', '0.0.15']]) {
      const target = path.join('node_modules', '@inline-chat', name)
      fs.mkdirSync(target, { recursive: true })
      fs.writeFileSync(path.join(target, 'package.json'), JSON.stringify({ version }))
    }
  }
} else if (program === 'bun') {
  assert.equal(args[0], 'run')
  if (args[1] === 'check') {
    assert.equal(manifest.version, '1.0.0', 'source contracts must precede stamping')
    assert(plugin.includes('version: 1.0.0\n'))
    assert(probe.includes('inline-hermes-agent-adapter/1.0.0'))
    assert.equal(fs.readFileSync('README.md', 'utf8'), 'source version 1.0.0')
    assert(!manifest.dependencies['@inline-chat/realtime-sdk'].startsWith('file:'))
    if (process.env.HERMES_STAGE_FAIL_CHECK) process.exit(12)
  } else {
    assert.equal(args[1], 'build')
    assert.equal(manifest.version, '0.0.23-alpha.1')
    assert.equal(manifest.gitHead, 'a'.repeat(40))
    assert.deepEqual(manifest.inlineRelease, { tag: 'hermes-agent-v0.0.23-alpha.1', sha: 'a'.repeat(40) })
    assert(plugin.includes('version: ' + manifest.version + '\n'))
    assert(probe.includes('inline-hermes-agent-adapter/' + manifest.version))
  }
  fs.mkdirSync('dist', { recursive: true })
  fs.writeFileSync('dist/install.js', 'runtime-version=' + manifest.version)
  fs.mkdirSync('plugin/inline/sidecar', { recursive: true })
  fs.writeFileSync('plugin/inline/sidecar/index.mjs', process.env.HERMES_STAGE_BAD_BUNDLE ? 'different' : 'source-bundle')
} else if (program === 'npm' && args[0] === 'pack') {
  assert(args.includes('--ignore-scripts'))
  const output = args[args.indexOf('--pack-destination') + 1]
  const filename = 'hermes-fixture.tgz'
  execFileSync('tar', ['-czf', path.join(output, filename), 'package.json', 'plugin', 'dist'])
  const integrity = 'sha512-' + createHash('sha512').update(fs.readFileSync(path.join(output, filename))).digest('base64')
  console.log(JSON.stringify([{ name: manifest.name, version: manifest.version, filename, files: [],
    integrity: process.env.HERMES_STAGE_BAD_INTEGRITY ? 'sha512-wrong' : integrity }]))
} else if (program === 'npm' && args[0] === 'publish') {
  assert(args.includes('--dry-run'), 'fixtures must never publish')
  const channel = args.indexOf('--tag')
  if (channel >= 0) assert.equal(args[channel + 1], 'alpha')
} else { throw new Error('Unexpected command: ' + program + ' ' + args.join(' ')) }
`

describe("Hermes tag release staging", () => {
  let directory: string
  let packageRoot: string
  let script: string
  let outputDir: string
  let calls: string
  let bin: string

  beforeEach(async () => {
    directory = await mkdtemp(path.join(os.tmpdir(), "inline-hermes-tag-test-"))
    packageRoot = path.join(directory, "source/plugins/hermes-agent")
    script = path.join(packageRoot, "scripts/release-stage.mjs")
    outputDir = path.join(directory, "artifacts")
    calls = path.join(directory, "calls.jsonl")
    bin = path.join(directory, "bin")
    for (const folder of ["scripts", "src", "tests", "plugin/inline/sidecar"]) {
      await mkdir(path.join(packageRoot, folder), { recursive: true })
    }
    await mkdir(path.join(directory, "source/scripts/ci"), { recursive: true })
    await cp(path.join(root, "plugins/hermes-agent/scripts/release-stage.mjs"), script)
    await cp(path.join(root, "scripts/ci/release-tag.mjs"), path.join(directory, "source/scripts/ci/release-tag.mjs"))
    for (const name of ["LICENSE", "RELEASE.md", "tsconfig.json", "vitest.config.ts"]) {
      await writeFile(path.join(packageRoot, name), "fixture")
    }
    await writeFile(path.join(packageRoot, "README.md"), "source version 1.0.0")
    await writeFile(path.join(directory, "source/.oxlintignore"), "")
    await writeFile(path.join(packageRoot, "package.json"), JSON.stringify({
      name: "@inline-chat/hermes-agent-adapter", version: "1.0.0", type: "module",
      dependencies: { "@inline-chat/realtime-sdk": "0.0.18", yaml: "2.9.0" },
    }))
    await mkdir(path.join(directory, "source/packages/protocol"), { recursive: true })
    await writeFile(path.join(directory, "source/packages/protocol/package.json"), '{"version":"0.0.15"}')
    await writeFile(path.join(packageRoot, "plugin/inline/plugin.yaml"), "name: inline-platform\nversion: 1.0.0\n")
    await writeFile(path.join(packageRoot, "plugin/inline/cli.py"), '_PROBE_USER_AGENT = "inline-hermes-agent-adapter/1.0.0"\n')
    await writeFile(path.join(packageRoot, "plugin/inline/sidecar/index.mjs"), "source-bundle")
    await mkdir(bin)
    for (const name of ["npm", "bun", "git"]) {
      await writeFile(path.join(bin, name), runner)
      await chmod(path.join(bin, name), 0o700)
    }
  })

  afterEach(async () => { await rm(directory, { recursive: true, force: true }) })

  function stage(args: string[], environment: Record<string, string> = {}) {
    const result = Bun.spawnSync(["node", script, "--output-dir", outputDir, ...args], { env: {
      ...process.env, PATH: `${bin}:${process.env.PATH}`, HERMES_STAGE_CALLS: calls,
      TMPDIR: directory, GITHUB_OUTPUT: path.join(directory, "outputs"), ...environment,
    } })
    return { code: result.exitCode, error: result.stderr.toString() }
  }

  async function operations() {
    return (await readFile(calls, "utf8")).trim().split("\n").map((line) => JSON.parse(line))
  }

  it("checks original source before stamping and packs the release identity without changing source or dependencies", async () => {
    const sourceFiles = ["package.json", "README.md", "plugin/inline/plugin.yaml", "plugin/inline/cli.py", "plugin/inline/sidecar/index.mjs"]
    const before = await Promise.all(sourceFiles.map((name) => readFile(path.join(packageRoot, name), "utf8")))
    const result = stage(["--dry-run", "--verify-source-bundle", ...releaseArgs])
    expect(result.code, result.error).toBe(0)
    expect(await Promise.all(sourceFiles.map((name) => readFile(path.join(packageRoot, name), "utf8")))).toEqual(before)
    const recorded = await operations()
    expect(recorded.map(({ program, args }) => `${program} ${args.slice(0, 2).join(" ")}`)).toEqual([
      "npm install --ignore-scripts", "bun run check", "bun run build", "npm pack --ignore-scripts", "npm publish --dry-run",
    ])
    expect(recorded[3].manifest.dependencies).toEqual(recorded[0].manifest.dependencies)
    const receipt = JSON.parse(await readFile(path.join(outputDir, "release-artifact.json"), "utf8"))
    const artifact = path.join(outputDir, receipt.file)
    const bytes = await readFile(artifact)
    expect(receipt).toEqual({ name: "@inline-chat/hermes-agent-adapter", version, tag, sha, file: "hermes-fixture.tgz",
      integrity: `sha512-${createHash("sha512").update(bytes).digest("base64")}`,
      sha256: createHash("sha256").update(bytes).digest("hex") })
    const packed = Bun.spawnSync(["tar", "-xOzf", artifact, "package.json"])
    expect(JSON.parse(packed.stdout.toString())).toMatchObject({ version, gitHead: sha, inlineRelease: { tag, sha } })
    expect(Bun.spawnSync(["tar", "-xOzf", artifact, "dist/install.js"]).stdout.toString()).toBe(`runtime-version=${version}`)
    expect(await readFile(path.join(directory, "outputs"), "utf8")).toBe(`artifact=${artifact}\nartifact-sha256=${receipt.sha256}\nintegrity=${receipt.integrity}\n`)
  })

  it("preserves unstamped registry and candidate preparation", async () => {
    for (const candidate of [false, true]) {
      await rm(calls, { force: true })
      await rm(outputDir, { recursive: true, force: true })
      const args = candidate
        ? ["--candidate-sdk-tarball", "/fixture/sdk.tgz", "--candidate-protocol-tarball", "/fixture/protocol.tgz"]
        : ["--verify-source-bundle"]
      const result = stage(["--prepare-only", ...args])
      expect(result.code, result.error).toBe(0)
      const recorded = await operations()
      expect(recorded.map(({ program, args }) => `${program} ${args[0]}`)).toEqual(["npm install", "bun run", "npm pack"])
      expect(recorded[2].manifest).toMatchObject({ version: "1.0.0", dependencies: { "@inline-chat/realtime-sdk": "0.0.18", yaml: "2.9.0" } })
      expect(recorded[2].manifest.gitHead).toBeUndefined()
      expect(await Bun.file(path.join(outputDir, "release-artifact.json")).exists()).toBe(false)
    }
  })

  it("rejects partial, mismatched, malformed and duplicate release identities before installing", async () => {
    for (const args of [
      ["--version", version], ["--tag", tag, "--sha", sha],
      ["--version", "0.0.24", "--tag", tag, "--sha", sha],
      ["--version", version, "--tag", `openclaw-v${version}`, "--sha", sha],
      ["--version", version, "--tag", tag, "--sha", "short"],
      ["--version", "0.0.23-alpha.01", "--tag", "hermes-agent-v0.0.23-alpha.01", "--sha", sha],
      [...releaseArgs, "--version", version], ["--version"],
    ]) expect(stage(args).code).not.toBe(0)
    expect(await Bun.file(calls).exists()).toBe(false)
  })

  it("fails before stamping/packing when original source checks or bundle comparison fail", async () => {
    const environments: Array<Record<string, string>> = [{ HERMES_STAGE_FAIL_CHECK: "1" }, { HERMES_STAGE_BAD_BUNDLE: "1" }]
    for (const environment of environments) {
      await rm(calls, { force: true })
      expect(stage(["--prepare-only", "--verify-source-bundle", ...releaseArgs], environment).code).not.toBe(0)
      expect((await operations()).map(({ program, args }) => `${program} ${args[0]}`)).toEqual(["npm install", "bun run"])
      expect(await Bun.file(path.join(outputDir, "release-artifact.json")).exists()).toBe(false)
    }
  })

  it("does not issue a release receipt for corrupt packed integrity", async () => {
    const result = stage(["--prepare-only", "--verify-source-bundle", ...releaseArgs], { HERMES_STAGE_BAD_INTEGRITY: "1" })
    expect(result.code).not.toBe(0)
    expect(result.error).toContain("integrity does not match")
    expect(await Bun.file(path.join(outputDir, "release-artifact.json")).exists()).toBe(false)
  })
})
