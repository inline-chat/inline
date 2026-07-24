#!/usr/bin/env node

import { constants as fsConstants, existsSync, realpathSync } from "node:fs"
import { access, cp, lstat, mkdir, readFile, realpath, rm, stat, symlink } from "node:fs/promises"
import http from "node:http"
import { createHash, randomBytes } from "node:crypto"
import { spawn, spawnSync, type ChildProcessWithoutNullStreams } from "node:child_process"
import net from "node:net"
import os from "node:os"
import path from "node:path"
import { fileURLToPath } from "node:url"
import { parse as parseYaml } from "yaml"
import { redactText, redactUrl, type SecretRedaction } from "./sidecar/contract.js"

type Command = "install" | "status" | "doctor" | "test-send" | "help" | "version"

type InstallOptions = {
  command: Command
  hermesHome: string
  pluginId: string
  link: boolean
  dryRun: boolean
  force: boolean
  json: boolean
  to?: string
  text: string
  baseUrl?: string
  statePath?: string
  timeoutMs: number
}

type PackageInfo = {
  name: string
  version: string
}

type SidecarInfo = {
  path: string
  exists: boolean
  size: number | null
  sha256: string | null
}

type NodeInfo = {
  path: string
  source: "INLINE_NODE_BIN" | "process.execPath"
  ok: boolean
  exists: boolean
  executable: boolean
  version: string | null
  major: number | null
  error: string | null
}

type ActivationInfo = {
  configPath: string
  configExists: boolean
  pluginEnabled: boolean
  platformConfigured: boolean
  configTokenConfigured: boolean
  tokenPresent: boolean
  tokenConfigured: boolean
}

type TokenInfo = {
  token: string
}

const defaultPluginId = "inline"
const pluginEnableKey = "inline-platform"
const minNodeMajor = 20

export async function main(argv = process.argv.slice(2)): Promise<number> {
  const opts = parseArgs(argv)
  if (opts.command === "help") {
    printHelp()
    return 0
  }

  const pkg = await readPackageInfo()
  if (opts.command === "version") {
    console.log(`${pkg.name}@${pkg.version}`)
    return 0
  }

  const source = resolvePluginSourceDir()
  const target = path.join(opts.hermesHome, "plugins", opts.pluginId)

  if (opts.command === "status" || opts.command === "doctor") {
    const status = await inspectInstall({ source, target, opts, pkg })
    if (opts.json) {
      console.log(JSON.stringify(status, null, 2))
    } else {
      printStatus(status)
    }
    return status.ok ? 0 : opts.command === "doctor" ? 1 : 0
  }

  if (opts.command === "test-send") {
    const result = await testSend({ source, opts, pkg })
    if (opts.json) {
      console.log(JSON.stringify(result, null, 2))
    } else {
      printTestSendResult(result)
    }
    return result.ok ? 0 : 1
  }

  const result = await installPlugin({ source, target, opts, pkg })
  if (opts.json) {
    console.log(JSON.stringify(result, null, 2))
  } else {
    printInstallResult(result)
  }
  return result.ok ? 0 : 1
}

type InstallResult = Awaited<ReturnType<typeof inspectInstall>> & {
  action: "install" | "status"
  installed: boolean
}

type TestSendResult = {
  ok: boolean
  action: "test-send"
  packageName: string
  packageVersion: string
  source: string
  sourceValid: boolean
  sidecar: string
  target?: Record<string, string>
  textLength: number
  tokenPresent: boolean
  node: NodeInfo
  baseUrl: string
  statePath: string
  dryRun: boolean
  sent: boolean
  messageId?: string | null
  health?: unknown
  issues: string[]
  logs?: string[]
}

async function installPlugin(params: {
  source: string
  target: string
  opts: InstallOptions
  pkg: PackageInfo
}): Promise<InstallResult> {
  const before = await inspectInstall(params)
  if (!before.sourceValid) return { ...before, action: "install", installed: false }
  if (params.opts.dryRun) return { ...before, action: "install", installed: false }

  await mkdir(path.dirname(params.target), { recursive: true })

  if (before.targetExists) {
    if (!params.opts.force) {
      return {
        ...before,
        ok: false,
        action: "install",
        installed: false,
        issues: [
          ...before.issues,
          `target already exists: ${params.target}. Re-run with --force to replace it.`,
        ],
      }
    }
    await rm(params.target, { recursive: true, force: true })
  }

  if (params.opts.link) {
    await symlink(params.source, params.target, "dir")
  } else {
    await cp(params.source, params.target, {
      recursive: true,
      force: true,
      filter: shouldCopyPluginFile,
    })
  }

  const after = await inspectInstall(params)
  return {
    ...after,
    action: "install",
    installed: after.targetValid,
  }
}

