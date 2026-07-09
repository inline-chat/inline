#!/usr/bin/env bun
import { spawn, spawnSync } from "node:child_process"
import { existsSync, mkdirSync, openSync, readFileSync, writeFileSync } from "node:fs"
import { dirname, resolve } from "node:path"

type SeedUser = {
  id: number
  email: string
  token: string
  sessionId: number
}

type SeedOutput = {
  bridgeUser: SeedUser
  peerUser: SeedUser
  secondPeerUser: SeedUser
  dmChatId: number
  groupChatId: number
  seededMessages: {
    dm: string
    group: string
  }
  loginCode: string
}

type RunState = {
  runId: string
  runRoot: string
  matrixRoot: string
  databaseUrl: string
  inlineServerUrl: string
  inlineRealtimeUrl: string
  seed: SeedOutput
  ports: {
    postgres: number
    inlineServer: number
    synapse: number
    bridge: number
    sidecar: number
  }
}

const ROOT = resolve(import.meta.dir, "..")
const BUN_BIN = process.execPath
const MATRIX_INLINE_ROOT = resolve(process.env.MATRIX_INLINE_ROOT ?? `${ROOT}/../matrix-inline`)
const WORK_ROOT = resolve(process.env.MATRIX_INLINE_REAL_E2E_ROOT ?? `${ROOT}/.tmp/matrix-inline-e2e`)
const STATE_FILE = resolve(WORK_ROOT, "current-state.json")
const COMPOSE_FILE = resolve(WORK_ROOT, "docker-compose.yml")
const PROJECT = process.env.MATRIX_INLINE_REAL_E2E_PROJECT ?? "inline-matrix-real-e2e"
const POSTGRES_PORT = Number(process.env.MATRIX_INLINE_REAL_E2E_POSTGRES_PORT ?? "15432")
const INLINE_SERVER_PORT = Number(process.env.MATRIX_INLINE_REAL_E2E_INLINE_PORT ?? "18080")
const SYNAPSE_PORT = Number(process.env.MATRIX_INLINE_REAL_E2E_SYNAPSE_PORT ?? "18088")
const BRIDGE_PORT = Number(process.env.MATRIX_INLINE_REAL_E2E_BRIDGE_PORT ?? "29353")
const SIDECAR_PORT = Number(process.env.MATRIX_INLINE_REAL_E2E_SIDECAR_PORT ?? "29352")
const MATRIX_USER = process.env.MATRIX_INLINE_REAL_E2E_MATRIX_USER ?? "alice"
const MATRIX_PASSWORD = process.env.MATRIX_INLINE_REAL_E2E_MATRIX_PASSWORD ?? "matrix-inline-e2e-password"
const SERVER_NAME = process.env.MATRIX_INLINE_REAL_E2E_SERVER_NAME ?? "localhost"
const TEST_ENCRYPTION_KEY =
  process.env.MATRIX_INLINE_REAL_E2E_ENCRYPTION_KEY ??
  "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
const HELPER_JSON_MARKER = "MATRIX_INLINE_E2E_JSON:"

const command = process.argv[2] ?? "help"

switch (command) {
  case "full":
    await full()
    break
  case "start":
    await start()
    break
  case "stop":
    await stop()
    break
  case "status":
    status()
    break
  case "logs":
    logs()
    break
  case "help":
  case "--help":
  case "-h":
    usage()
    break
  default:
    throw new Error(`Unknown command: ${command}`)
}

function usage() {
  console.log(`Usage: bun scripts/matrix-inline-e2e.ts <full|start|stop|status|logs>

Commands:
  full   Start a fresh local Inline + Matrix bridge run and verify seeded backfill,
         provisioning login, Inline -> Matrix, Matrix -> Inline, and restart catch-up.
  start  Start a fresh local Inline server, Postgres DB, Synapse, Rust adapter, and bridge.
  stop   Stop the latest run's host processes and Docker services.
  status Print process/container status for the latest run.
  logs   Print recent logs for the latest run.

Generated state stays under:
  ${WORK_ROOT}
`)
}

