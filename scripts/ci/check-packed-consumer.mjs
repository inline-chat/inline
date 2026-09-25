import assert from "node:assert/strict"
import { createHash } from "node:crypto"
import { execFileSync } from "node:child_process"
import { existsSync } from "node:fs"
import { mkdtemp, readFile, writeFile } from "node:fs/promises"
import os from "node:os"
import path from "node:path"

const artifactDir = path.resolve(process.argv[2] ?? "")
if (!process.argv[2]) throw new Error("usage: check-packed-consumer.mjs ARTIFACT_DIR")
const manifest = JSON.parse(await readFile(path.join(artifactDir, "manifest.json"), "utf8"))
assert.equal(manifest.packages.length, 7)
const expectedSha = process.env.GITHUB_SHA
if (expectedSha) assert.equal(manifest.sourceSha, expectedSha, "artifact must come from this source SHA")
const dependencies = { chat: "4.40.0" }
for (const pkg of manifest.packages) {
  const bytes = await readFile(path.join(artifactDir, pkg.file))
  assert.equal(createHash("sha256").update(bytes).digest("hex"), pkg.sha256, `${pkg.name} tarball hash`)
  dependencies[pkg.name] = `file:${path.join(artifactDir, pkg.file)}`
}

const consumer = await mkdtemp(path.join(os.tmpdir(), "inline-packed-consumer-"))
await writeFile(path.join(consumer, "package.json"), JSON.stringify({
  private: true, type: "module", dependencies,
}, null, 2))
execFileSync("npm", ["install", "--ignore-scripts", "--legacy-peer-deps", "--no-audit", "--no-fund"], {
  cwd: consumer, stdio: "inherit", timeout: 180_000,
})

for (const pkg of manifest.packages) {
  const installedRoot = path.join(consumer, "node_modules", pkg.name)
  const installed = JSON.parse(await readFile(path.join(installedRoot, "package.json"), "utf8"))
  assert.equal(installed.name, pkg.name)
  assert.equal(installed.version, pkg.version)
  for (const [entry, target] of Object.entries(installed.exports ?? {})) {
    const paths = typeof target === "string" ? [target] : Object.values(target)
    for (const relative of paths) {
      assert.equal(typeof relative, "string", true)
      assert.equal(relative.startsWith("./"), true, `${pkg.name} ${entry} is relative`)
      assert.equal(existsSync(path.join(installedRoot, relative)), true, `${pkg.name} ${entry} missing ${relative}`)
    }
  }
  console.log(`${pkg.name}@${pkg.version}: ${Object.keys(installed.exports ?? {}).length} exports found`)
}

const entry = path.join(consumer, "smoke.mjs")
await writeFile(entry, `
import assert from 'node:assert/strict'
import { InlineSdkClient } from '@inline-chat/realtime-sdk'
import { InlineBotClient } from '@inline-chat/bot-client'
import { BOT_ID_MAX } from '@inline-chat/bot-api-types'
import { InlineAdapter } from '@inline-chat/chat-sdk'
import * as protocol from '@inline-chat/protocol'
import * as hermes from '@inline-chat/hermes-agent-adapter'
assert.equal(typeof InlineSdkClient, 'function')
assert.equal(typeof InlineBotClient, 'function')
assert.equal(typeof InlineAdapter, 'function')
assert.equal(BOT_ID_MAX, 4_503_599_627_370_495)
assert.ok(Object.keys(protocol).length > 0)
assert.ok(Object.keys(hermes).length > 0)
const adapter = new InlineAdapter({ token: 'ci-local-token', webhookSecret: 'ci-local-secret' })
assert.equal(adapter.decodeThreadId(adapter.encodeThreadId({ kind: 'chat', id: '123' })).id, '123')
console.log('Packed Node consumer smoke passed')
`)
execFileSync("node", [entry], { cwd: consumer, stdio: "inherit", timeout: 30_000 })
execFileSync("bun", [entry], { cwd: consumer, stdio: "inherit", timeout: 30_000 })

const typesPath = path.join(consumer, "smoke.ts")
await writeFile(typesPath, `
import type { BotApiEnvelope } from '@inline-chat/bot-api-types'
import { InlineSdkClient } from '@inline-chat/realtime-sdk'
import { InlineBotClient } from '@inline-chat/bot-client'
import { InlineAdapter } from '@inline-chat/chat-sdk'
const envelope: BotApiEnvelope<number> = { ok: true, result: 1 }
const constructors: [typeof InlineSdkClient, typeof InlineBotClient, typeof InlineAdapter] = [InlineSdkClient, InlineBotClient, InlineAdapter]
void envelope; void constructors
`)
await writeFile(path.join(consumer, "tsconfig.json"), JSON.stringify({
  compilerOptions: { target: "ES2022", module: "NodeNext", moduleResolution: "NodeNext", strict: true, skipLibCheck: true, noEmit: true },
  files: ["smoke.ts"],
}))
const tsc = path.resolve(path.dirname(new URL(import.meta.url).pathname), "../../node_modules/.bin/tsc")
execFileSync(tsc, ["-p", path.join(consumer, "tsconfig.json")], { cwd: consumer, stdio: "inherit", timeout: 60_000 })
console.log(`Consumer: ${consumer}; Node ${process.version}; Bun and TypeScript passed`)