function shouldCopyPluginFile(src: string): boolean {
  const name = path.basename(src)
  if (name === "__pycache__" || name === ".pytest_cache" || name === ".DS_Store") return false
  if (name.endsWith(".pyc") || name.endsWith(".pyo") || name.endsWith(".map")) return false
  return true
}

async function inspectInstall(params: {
  source: string
  target: string
  opts: InstallOptions
  pkg: PackageInfo
}) {
  const sourceValid = await hasPluginFiles(params.source)
  const targetExists = await exists(params.target)
  const targetValid = targetExists ? await hasPluginFiles(params.target) : false
  const targetLinked = targetExists ? await isSymlink(params.target) : false
  const sourceReal = await safeRealpath(params.source)
  const targetReal = targetExists ? await safeRealpath(params.target) : null
  const sourceSidecar = await inspectSidecar(params.source)
  const targetSidecar = targetExists ? await inspectSidecar(params.target) : null
  const node = await inspectNode()
  const activation = await inspectActivation(params.opts.hermesHome)
  const issues: string[] = []
  const warnings: string[] = []

  if (!sourceValid) {
    issues.push(`plugin source is incomplete: ${params.source}`)
  }
  if (targetExists && !targetValid) {
    issues.push(`installed plugin is incomplete: ${params.target}`)
  }
  if (params.opts.command === "doctor" && !targetExists) {
    issues.push(`plugin is not installed: ${params.target}`)
  }
  if (targetSidecar?.exists && sourceSidecar.sha256 && targetSidecar.sha256 && sourceSidecar.sha256 !== targetSidecar.sha256) {
    issues.push("installed sidecar bundle does not match the package sidecar bundle")
  }
  if (!node.ok) {
    issues.push(node.error || `${node.source} is not usable: ${node.path}`)
  }
  if (params.opts.command === "doctor" && !activation.pluginEnabled) {
    issues.push(`Hermes plugin '${pluginEnableKey}' is not enabled. Run: hermes plugins enable ${pluginEnableKey}`)
  }
  if (targetExists && activation.pluginEnabled && !activation.platformConfigured && !activation.tokenConfigured) {
    warnings.push("Inline platform config is not enabled. Add platforms.inline.enabled: true and set INLINE_TOKEN/INLINE_BOT_TOKEN in the gateway environment, or set platforms.inline.token/inline.token in Hermes config")
  }
  if (targetExists && activation.pluginEnabled && !activation.tokenConfigured) {
    warnings.push("No Inline token was detected in INLINE_TOKEN, INLINE_BOT_TOKEN, or Hermes Inline config; live Inline realtime checks will not connect")
  }

  return {
    ok: sourceValid && (!targetExists || targetValid) && node.ok && issues.length === 0,
    action: "status" as "install" | "status",
    packageName: params.pkg.name,
    packageVersion: params.pkg.version,
    hermesHome: params.opts.hermesHome,
    pluginId: params.opts.pluginId,
    source: params.source,
    sourceReal,
    sourceValid,
    target: params.target,
    targetReal,
    targetExists,
    targetValid,
    targetLinked,
    sidecar: {
      source: sourceSidecar,
      target: targetSidecar,
    },
    node,
    activation,
    dryRun: params.opts.dryRun,
    link: params.opts.link,
    force: params.opts.force,
    issues,
    warnings,
  }
}