async function full() {
  const state = await start()
  const matrixToken = await matrixLoginToken(state)

  await ensureManagementRoom(state, matrixToken)
  await completeBridgeLogin(state, matrixToken)

  runMatrixScript(state, "live-check", {
    MATRIX_INLINE_E2E_MIN_VISIBLE_PORTALS: "2",
    MATRIX_INLINE_E2E_MIN_BRIDGED_MESSAGES: "2",
  })

  await verifySeedBackfill(state, matrixToken)
  await verifyMatrixToInline(state, matrixToken)
  await verifyInlineToMatrix(state, matrixToken)

  runMatrixScript(state, "live-restart-check", {
    MATRIX_INLINE_E2E_MIN_VISIBLE_PORTALS: "2",
    MATRIX_INLINE_E2E_MIN_BRIDGED_MESSAGES: "2",
  })

  await verifyBridgeRestartCatchup(state, matrixToken)

  console.log("Full matrix-inline real E2E check passed.")
  console.log(`Run state: ${STATE_FILE}`)
}

async function start(): Promise<RunState> {
  await stop({ quiet: true })
  ensureDir(WORK_ROOT)
  ensureMatrixInlineRepo()
  ensurePostgres()

  const runId = timestampId()
  const runRoot = resolve(WORK_ROOT, "runs", runId)
  const matrixRoot = resolve(runRoot, "matrix")
  ensureDir(resolve(runRoot, "logs"))
  ensureDir(matrixRoot)

  const databaseName = `matrix_inline_e2e_${runId.replace(/[^a-zA-Z0-9_]/g, "_")}`
  createDatabase(databaseName)
  const databaseUrl = `postgres://inline:inline@127.0.0.1:${POSTGRES_PORT}/${databaseName}`
  const inlineServerUrl = `http://127.0.0.1:${INLINE_SERVER_PORT}`
  const inlineRealtimeUrl = `ws://127.0.0.1:${INLINE_SERVER_PORT}/realtime`

  runServerScript(["server/scripts/migrate.ts"], databaseUrl)
  const seed = seedDatabase(databaseUrl, runId)

  const state: RunState = {
    runId,
    runRoot,
    matrixRoot,
    databaseUrl,
    inlineServerUrl,
    inlineRealtimeUrl,
    seed,
    ports: {
      postgres: POSTGRES_PORT,
      inlineServer: INLINE_SERVER_PORT,
      synapse: SYNAPSE_PORT,
      bridge: BRIDGE_PORT,
      sidecar: SIDECAR_PORT,
    },
  }
  writeState(state)

  startInlineServer(state)
  runMatrixScript(state, "start")

  console.log("Started matrix-inline real E2E environment.")
  console.log(`Run state: ${STATE_FILE}`)
  return state
}

async function stop(opts: { quiet?: boolean } = {}) {
  const state = readState()
  if (state) {
    stopPid("Inline server", resolve(state.runRoot, "server.pid"), opts)
    runMatrixScript(state, "stop", {}, { allowFailure: true, quiet: opts.quiet })
  }
  if (existsSync(COMPOSE_FILE)) {
    run(["docker", "compose", "-p", PROJECT, "-f", COMPOSE_FILE, "stop", "postgres"], {
      cwd: ROOT,
      allowFailure: true,
      quiet: opts.quiet,
    })
  }
}

function status() {
  const state = readState()
  console.log(`Work root: ${WORK_ROOT}`)
  if (!state) {
    console.log("No current run state.")
  } else {
    console.log(`Run: ${state.runId}`)
    console.log(`Inline server: ${isPidFileRunning(resolve(state.runRoot, "server.pid")) ? "running" : "stopped"}`)
    runMatrixScript(state, "status", {}, { allowFailure: true })
  }
  if (existsSync(COMPOSE_FILE)) {
    run(["docker", "compose", "-p", PROJECT, "-f", COMPOSE_FILE, "ps"], { cwd: ROOT, allowFailure: true })
  }
}

function logs() {
  const state = readState()
  if (!state) {
    console.log("No current run state.")
    return
  }
  printTail(resolve(state.runRoot, "logs", "server.log"), "Inline server")
  runMatrixScript(state, "logs", {}, { allowFailure: true })
}

