import assert from "node:assert/strict"
import { execFileSync } from "node:child_process"
import { randomUUID } from "node:crypto"
import { mkdtemp, readFile, writeFile } from "node:fs/promises"
import { createRequire } from "node:module"
import os from "node:os"
import path from "node:path"
import { fileURLToPath } from "node:url"
import { assertLocalTestDatabaseUrl, prepareTestDatabaseTemplate } from "../../server/scripts/test-database-template.ts"

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..")
const serverRoot = path.join(repoRoot, "server")
const postgresModule = createRequire(path.join(serverRoot, "package.json"))("postgres")
const postgres = postgresModule.default ?? postgresModule
const artifactDir = path.resolve(process.argv[2] ?? "")
if (!process.argv[2]) throw new Error("usage: local-bot-flow.mjs ARTIFACT_DIR")
const provisioningUrl = process.env.TEST_DATABASE_URL
if (!provisioningUrl) throw new Error("TEST_DATABASE_URL is required")
assertLocalTestDatabaseUrl(provisioningUrl)
const template = await prepareTestDatabaseTemplate(provisioningUrl)
const databaseName = `test_db_${template.name.slice(-32)}_${randomUUID().replaceAll("-", "").slice(0, 12)}`
const databaseUrl = new URL(provisioningUrl)
databaseUrl.pathname = `/${databaseName}`
const adminUrl = new URL(provisioningUrl)
adminUrl.pathname = "/postgres"
const admin = postgres(adminUrl.toString(), { max: 1, connect_timeout: 5, onnotice: () => {} })
let child
let output = ""
let closeDb
const withTimeout = async (promise, milliseconds, message) => {
  let timer
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(message)), milliseconds) }),
    ])
  } finally {
    clearTimeout(timer)
  }
}
const stopServer = async () => {
  if (!child || child.exitCode !== null) return
  child.kill("SIGTERM")
  try {
    await withTimeout(child.exited, 10_000, "server shutdown timed out")
  } catch {
    child.kill("SIGKILL")
    await child.exited
  }
}
try {
  await admin.unsafe(`CREATE DATABASE "${databaseName}" TEMPLATE "${template.name}"`)
  process.env.DATABASE_URL = databaseUrl.toString()
  process.env.TEST_DATABASE_URL = databaseUrl.toString()
  process.env.ENCRYPTION_KEY = "0".repeat(64)
  const { makeCoreProductionSmokeEnvironment } = await import("../../server/scripts/core-production-smoke.ts")
  const environment = makeCoreProductionSmokeEnvironment(process.env, false)
  Object.assign(process.env, environment)

  const database = await import("../../server/src/db/index.ts")
  closeDb = database.closeDb
  const { db } = database
  const { users } = await import("../../server/src/db/schema/users.ts")
  const { generateToken, hashToken } = await import("../../server/src/utils/auth.ts")
  const { SessionsModel } = await import("../../server/src/db/models/sessions.ts")
  const [bot, human] = await db.insert(users).values([
    { firstName: "CI Bot", username: `ci_bot_${process.pid}`, bot: true, emailVerified: false, phoneVerified: false, pendingSetup: false },
    { firstName: "CI Human", username: `ci_human_${process.pid}`, bot: false, emailVerified: false, phoneVerified: false, pendingSetup: false },
  ]).returning()
  assert.ok(bot && human)
  const { token } = await generateToken(bot.id)
  await SessionsModel.create({ userId: bot.id, tokenHash: hashToken(token), personalData: {}, clientType: "api" })

  let ready
  const readyPromise = new Promise((resolve) => { ready = resolve })
  child = Bun.spawn({
    cmd: [process.execPath, "--no-env-file", "src/index.ts"], cwd: serverRoot, env: environment,
    stdout: "pipe", stderr: "pipe", stdin: "ignore",
  })
  const drain = async (stream, inspectReady) => {
    for await (const part of stream) {
      output = (output + new TextDecoder().decode(part)).slice(-8_000)
      if (inspectReady) {
        const match = output.match(/SERVER_READY ([0-9]+)/)
        if (match) ready(Number(match[1]))
      }
    }
  }
  const stdout = drain(child.stdout, true)
  const stderr = drain(child.stderr, false)
  const port = await withTimeout(Promise.race([
    readyPromise,
    child.exited.then((code) => { throw new Error(`server exited before readiness (${code})`) }),
  ]), 30_000, "server readiness timed out")
  const baseUrl = `http://127.0.0.1:${port}`
  const health = await fetch(`${baseUrl}/readyz`, { signal: AbortSignal.timeout(10_000) })
  assert.equal(health.status, 200, `server readiness ${health.status}`)

  const manifest = JSON.parse(await readFile(path.join(artifactDir, "manifest.json"), "utf8"))
  const names = ["@inline-chat/protocol", "@inline-chat/bot-api-types", "@inline-chat/bot-client", "@inline-chat/realtime-sdk", "@inline-chat/chat-sdk"]
  const dependencies = { chat: "4.40.0" }
  for (const name of names) {
    const pkg = manifest.packages.find((entry) => entry.name === name)
    assert.ok(pkg, `missing ${name} candidate`)
    dependencies[name] = `file:${path.join(artifactDir, pkg.file)}`
  }
  const consumer = await mkdtemp(path.join(os.tmpdir(), "inline-local-bot-flow-"))
  await writeFile(path.join(consumer, "package.json"), JSON.stringify({ type: "module", private: true, dependencies }))
  execFileSync("npm", ["install", "--ignore-scripts", "--legacy-peer-deps", "--no-audit", "--no-fund"], {
    cwd: consumer, stdio: "inherit", timeout: 180_000,
  })
  const flow = path.join(consumer, "flow.mjs")
  await writeFile(flow, `
import assert from 'node:assert/strict'
import { InlineBotClient } from '@inline-chat/bot-client'
import { InlineSdkClient } from '@inline-chat/realtime-sdk'
import { InlineAdapter } from '@inline-chat/chat-sdk'
const bot = new InlineBotClient({ token: process.env.INLINE_E2E_TOKEN, baseUrl: process.env.INLINE_E2E_BASE_URL })
const me = await bot.getMe()
assert.equal(me.ok, true)
assert.equal(me.result.user.is_bot, true)
const target = { user_id: Number(process.env.INLINE_E2E_HUMAN_ID) }
const chat = await bot.getChat(target)
assert.equal(chat.ok, true)
const sent = await bot.sendMessage({ ...target, text: 'ci-packed-bot-round-trip' })
assert.equal(sent.ok, true)
assert.ok(sent.result.message.message_id > 0)
const history = await bot.getMessages({ chat_id: chat.result.chat.chat_id, message_ids: [sent.result.message.message_id] })
assert.equal(history.ok, true)
assert.equal(history.result.messages[0].message_id, sent.result.message.message_id)
const adapter = new InlineAdapter({ token: process.env.INLINE_E2E_TOKEN, webhookSecret: 'ci-secret', baseUrl: process.env.INLINE_E2E_BASE_URL })
await adapter.initialize({ getUserName: () => 'ci-bot' })
assert.equal(adapter.botUserId, String(me.result.user.id))
const sdk = new InlineSdkClient({ token: process.env.INLINE_E2E_TOKEN, baseUrl: process.env.INLINE_E2E_BASE_URL })
try {
  await sdk.connect()
  const sdkMe = await sdk.getMe()
  assert.equal(sdkMe.userId, BigInt(me.result.user.id))
} finally { await sdk.close() }
console.log('Packed Bot Client, Chat SDK adapter, and realtime SDK reached the local Inline server')
`)
  execFileSync("bun", ["--no-env-file", flow], {
    cwd: consumer, stdio: "inherit", timeout: 60_000,
    env: { ...process.env, INLINE_E2E_BASE_URL: baseUrl, INLINE_E2E_TOKEN: token, INLINE_E2E_HUMAN_ID: String(human.id) },
  })
  await closeDb()
  closeDb = undefined
  await stopServer()
  await Promise.allSettled([stdout, stderr])
  console.log(`Local server round trip passed for ${manifest.sourceSha}`)
} catch (error) {
  if (child) console.error(`Server output (last 8 KB): ${output}`)
  console.error(error)
  throw error
} finally {
  await stopServer()
  await closeDb?.()
  try {
    await template.dispose()
  } finally {
    await admin.end({ timeout: 5 })
  }
}