async function testSend(params: {
  source: string
  opts: InstallOptions
  pkg: PackageInfo
}): Promise<TestSendResult> {
  const sourceValid = await hasPluginFiles(params.source)
  const sidecar = path.join(params.source, "sidecar", "index.mjs")
  const tokenInfo = await resolveInlineToken(params.opts.hermesHome)
  const token = tokenInfo.token
  const baseUrl = params.opts.baseUrl || process.env.INLINE_BASE_URL || "https://api.inline.chat"
  let redactions = secretRedactions({ token, baseUrl })
  const statePath = path.resolve(expandHome(params.opts.statePath || path.join(params.opts.hermesHome, "inline", "test-send-state.json")))
  const node = await inspectNode()
  const issues: string[] = []
  let target: Record<string, string> | undefined

  if (!sourceValid) issues.push(`plugin source is incomplete: ${params.source}`)
  if (!await exists(sidecar)) issues.push(`sidecar is missing: ${sidecar}`)
  if (!params.opts.to) {
    issues.push("test-send requires --to chat:<id> or --to user:<id>")
  } else {
    try {
      target = parseInlineTarget(params.opts.to)
    } catch (error) {
      issues.push(error instanceof Error ? error.message : String(error))
    }
  }
  if (!params.opts.text.trim()) issues.push("test-send requires non-empty --text")
  if (!token && !params.opts.dryRun) issues.push("Inline token is required in INLINE_TOKEN, INLINE_BOT_TOKEN, platforms.inline.token, or inline.token")
  if (!params.opts.dryRun && !node.ok) issues.push(node.error || `${node.source} is not usable: ${node.path}`)

  const base: TestSendResult = {
    ok: issues.length === 0,
    action: "test-send",
    packageName: params.pkg.name,
    packageVersion: params.pkg.version,
    source: params.source,
    sourceValid,
    sidecar,
    ...(target ? { target } : {}),
    textLength: params.opts.text.length,
    tokenPresent: Boolean(token),
    node,
    baseUrl: redactUrl(baseUrl),
    statePath,
    dryRun: params.opts.dryRun,
    sent: false,
    issues,
  }

  if (params.opts.dryRun || issues.length > 0) return base

  const port = await getOpenPort()
  const sidecarToken = randomBytes(18).toString("hex")
  redactions = secretRedactions({ token, sidecarToken, baseUrl })
  const logs: string[] = []
  const child = spawn(node.path, [sidecar], {
    env: {
      ...process.env,
      INLINE_TOKEN: token,
      INLINE_BASE_URL: baseUrl,
      INLINE_SIDECAR_TOKEN: sidecarToken,
      INLINE_SIDECAR_PORT: String(port),
      INLINE_SIDECAR_BIND: "127.0.0.1",
      INLINE_STATE_PATH: statePath,
      INLINE_SIDECAR_WATCH_STDIN: "1",
    },
    stdio: ["pipe", "pipe", "pipe"],
  })
  collectSidecarLogs(child, logs, secretRedactions({ token, sidecarToken, baseUrl }))

  try {
    const health = await waitForSidecarReady(port, sidecarToken, child, params.opts.timeoutMs, redactions)
    const result = await postSidecarJson(port, sidecarToken, "/send", {
      target,
      text: params.opts.text,
      parseMarkdown: true,
    }, params.opts.timeoutMs)
    const body = asObject(result)
    const sendResult = asObject(body.result)
    const messageId = typeof sendResult?.messageId === "string" ? sendResult.messageId : null
    return {
      ...base,
      ok: true,
      sent: true,
      messageId,
      health: redactValue(health, redactions),
      logs: logs.slice(-20),
    }
  } catch (error) {
    const issue = error instanceof Error ? error.message : String(error)
    return {
      ...base,
      ok: false,
      health: error instanceof TestSendError ? redactValue(error.health, redactions) : undefined,
      issues: [redactText(issue, redactions)],
      logs: logs.slice(-40),
    }
  } finally {
    await stopSidecar(child, port, sidecarToken)
  }
}

function parseArgs(argv: string[]): InstallOptions {
  const command = parseCommand(argv[0])
  const opts: InstallOptions = {
    command,
    hermesHome: process.env.HERMES_HOME || path.join(os.homedir(), ".hermes"),
    pluginId: defaultPluginId,
    link: false,
    dryRun: false,
    force: false,
    json: false,
    text: "Inline Hermes test",
    timeoutMs: 30_000,
  }

  const firstArgIsFlag = argv[0]?.startsWith("-") ?? false
  for (let i = argv[0] == null || firstArgIsFlag ? 0 : 1; i < argv.length; i += 1) {
    const arg = argv[i]
    switch (arg) {
      case "--hermes-home":
        opts.hermesHome = requireValue(argv, ++i, arg)
        break
      case "--plugin-id":
        opts.pluginId = requireValue(argv, ++i, arg)
        break
      case "--link":
        opts.link = true
        break
      case "--dry-run":
        opts.dryRun = true
        break
      case "--force":
        opts.force = true
        break
      case "--json":
        opts.json = true
        break
      case "--to":
        opts.to = requireValue(argv, ++i, arg)
        break
      case "--text":
        opts.text = requireValue(argv, ++i, arg)
        break
      case "--base-url":
        opts.baseUrl = requireValue(argv, ++i, arg)
        break
      case "--state-path":
        opts.statePath = requireValue(argv, ++i, arg)
        break
      case "--timeout-ms":
        opts.timeoutMs = parsePositiveInt(requireValue(argv, ++i, arg), arg)
        break
      case "-h":
      case "--help":
        opts.command = "help"
        break
      case "-v":
      case "--version":
        opts.command = "version"
        break
      default:
        throw new Error(`unknown argument: ${arg}`)
    }
  }

  opts.hermesHome = path.resolve(expandHome(opts.hermesHome))
  validatePluginId(opts.pluginId)
  return opts
}