function ensurePostgres() {
  writeCompose()
  run(["docker", "compose", "-p", PROJECT, "-f", COMPOSE_FILE, "up", "-d", "postgres"], { cwd: ROOT })
  for (let i = 0; i < 90; i += 1) {
    const result = run(
      ["docker", "compose", "-p", PROJECT, "-f", COMPOSE_FILE, "exec", "-T", "postgres", "pg_isready", "-U", "inline", "-d", "postgres"],
      { cwd: ROOT, allowFailure: true, quiet: true },
    )
    if (result.status === 0) return
    Bun.sleepSync(1000)
  }
  throw new Error("Timed out waiting for local Postgres")
}

function writeCompose() {
  ensureDir(WORK_ROOT)
  writeFileSync(
    COMPOSE_FILE,
    `services:
  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: inline
      POSTGRES_PASSWORD: inline
      POSTGRES_DB: postgres
    ports:
      - "127.0.0.1:${POSTGRES_PORT}:5432"
    volumes:
      - "${resolve(WORK_ROOT, "postgres")}:/var/lib/postgresql/data"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U inline -d postgres"]
      interval: 2s
      timeout: 2s
      retries: 30
`,
  )
}

function createDatabase(databaseName: string) {
  run(["docker", "compose", "-p", PROJECT, "-f", COMPOSE_FILE, "exec", "-T", "postgres", "createdb", "-U", "inline", databaseName], {
    cwd: ROOT,
  })
}

function seedDatabase(databaseUrl: string, runId: string): SeedOutput {
  const result = runCapture(
    ["bun", "server/scripts/seed-matrix-inline-e2e.ts", "seed", "--prefix", `matrix-inline-${runId}`],
    {
      cwd: ROOT,
      env: serverEnv(databaseUrl),
    },
  )
  return parseHelperJson(result.stdout) as SeedOutput
}

function startInlineServer(state: RunState) {
  const pidFile = resolve(state.runRoot, "server.pid")
  const logFile = resolve(state.runRoot, "logs", "server.log")
  if (isPidFileRunning(pidFile)) return

  const out = openSync(logFile, "a")
  const child = spawn(BUN_BIN, ["server/src/index.ts"], {
    cwd: ROOT,
    env: {
      ...process.env,
      ...serverEnv(state.databaseUrl, {
        PORT: String(state.ports.inlineServer),
        INLINE_API_RATE_LIMIT_MAX: "10000",
      }),
    },
    detached: true,
    stdio: ["ignore", out, out],
  })
  child.unref()
  writeFileSync(pidFile, String(child.pid))
  waitForHttp(`${state.inlineServerUrl}/health`, "Inline server")
}

async function completeBridgeLogin(state: RunState, matrixToken: string) {
  const userId = matrixUserId()
  const start = await provisioningJson(state, matrixToken, "POST", "/v3/login/start/chat.inline.matrix.email")
  let loginId = stringField(start, "login_id")
  let stepId = stringField(start, "step_id")
  let stepType = stringField(start, "type")

  const contact = await provisioningJson(
    state,
    matrixToken,
    "POST",
    `/v3/login/step/${encodeURIComponent(loginId)}/${encodeURIComponent(stepId)}/${encodeURIComponent(stepType)}`,
    { email: state.seed.bridgeUser.email },
  )

  runServerScript(
    [
      "server/scripts/seed-matrix-inline-e2e.ts",
      "set-login-code",
      "--email",
      state.seed.bridgeUser.email,
      "--code",
      state.seed.loginCode,
    ],
    state.databaseUrl,
    { quiet: true },
  )

  loginId = stringField(contact, "login_id", loginId)
  stepId = stringField(contact, "step_id")
  stepType = stringField(contact, "type")
  const complete = await provisioningJson(
    state,
    matrixToken,
    "POST",
    `/v3/login/step/${encodeURIComponent(loginId)}/${encodeURIComponent(stepId)}/${encodeURIComponent(stepType)}`,
    { verification_code: state.seed.loginCode },
  )
  if (complete.type !== "complete") {
    throw new Error(`Bridge login did not complete for ${userId}: ${JSON.stringify(complete)}`)
  }
}