function parseCommand(raw: string | undefined): Command {
  if (raw == null || raw === "install") return "install"
  if (raw === "status" || raw === "doctor" || raw === "test-send" || raw === "help" || raw === "version") return raw
  if (raw === "-h" || raw === "--help") return "help"
  if (raw === "-v" || raw === "--version") return "version"
  throw new Error(`unknown command: ${raw}`)
}

function requireValue(argv: string[], index: number, flag: string): string {
  const value = argv[index]
  if (value == null || value.startsWith("--")) {
    throw new Error(`${flag} requires a value`)
  }
  return value
}

function validatePluginId(pluginId: string) {
  if (!/^[a-z0-9][a-z0-9_-]*$/i.test(pluginId)) {
    throw new Error(`invalid plugin id: ${pluginId}`)
  }
}

function parseInlineTarget(rawTarget: string): Record<string, string> {
  let raw = rawTarget.trim()
  if (raw.startsWith("inline:")) raw = raw.slice("inline:".length).trim()
  const parts = raw.split(":")
  const [kind, value] = parts.length === 1
    ? ["chat", parts[0]]
    : parts.length === 2
      ? parts
      : ["", ""]
  const id = (value || "").trim()
  if (!/^[1-9][0-9]*$/.test(id)) {
    throw new Error(`invalid Inline target: ${rawTarget}`)
  }
  if (kind === "chat") return { chatId: id }
  if (kind === "user") return { userId: id }
  throw new Error(`invalid Inline target: ${rawTarget}`)
}

function parsePositiveInt(raw: string, flag: string): number {
  const value = raw.trim()
  const parsed = Number(value)
  if (!/^[1-9][0-9]*$/.test(value) || !Number.isSafeInteger(parsed)) {
    throw new Error(`${flag} requires a positive integer`)
  }
  return parsed
}

function resolvePluginSourceDir(): string {
  const here = path.dirname(fileURLToPath(import.meta.url))
  const candidates = [
    path.resolve(here, "../plugin/inline"),
    path.resolve(here, "../../plugin/inline"),
    path.resolve(process.cwd(), "plugin/inline"),
  ]
  for (const candidate of candidates) {
    if (candidate && existsSyncLite(candidate)) return candidate
  }
  return candidates[0]!
}

async function hasPluginFiles(dir: string): Promise<boolean> {
  const files = [
    "plugin.yaml",
    "__init__.py",
    "adapter.py",
    path.join("sidecar", "index.mjs"),
  ]
  const checks = files.map((file) => exists(path.join(dir, file)))
  return (await Promise.all(checks)).every(Boolean)
}

async function inspectSidecar(pluginDir: string): Promise<SidecarInfo> {
  const file = path.join(pluginDir, "sidecar", "index.mjs")
  try {
    const [raw, info] = await Promise.all([
      readFile(file),
      stat(file),
    ])
    return {
      path: file,
      exists: true,
      size: info.size,
      sha256: createHash("sha256").update(raw).digest("hex"),
    }
  } catch {
    return {
      path: file,
      exists: false,
      size: null,
      sha256: null,
    }
  }
}

async function inspectNode(): Promise<NodeInfo> {
  const configured = (process.env.INLINE_NODE_BIN || "").trim()
  const nodePath = configured || process.execPath
  const source = configured ? "INLINE_NODE_BIN" : "process.execPath"
  const exists = await hasAccess(nodePath, fsConstants.F_OK)
  const executable = exists ? await hasAccess(nodePath, fsConstants.X_OK) : false

  if (!exists || !executable) {
    return {
      path: nodePath,
      source,
      ok: false,
      exists,
      executable,
      version: null,
      major: null,
      error: exists ? `${source} is not executable: ${nodePath}` : `${source} does not exist: ${nodePath}`,
    }
  }

  const result = spawnSync(nodePath, ["--version"], {
    encoding: "utf8",
    timeout: 5_000,
  })
  const version = (result.stdout || result.stderr || "").trim()
  const major = parseNodeMajor(version)
  const versionError = major == null
    ? `${source} did not report a recognizable Node.js version: ${version || "(empty)"}`
    : major < minNodeMajor
      ? `${source} must be Node.js >=${minNodeMajor}; got ${version}`
      : null
  const error = result.error
    ? result.error.message
    : result.status === 0 ? versionError : version || `${source} exited with status ${result.status ?? "unknown"}`

  return {
    path: nodePath,
    source,
    ok: error == null,
    exists,
    executable,
    version: version || null,
    major,
    error,
  }
}

async function inspectActivation(hermesHome: string): Promise<ActivationInfo> {
  const configPath = path.join(hermesHome, "config.yaml")
  let config: unknown = null
  let configExists = false
  try {
    config = parseYaml(await readFile(configPath, "utf8"))
    configExists = true
  } catch {
    config = null
  }
  const tokenPresent = Boolean(process.env.INLINE_TOKEN || process.env.INLINE_BOT_TOKEN)
  const configTokenConfigured = configTokenIsConfigured(config, ["platforms", defaultPluginId, "token"]) || configTokenIsConfigured(config, [defaultPluginId, "token"])

  return {
    configPath,
    configExists,
    pluginEnabled: readConfigList(config, ["plugins", "enabled"]).includes(pluginEnableKey),
    platformConfigured: readConfigBoolean(config, ["platforms", defaultPluginId, "enabled"]) || readConfigBoolean(config, [defaultPluginId, "enabled"]),
    configTokenConfigured,
    tokenPresent,
    tokenConfigured: tokenPresent || configTokenConfigured,
  }
}

function readConfigList(config: unknown, pathParts: string[]): string[] {
  const value = readConfigValue(config, pathParts)
  if (Array.isArray(value)) return value.map((item) => String(item)).filter(Boolean)
  if (typeof value === "string" && value.trim()) return [value.trim()]
  return []
}

function readConfigBoolean(config: unknown, pathParts: string[]): boolean {
  const value = readConfigValue(config, pathParts)
  if (typeof value === "boolean") return value
  if (typeof value === "number") return value !== 0
  if (typeof value !== "string") return false
  const normalized = value.trim().toLowerCase()
  return normalized === "true" || normalized === "yes" || normalized === "on" || normalized === "1"
}

function configTokenIsConfigured(config: unknown, pathParts: string[]): boolean {
  return Boolean(readConfigToken(config, pathParts))
}

async function resolveInlineToken(hermesHome: string): Promise<TokenInfo> {
  const envToken = normalizeToken(process.env.INLINE_TOKEN) || normalizeToken(process.env.INLINE_BOT_TOKEN)
  let config: unknown = null
  try {
    config = parseYaml(await readFile(path.join(hermesHome, "config.yaml"), "utf8"))
  } catch {
    config = null
  }

  const configToken = readConfigToken(config, ["platforms", defaultPluginId, "token"]) || readConfigToken(config, [defaultPluginId, "token"])
  return {
    token: envToken || configToken,
  }
}

function readConfigToken(config: unknown, pathParts: string[]): string {
  const value = readConfigValue(config, pathParts)
  if (typeof value !== "string") return ""
  const trimmed = value.trim()
  if (!trimmed) return ""
  const envName = envReferenceName(value)
  return envName ? normalizeToken(process.env[envName]) : trimmed
}

function normalizeToken(value: string | undefined): string {
  return typeof value === "string" ? value.trim() : ""
}

function envReferenceName(value: string): string | null {
  const match = /^\$\{([A-Za-z_][A-Za-z0-9_]*)\}$/.exec(value.trim())
  return match?.[1] || null
}

function readConfigValue(config: unknown, pathParts: string[]): unknown {
  let current = config
  for (const part of pathParts) {
    if (!current || typeof current !== "object" || Array.isArray(current) || !(part in current)) return undefined
    current = (current as Record<string, unknown>)[part]
  }
  return current
}

function parseNodeMajor(version: string): number | null {
  const match = /\bv?(\d+)(?:\.\d+){0,2}\b/.exec(version.trim())
  if (!match) return null
  const major = Number.parseInt(match[1]!, 10)
  return Number.isFinite(major) ? major : null
}