async function ensureManagementRoom(state: RunState, matrixToken: string) {
  const botLocalpart = bridgeConfigValue(state, "appservice.bot.username")
  const botMxid = `@${botLocalpart}:${SERVER_NAME}`
  const roomId = await createMatrixRoom(state, matrixToken, {
    preset: "private_chat",
    is_direct: true,
    invite: [botMxid],
    name: "matrix-inline real e2e management",
  })
  await waitForMatrixRoomMessage(state, matrixToken, roomId, /Inline bridge bot|management room|Use .*help/i)
}

async function verifySeedBackfill(state: RunState, matrixToken: string) {
  const dmRoom = await waitForPortalRoom(state, state.seed.dmChatId)
  const groupRoom = await waitForPortalRoom(state, state.seed.groupChatId)
  await matrixJoinRoom(state, matrixToken, dmRoom)
  await matrixJoinRoom(state, matrixToken, groupRoom)
  await waitForMatrixRoomMessage(state, matrixToken, dmRoom, textPattern(state.seed.seededMessages.dm))
  await waitForMatrixRoomMessage(state, matrixToken, groupRoom, textPattern(state.seed.seededMessages.group))
}

async function verifyMatrixToInline(state: RunState, matrixToken: string) {
  const dmRoom = await waitForPortalRoom(state, state.seed.dmChatId)
  await matrixJoinRoom(state, matrixToken, dmRoom)
  const text = `matrix to inline e2e ${Date.now()}`
  await sendMatrixText(state, matrixToken, dmRoom, text)
  runServerScript(
    [
      "server/scripts/seed-matrix-inline-e2e.ts",
      "wait-message",
      "--chat-id",
      String(state.seed.dmChatId),
      "--text",
      text,
      "--from-user-id",
      String(state.seed.bridgeUser.id),
    ],
    state.databaseUrl,
    { quiet: true },
  )
}

async function verifyInlineToMatrix(state: RunState, matrixToken: string) {
  const dmRoom = await waitForPortalRoom(state, state.seed.dmChatId)
  const groupRoom = await waitForPortalRoom(state, state.seed.groupChatId)
  await matrixJoinRoom(state, matrixToken, dmRoom)
  await matrixJoinRoom(state, matrixToken, groupRoom)

  const dmText = `inline to matrix dm e2e ${Date.now()}`
  await inlineApiPost(state, state.seed.peerUser.token, "/v1/sendMessage", {
    peerUserId: state.seed.bridgeUser.id,
    text: dmText,
    randomId: String(Date.now() * 1000 + 11),
  })
  await waitForMatrixRoomMessage(state, matrixToken, dmRoom, textPattern(dmText))

  const groupText = `inline to matrix group e2e ${Date.now()}`
  await inlineApiPost(state, state.seed.peerUser.token, "/v1/sendMessage", {
    peerThreadId: state.seed.groupChatId,
    text: groupText,
    randomId: String(Date.now() * 1000 + 12),
  })
  await waitForMatrixRoomMessage(state, matrixToken, groupRoom, textPattern(groupText))
}

async function verifyBridgeRestartCatchup(state: RunState, matrixToken: string) {
  const dmRoom = await waitForPortalRoom(state, state.seed.dmChatId)
  await matrixJoinRoom(state, matrixToken, dmRoom)

  stopPid("matrix-inline bridge", resolve(state.matrixRoot, "run", "bridge.pid"))
  const text = `inline catchup after bridge restart e2e ${Date.now()}`
  await inlineApiPost(state, state.seed.peerUser.token, "/v1/sendMessage", {
    peerUserId: state.seed.bridgeUser.id,
    text,
    randomId: String(Date.now() * 1000 + 21),
  })

  runMatrixScript(state, "start")
  await waitForMatrixRoomMessage(state, matrixToken, dmRoom, textPattern(text), 120_000)
}