async function readPackageInfo(): Promise<PackageInfo> {
  const here = path.dirname(fileURLToPath(import.meta.url))
  const candidates = [
    path.resolve(here, "../package.json"),
    path.resolve(here, "../../package.json"),
  ]
  for (const candidate of candidates) {
    try {
      const raw = await readFile(candidate, "utf8")
      const parsed = JSON.parse(raw) as Partial<PackageInfo>
      return {
        name: parsed.name || "@inline-chat/hermes-agent-adapter",
        version: parsed.version || "0.0.0",
      }
    } catch {
      continue
    }
  }
  return { name: "@inline-chat/hermes-agent-adapter", version: "0.0.0" }
}

async function exists(file: string): Promise<boolean> {
  return hasAccess(file, fsConstants.F_OK)
}

async function hasAccess(file: string, mode: number): Promise<boolean> {
  try {
    await access(file, mode)
    return true
  } catch {
    return false
  }
}

function existsSyncLite(file: string): boolean {
  return existsSync(file)
}

async function isSymlink(file: string): Promise<boolean> {
  try {
    return (await lstat(file)).isSymbolicLink()
  } catch {
    return false
  }
}

async function safeRealpath(file: string): Promise<string | null> {
  try {
    return await realpath(file)
  } catch {
    return null
  }
}

function expandHome(value: string): string {
  if (value === "~") return os.homedir()
  if (value.startsWith("~/")) return path.join(os.homedir(), value.slice(2))
  return value
}

function getOpenPort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = net.createServer()
    server.once("error", reject)
    server.listen(0, "127.0.0.1", () => {
      const address = server.address()
      const port = typeof address === "object" && address ? address.port : 0
      server.close((error) => {
        if (error) reject(error)
        else resolve(port)
      })
    })
  })
}

function collectSidecarLogs(child: ChildProcessWithoutNullStreams, logs: string[], secrets: SecretRedaction[]) {
  const append = (chunk: Buffer) => {
    const redacted = redactText(chunk.toString("utf8"), secrets)
    for (const line of redacted.split(/\r?\n/)) {
      const trimmed = line.trim()
      if (trimmed) logs.push(trimmed)
    }
    if (logs.length > 200) logs.splice(0, logs.length - 200)
  }
  child.stdout.on("data", append)
  child.stderr.on("data", append)
}

function secretRedactions(input: {
  token?: string
  sidecarToken?: string
  baseUrl?: string
}): SecretRedaction[] {
  return [
    { value: input.token, label: "[INLINE_TOKEN]" },
    { value: input.sidecarToken, label: "[INLINE_SIDECAR_TOKEN]" },
    { value: input.baseUrl, label: "[INLINE_BASE_URL]" },
    ...urlSecretRedactions(input.baseUrl),
  ]
}

function urlSecretRedactions(value: string | undefined): SecretRedaction[] {
  if (!value) return []
  let url: URL
  try {
    url = new URL(value)
  } catch {
    return []
  }

  const redactions: SecretRedaction[] = []
  if (url.username) redactions.push({ value: decodeURIComponent(url.username), label: "[INLINE_BASE_URL_USER]" })
  if (url.password) redactions.push({ value: decodeURIComponent(url.password), label: "[INLINE_BASE_URL_PASSWORD]" })
  for (const [key, item] of url.searchParams.entries()) {
    const normalized = key.toLowerCase()
    if (normalized === "access_token" || normalized === "auth" || normalized === "authorization" || normalized === "key" || normalized === "token" || normalized.includes("token")) {
      redactions.push({ value: item, label: "[INLINE_BASE_URL_PARAM]" })
    }
  }
  return redactions
}

async function waitForSidecarReady(
  port: number,
  sidecarToken: string,
  child: ChildProcessWithoutNullStreams,
  timeoutMs: number,
  redactions: SecretRedaction[] = [],
): Promise<unknown> {
  const deadline = Date.now() + timeoutMs
  let lastHealth: unknown
  let lastError: unknown
  while (Date.now() < deadline) {
    if (child.exitCode != null) {
      throw new TestSendError(`Inline sidecar exited with code ${child.exitCode}`, lastHealth)
    }
    try {
      const health = await postSidecarJson(port, sidecarToken, "/healthz", {}, 2_000)
      lastHealth = health
      const result = asObject(asObject(health).result)
      if (result?.connected === true) return health
    } catch (error) {
      lastError = error
    }
    await sleep(250)
  }
  const rawHealthFailure = describeHealthFailure(lastHealth)
  const healthFailure = rawHealthFailure ? redactText(rawHealthFailure, redactions) : null
  const suffix = healthFailure
    ? `: ${healthFailure}`
    : lastError instanceof Error ? `: ${redactText(lastError.message, redactions)}` : ""
  throw new TestSendError(`Inline sidecar did not become ready within ${timeoutMs}ms${suffix}`, lastHealth)
}

export function describeHealthFailure(health: unknown): string | null {
  const result = asObject(asObject(health).result)
  const connectError = result.connectError
  if (typeof connectError === "string" && connectError.trim()) return connectError.trim()

  const diagnostics = asObject(result.diagnostics)
  const protocol = asObject(diagnostics.protocol)
  const lastFailureReason = protocol.lastFailureReason
  if (typeof lastFailureReason === "string" && lastFailureReason.trim()) {
    return lastFailureReason.trim()
  }

  return null
}

function postSidecarJson(
  port: number,
  sidecarToken: string,
  requestPath: string,
  body: unknown,
  timeoutMs: number,
): Promise<unknown> {
  return new Promise((resolve, reject) => {
    const payload = JSON.stringify(body ?? {})
    const req = http.request({
      hostname: "127.0.0.1",
      port,
      path: requestPath,
      method: "POST",
      headers: {
        "content-type": "application/json; charset=utf-8",
        "content-length": Buffer.byteLength(payload),
        "x-hermes-sidecar-token": sidecarToken,
      },
    }, (res) => {
      const chunks: Buffer[] = []
      res.on("data", (chunk) => chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk)))
      res.on("end", () => {
        const text = Buffer.concat(chunks).toString("utf8")
        let parsed: unknown
        try {
          parsed = text ? JSON.parse(text) : {}
        } catch {
          reject(new Error(`sidecar ${requestPath} returned invalid JSON: ${text.slice(0, 200)}`))
          return
        }
        if ((res.statusCode ?? 500) >= 400) {
          const record = asObject(parsed)
          const message = typeof record.error === "string" ? record.error : `HTTP ${res.statusCode}`
          reject(new TestSendError(`sidecar ${requestPath} failed: ${message}`, parsed))
          return
        }
        resolve(parsed)
      })
    })
    req.on("error", reject)
    req.setTimeout(Math.min(Math.max(timeoutMs, 1), 10_000), () => {
      req.destroy(new Error(`sidecar ${requestPath} timed out`))
    })
    req.end(payload)
  })
}

async function stopSidecar(child: ChildProcessWithoutNullStreams, port: number, sidecarToken: string) {
  try {
    await postSidecarJson(port, sidecarToken, "/shutdown", {}, 2_000)
  } catch {
    // Stdin EOF is the secondary shutdown signal.
  }
  try {
    child.stdin.end()
  } catch {
    // no-op
  }
  const exited = await waitForExit(child, 2_000)
  if (!exited) child.kill("SIGTERM")
}

function waitForExit(child: ChildProcessWithoutNullStreams, timeoutMs: number): Promise<boolean> {
  if (child.exitCode != null) return Promise.resolve(true)
  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      cleanup()
      resolve(false)
    }, timeoutMs)
    const onExit = () => {
      cleanup()
      resolve(true)
    }
    const cleanup = () => {
      clearTimeout(timer)
      child.off("exit", onExit)
    }
    child.once("exit", onExit)
  })
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

function asObject(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {}
}

function redactValue(value: unknown, redactions: SecretRedaction[]): unknown {
  if (typeof value === "string") return redactText(value, redactions)
  if (Array.isArray(value)) return value.map((item) => redactValue(item, redactions))
  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {}
    for (const [key, item] of Object.entries(value)) {
      out[key] = redactValue(item, redactions)
    }
    return out
  }
  return value
}

class TestSendError extends Error {
  readonly health: unknown

  constructor(message: string, health?: unknown) {
    super(message)
    this.health = health
  }
}

function printInstallResult(result: InstallResult) {
  if (result.dryRun) {
    console.log(`Inline Hermes plugin dry run for ${result.target}`)
  } else if (result.installed) {
    console.log(`Installed Inline Hermes plugin to ${result.target}`)
  } else {
    console.log(`Inline Hermes plugin was not installed`)
  }
  printStatus(result)
  if (result.installed || result.dryRun) {
    console.log("")
    console.log(`Enable the Hermes plugin with \`hermes plugins enable ${pluginEnableKey}\`.`)
    console.log("Then run `hermes gateway setup`, select Inline, and follow the guided bot setup.")
  }
}