async function matrixLoginToken(state: RunState): Promise<string> {
  const response = await jsonFetch(`${homeserverUrl(state)}/_matrix/client/v3/login`, {
    method: "POST",
    body: {
      type: "m.login.password",
      identifier: { type: "m.id.user", user: MATRIX_USER },
      password: MATRIX_PASSWORD,
      device_id: "matrix-inline-real-e2e",
    },
  })
  return stringField(response, "access_token")
}

async function provisioningJson(
  state: RunState,
  token: string,
  method: string,
  path: string,
  body?: Record<string, unknown>,
) {
  const userParam = encodeURIComponent(matrixUserId())
  return jsonFetch(`http://127.0.0.1:${state.ports.bridge}/_matrix/provision${path}?user_id=${userParam}`, {
    method,
    token,
    body,
  })
}

async function inlineApiPost(state: RunState, token: string, path: string, body: Record<string, unknown>) {
  const response = await jsonFetch(`${state.inlineServerUrl}${path}`, {
    method: "POST",
    token,
    body,
  })
  if (response.ok !== true) {
    throw new Error(`Inline API ${path} failed: ${JSON.stringify(response)}`)
  }
  return response
}

async function createMatrixRoom(state: RunState, token: string, body: Record<string, unknown>): Promise<string> {
  const response = await matrixJson(state, token, "POST", "/_matrix/client/v3/createRoom", body)
  return stringField(response, "room_id")
}

async function matrixJoinRoom(state: RunState, token: string, roomId: string) {
  await matrixJson(state, token, "POST", `/_matrix/client/v3/rooms/${encodeURIComponent(roomId)}/join`, {})
}

async function sendMatrixText(state: RunState, token: string, roomId: string, text: string) {
  const txn = `e2e-${Date.now()}-${Math.floor(Math.random() * 1_000_000)}`
  await matrixJson(
    state,
    token,
    "PUT",
    `/_matrix/client/v3/rooms/${encodeURIComponent(roomId)}/send/m.room.message/${txn}`,
    { msgtype: "m.text", body: text },
  )
}

async function waitForMatrixRoomMessage(
  state: RunState,
  token: string,
  roomId: string,
  pattern: RegExp,
  timeoutMs = 90_000,
) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const response = await matrixJson(
      state,
      token,
      "GET",
      `/_matrix/client/v3/rooms/${encodeURIComponent(roomId)}/messages?dir=b&limit=80`,
    )
    const chunk = Array.isArray(response.chunk) ? response.chunk : []
    const found = chunk.some((event: any) => {
      const body = typeof event?.content?.body === "string" ? event.content.body : ""
      return pattern.test(body)
    })
    if (found) return
    await Bun.sleep(1000)
  }
  throw new Error(`Timed out waiting for Matrix room ${roomId} message matching ${pattern}`)
}

async function matrixJson(
  state: RunState,
  token: string,
  method: string,
  path: string,
  body?: Record<string, unknown>,
) {
  return jsonFetch(`${homeserverUrl(state)}${path}`, { method, token, body })
}

async function jsonFetch(
  url: string,
  opts: { method: string; token?: string; body?: Record<string, unknown> },
): Promise<any> {
  const headers: Record<string, string> = {}
  if (opts.token) headers.authorization = `Bearer ${opts.token}`
  if (opts.body !== undefined) headers["content-type"] = "application/json"
  const response = await fetch(url, {
    method: opts.method,
    headers,
    body: opts.body === undefined ? undefined : JSON.stringify(opts.body),
  })
  const text = await response.text()
  const data = text ? JSON.parse(text) : {}
  if (!response.ok) {
    throw new Error(`${opts.method} ${url} failed with ${response.status}: ${text}`)
  }
  return data
}

async function waitForPortalRoom(state: RunState, chatId: number): Promise<string> {
  const bridgeDb = resolve(state.matrixRoot, "bridge", "matrix-inline.db")
  for (let i = 0; i < 120; i += 1) {
    const result = runCapture(
      ["sqlite3", "-readonly", bridgeDb, `SELECT mxid FROM portal WHERE id = '${chatId}' AND mxid IS NOT NULL AND mxid <> '' LIMIT 1;`],
      { cwd: MATRIX_INLINE_ROOT, allowFailure: true, quiet: true },
    )
    const roomId = result.stdout.trim()
    if (roomId) return roomId
    await Bun.sleep(1000)
  }
  throw new Error(`Timed out waiting for Matrix portal for Inline chat ${chatId}`)
}