function printTestSendResult(result: TestSendResult) {
  console.log(`package: ${result.packageName}@${result.packageVersion}`)
  console.log(`source: ${result.source}${result.sourceValid ? "" : " (missing files)"}`)
  console.log(`sidecar: ${result.sidecar}`)
  console.log(`base url: ${result.baseUrl}`)
  console.log(`state path: ${result.statePath}`)
  console.log(`node: ${formatNodeInfo(result.node)}`)
  console.log(`token: ${result.tokenPresent ? "present" : "missing"}`)
  if (result.target) {
    const target = "chatId" in result.target ? `chat:${result.target.chatId}` : `user:${result.target.userId}`
    console.log(`target: ${target}`)
  }
  if (result.dryRun) {
    console.log("dry run: no sidecar started and no message sent")
  } else if (result.sent) {
    console.log(`sent: yes${result.messageId ? ` (${result.messageId})` : ""}`)
  } else {
    console.log("sent: no")
  }
  if (result.issues.length > 0) {
    console.log("issues:")
    for (const issue of result.issues) console.log(`- ${issue}`)
  }
}

function printStatus(status: Awaited<ReturnType<typeof inspectInstall>>) {
  console.log(`package: ${status.packageName}@${status.packageVersion}`)
  console.log(`hermes home: ${status.hermesHome}`)
  console.log(`source: ${status.source}${status.sourceValid ? "" : " (missing files)"}`)
  console.log(`target: ${status.target}${status.targetLinked ? " (symlink)" : ""}`)
  console.log(`source sidecar: ${formatSidecarInfo(status.sidecar.source)}`)
  console.log(`target sidecar: ${status.sidecar.target ? formatSidecarInfo(status.sidecar.target) : "not installed"}`)
  console.log(`node: ${formatNodeInfo(status.node)}`)
  console.log(`hermes plugin enabled: ${status.activation.pluginEnabled ? "yes" : "no"}`)
  console.log(`inline platform configured: ${status.activation.platformConfigured || status.activation.tokenConfigured ? "yes" : "no"}`)
  if (status.warnings.length > 0) {
    console.log("warnings:")
    for (const warning of status.warnings) console.log(`- ${warning}`)
  }
  if (status.issues.length > 0) {
    console.log("issues:")
    for (const issue of status.issues) console.log(`- ${issue}`)
  }
}

function formatNodeInfo(node: NodeInfo): string {
  const detail = node.version || node.error
  return `${node.path} (${node.source}${detail ? `, ${detail}` : ""})`
}

function formatSidecarInfo(info: SidecarInfo): string {
  if (!info.exists) return `${info.path} (missing)`
  const digest = info.sha256 ? info.sha256.slice(0, 12) : "unknown"
  return `${info.path} (${info.size ?? 0} bytes, sha256 ${digest})`
}

function printHelp() {
  console.log(`inline-hermes

Usage:
  inline-hermes install [--hermes-home <path>] [--link] [--force] [--dry-run]
  inline-hermes status [--hermes-home <path>] [--json]
  inline-hermes doctor [--hermes-home <path>] [--json]
  inline-hermes test-send --to chat:<id>|user:<id> [--text <message>] [--json]
  inline-hermes version

Options:
  --hermes-home <path>  Hermes home directory. Defaults to HERMES_HOME or ~/.hermes.
  --link                Symlink plugin source instead of copying it.
  --force               Replace an existing target plugin directory.
  --dry-run             Print what would happen without writing files.
  --json                Print machine-readable output.
  --to <target>          Inline target for test-send, for example chat:123.
  --text <message>       Message for test-send. Defaults to "Inline Hermes test".
  --base-url <url>       Inline API base URL for test-send.
  --state-path <path>    Inline SDK state file for test-send.
  --timeout-ms <ms>      test-send sidecar readiness timeout. Defaults to 30000.
  -v, --version          Print package version.

After install, enable the external Hermes plugin with:
  hermes plugins enable ${pluginEnableKey}

After upgrading the npm package, refresh the Hermes plugin copy with:
  inline-hermes install --force
`)
}

function isDirectEntrypoint(): boolean {
  const invoked = process.argv[1]
  if (!invoked) return false
  const modulePath = fileURLToPath(import.meta.url)
  if (path.resolve(invoked) === path.resolve(modulePath)) return true
  try {
    return realpathSync(invoked) === realpathSync(modulePath)
  } catch {
    return false
  }
}

if (isDirectEntrypoint()) {
  main().then((code) => {
    process.exitCode = code
  }).catch((error) => {
    console.error(error instanceof Error ? error.message : String(error))
    process.exitCode = 1
  })
}