function runMatrixScript(
  state: RunState,
  scriptCommand: string,
  extraEnv: Record<string, string> = {},
  opts: { allowFailure?: boolean; quiet?: boolean } = {},
) {
  run(["bash", "scripts/e2e-local.sh", scriptCommand], {
    cwd: MATRIX_INLINE_ROOT,
    env: {
      ...matrixEnv(state),
      ...extraEnv,
    },
    allowFailure: opts.allowFailure,
    quiet: opts.quiet,
  })
}

function bridgeConfigValue(state: RunState, path: string): string {
  return runCapture(
    ["go", "run", "./scripts/e2econfig", "get", "--config", resolve(state.matrixRoot, "bridge", "config.yaml"), "--path", path],
    { cwd: MATRIX_INLINE_ROOT },
  ).stdout.trim()
}

function runServerScript(args: string[], databaseUrl: string, opts: { quiet?: boolean } = {}) {
  if (opts.quiet) {
    runCapture(["bun", ...args], {
      cwd: ROOT,
      env: serverEnv(databaseUrl),
      quiet: true,
    })
    return
  }

  run(["bun", ...args], {
    cwd: ROOT,
    env: serverEnv(databaseUrl),
  })
}

function run(args: string[], opts: {
  cwd: string
  env?: Record<string, string>
  allowFailure?: boolean
  quiet?: boolean
}): { status: number | null } {
  if (!opts.quiet) console.log(`==> ${args.join(" ")}`)
  const result = spawnSync(args[0], args.slice(1), {
    cwd: opts.cwd,
    env: { ...process.env, ...opts.env },
    stdio: opts.quiet ? "ignore" : "inherit",
  })
  if (result.error) throw result.error
  if (!opts.allowFailure && result.status !== 0) {
    throw new Error(`Command failed (${result.status}): ${args.join(" ")}`)
  }
  return { status: result.status }
}

function runCapture(args: string[], opts: {
  cwd: string
  env?: Record<string, string>
  allowFailure?: boolean
  quiet?: boolean
}): { stdout: string; stderr: string; status: number | null } {
  if (!opts.quiet) console.log(`==> ${args.join(" ")}`)
  const result = spawnSync(args[0], args.slice(1), {
    cwd: opts.cwd,
    env: { ...process.env, ...opts.env },
    encoding: "utf8",
  })
  if (result.error) throw result.error
  if (!opts.allowFailure && result.status !== 0) {
    throw new Error(`Command failed (${result.status}): ${args.join(" ")}\n${result.stderr}`)
  }
  return {
    stdout: result.stdout ?? "",
    stderr: result.stderr ?? "",
    status: result.status,
  }
}

function parseHelperJson(stdout: string): unknown {
  const line = stdout
    .split(/\r?\n/)
    .find((candidate) => candidate.startsWith(HELPER_JSON_MARKER))
  if (!line) {
    throw new Error(`E2E helper did not print ${HELPER_JSON_MARKER}`)
  }
  return JSON.parse(line.slice(HELPER_JSON_MARKER.length))
}

function serverEnv(databaseUrl: string, extra: Record<string, string> = {}): Record<string, string> {
  return {
    NODE_ENV: "development",
    DATABASE_URL: databaseUrl,
    ENCRYPTION_KEY: TEST_ENCRYPTION_KEY,
    INVITE_CODES_REQUIRED: "false",
    RESEND_API_KEY: "re_matrix_inline_e2e_dummy",
    SEND_EMAIL: "",
    INLINE_API_RATE_LIMIT_MAX: "10000",
    ...extra,
  }
}

function matrixEnv(state: RunState): Record<string, string> {
  return {
    MATRIX_INLINE_E2E_ROOT: state.matrixRoot,
    MATRIX_INLINE_E2E_PROJECT: `matrix-inline-real-${state.runId}`,
    MATRIX_INLINE_E2E_SYNAPSE_PORT: String(state.ports.synapse),
    MATRIX_INLINE_E2E_BRIDGE_PORT: String(state.ports.bridge),
    MATRIX_INLINE_E2E_USER: MATRIX_USER,
    MATRIX_INLINE_E2E_PASSWORD: MATRIX_PASSWORD,
    MATRIX_INLINE_E2E_SERVER_NAME: SERVER_NAME,
    INLINE_SIDECAR_BIND: `127.0.0.1:${state.ports.sidecar}`,
    INLINE_SIDECAR_URL: `http://127.0.0.1:${state.ports.sidecar}`,
    INLINE_API_BASE_URL: `${state.inlineServerUrl}/v1`,
    INLINE_REALTIME_URL: state.inlineRealtimeUrl,
    RUST_LOG: process.env.RUST_LOG ?? "info",
  }
}

function homeserverUrl(state: RunState): string {
  return `http://127.0.0.1:${state.ports.synapse}`
}

function matrixUserId(): string {
  return `@${MATRIX_USER}:${SERVER_NAME}`
}

function writeState(state: RunState) {
  ensureDir(dirname(STATE_FILE))
  writeFileSync(STATE_FILE, JSON.stringify(state, null, 2))
}

function readState(): RunState | undefined {
  if (!existsSync(STATE_FILE)) return undefined
  return JSON.parse(readFileSync(STATE_FILE, "utf8")) as RunState
}

function ensureDir(path: string) {
  mkdirSync(path, { recursive: true })
}

function ensureMatrixInlineRepo() {
  if (!existsSync(resolve(MATRIX_INLINE_ROOT, "scripts", "e2e-local.sh"))) {
    throw new Error(`matrix-inline repo not found at ${MATRIX_INLINE_ROOT}`)
  }
}

function waitForHttp(url: string, name: string) {
  for (let i = 0; i < 90; i += 1) {
    const result = spawnSync("curl", ["-fsS", url], { stdio: "ignore" })
    if (result.status === 0) return
    Bun.sleepSync(1000)
  }
  throw new Error(`Timed out waiting for ${name}: ${url}`)
}

function stopPid(name: string, pidFile: string, opts: { quiet?: boolean } = {}) {
  if (!existsSync(pidFile)) return
  const pid = Number(readFileSync(pidFile, "utf8").trim())
  if (!Number.isSafeInteger(pid) || pid <= 0 || !processRunning(pid)) return
  if (!opts.quiet) console.log(`==> Stopping ${name} (${pid})`)
  process.kill(pid, "SIGTERM")
  for (let i = 0; i < 40; i += 1) {
    if (!processRunning(pid)) return
    Bun.sleepSync(250)
  }
}

function isPidFileRunning(pidFile: string): boolean {
  if (!existsSync(pidFile)) return false
  const pid = Number(readFileSync(pidFile, "utf8").trim())
  return Number.isSafeInteger(pid) && processRunning(pid)
}

function processRunning(pid: number): boolean {
  try {
    process.kill(pid, 0)
    return true
  } catch {
    return false
  }
}

function printTail(path: string, title: string) {
  if (!existsSync(path)) return
  console.log(`==> ${title}`)
  run(["tail", "-80", path], { cwd: ROOT, allowFailure: true })
}

function timestampId(): string {
  const stamp = new Date().toISOString().replace(/[-:.TZ]/g, "").slice(0, 17)
  const suffix = Math.random().toString(36).slice(2, 8)
  return `${stamp}-${suffix}`
}

function stringField(value: any, field: string, fallback?: string): string {
  const fieldValue = value?.[field]
  if (typeof fieldValue === "string" && fieldValue.length > 0) return fieldValue
  if (fallback !== undefined) return fallback
  throw new Error(`Response missing string field ${field}: ${JSON.stringify(value)}`)
}

function textPattern(text: string): RegExp {
  return new RegExp(escapeRegExp(text), "i")
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
}
