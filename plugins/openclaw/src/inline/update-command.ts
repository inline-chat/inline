import { execFile } from "node:child_process"
import type {
  OpenClawPluginApi,
  OpenClawPluginCommandDefinition,
  PluginCommandContext,
} from "openclaw/plugin-sdk/channel-entry-contract"

const INLINE_PLUGIN_ID = "inline"
const UPDATE_TIMEOUT_MS = 5 * 60_000
const UPDATE_MAX_BUFFER = 256 * 1024
const UPDATE_LOG_MAX_CHARS = 8_000
const UPDATE_LOG_MAX_LINES = 80
const ANSI_ESCAPE_PATTERN = new RegExp(`${String.fromCharCode(27)}\\[[0-?]*[ -/]*[@-~]`, "g")
const SENSITIVE_ENV_NAME_MARKERS = ["TOKEN", "SECRET", "PASSWORD", "API_KEY", "AUTHORIZATION"]

type UpdateProcessResult = {
  exitCode: number | null
  stdout: string
  stderr: string
  errorCode?: string | undefined
  timedOut?: boolean | undefined
}

type UpdateRunner = (params: {
  command: string
  args: string[]
  env: NodeJS.ProcessEnv
  timeoutMs: number
  maxBuffer: number
}) => Promise<UpdateProcessResult>

export const INLINE_UPDATE_COMMAND_SPEC = {
  name: "inline-update",
  nativeNames: { inline: "inline_update" },
  nativeProgressMessages: { inline: "Updating the Inline plugin…" },
  description: "Update the Inline OpenClaw plugin",
  channels: ["inline"],
  acceptsArgs: false,
  requiredScopes: ["operator.admin"],
} satisfies Pick<
  OpenClawPluginCommandDefinition,
  | "name"
  | "nativeNames"
  | "nativeProgressMessages"
  | "description"
  | "channels"
  | "acceptsArgs"
  | "requiredScopes"
>

let updateInFlight = false

export function listInlineUpdateCommandSpecs() {
  return [{
    name: INLINE_UPDATE_COMMAND_SPEC.nativeNames.inline,
    description: INLINE_UPDATE_COMMAND_SPEC.description,
    acceptsArgs: INLINE_UPDATE_COMMAND_SPEC.acceptsArgs,
  }]
}

export function sanitizeInlineUpdateEnvironment(
  source: NodeJS.ProcessEnv = process.env,
): NodeJS.ProcessEnv {
  const env = { ...source }
  for (const key of Object.keys(env)) {
    if (SENSITIVE_ENV_NAME_MARKERS.some((name) => key.toUpperCase().includes(name))) {
      delete env[key]
    }
  }
  return env
}

export function redactInlineUpdateLog(
  raw: unknown,
  sourceEnv: NodeJS.ProcessEnv = process.env,
): string {
  let text = String(raw ?? "")
    .replace(ANSI_ESCAPE_PATTERN, "")
    .replace(/\b(Authorization\s*[:=]\s*)(?:Basic|Bearer)\s+\S+/gi, "$1[REDACTED]")
    .replace(/\b(Bearer\s+)\S+/gi, "$1[REDACTED]")
    .replace(/(https?:\/\/)[^/\s:@]+:[^@\s/]+@/gi, "$1[REDACTED]@")
    .replace(/([?&][^=\s&]+)=([^&\s]+)/g, "$1=[REDACTED]")
    .replace(
      /\b([A-Za-z0-9_-]*(?:token|secret|password|api[_-]?key|authorization)[A-Za-z0-9_-]*)\s*([=:])\s*\S+/gi,
      "$1$2[REDACTED]",
    )

  for (const [key, value] of Object.entries(sourceEnv)) {
    if (
      typeof value === "string"
      && value.length >= 8
      && SENSITIVE_ENV_NAME_MARKERS.some((name) => key.toUpperCase().includes(name))
    ) {
      text = text.replaceAll(value, "[REDACTED]")
    }
  }

  const lines = text
    .split(/\r?\n/)
    .map((line) => line.trimEnd())
    .filter(Boolean)
    .slice(-UPDATE_LOG_MAX_LINES)
  text = lines.join("\n")
  if (text.length > UPDATE_LOG_MAX_CHARS) {
    text = `[earlier output truncated]\n${text.slice(-UPDATE_LOG_MAX_CHARS)}`
  }
  return text || "(no subprocess output)"
}

function resolveOpenClawUpdateInvocation(env: NodeJS.ProcessEnv): {
  command: string
  args: string[]
} {
  const cliPath = env.OPENCLAW_CLI_PATH?.trim()
  const args = ["plugins", "update", INLINE_PLUGIN_ID, "--accept-capabilities"]
  return cliPath
    ? { command: process.execPath, args: [cliPath, ...args] }
    : { command: "openclaw", args }
}

const defaultUpdateRunner: UpdateRunner = async (params) =>
  await new Promise((resolve) => {
    const child = execFile(
      params.command,
      params.args,
      {
        env: params.env,
        timeout: params.timeoutMs,
        maxBuffer: params.maxBuffer,
        windowsHide: true,
      },
      (error, stdout, stderr) => {
        const errorCode = error?.code
        resolve({
          exitCode: error ? (typeof errorCode === "number" ? errorCode : null) : 0,
          stdout: String(stdout ?? ""),
          stderr: String(stderr ?? ""),
          ...(typeof errorCode === "string" ? { errorCode } : {}),
          ...(error?.killed ? { timedOut: true } : {}),
        })
      },
    )
    // A tracked update can request confirmation on integrity drift. Chat commands
    // have no safe interactive input channel, so fail closed instead of hanging.
    child.stdin?.end()
  })

export async function runInlineOpenClawUpdate(params: {
  env?: NodeJS.ProcessEnv
  runner?: UpdateRunner
} = {}): Promise<UpdateProcessResult> {
  const sourceEnv = params.env ?? process.env
  const invocation = resolveOpenClawUpdateInvocation(sourceEnv)
  return await (params.runner ?? defaultUpdateRunner)({
    ...invocation,
    env: sanitizeInlineUpdateEnvironment(sourceEnv),
    timeoutMs: UPDATE_TIMEOUT_MS,
    maxBuffer: UPDATE_MAX_BUFFER,
  })
}

export async function handleInlineUpdateCommand(
  api: OpenClawPluginApi,
  ctx: PluginCommandContext,
  options: { runner?: UpdateRunner } = {},
) {
  if (!ctx.isAuthorizedSender || ctx.senderIsOwner !== true) {
    return { text: "Only an OpenClaw owner can update plugins." }
  }
  if (ctx.args?.trim()) {
    return { text: "Usage: /inline_update" }
  }
  if (updateInFlight) {
    return { text: "An Inline plugin update is already running." }
  }

  updateInFlight = true
  try {
    const result = await runInlineOpenClawUpdate(
      options.runner ? { runner: options.runner } : {},
    )
    if (result.exitCode === 0) {
      api.logger.info?.("[inline-update] OpenClaw plugin updater completed successfully")
      return {
        text: "Inline plugin update completed. Run /restart to load the installed version.",
      }
    }

    const diagnostic = redactInlineUpdateLog(`${result.stdout}\n${result.stderr}`)
    api.logger.error?.(
      `[inline-update] OpenClaw plugin updater failed${result.errorCode ? ` (${result.errorCode})` : ""}\n${diagnostic}`,
    )
    if (result.errorCode === "ENOENT") {
      return { text: "Inline plugin update is unavailable because the OpenClaw CLI was not found." }
    }
    if (result.timedOut) {
      return { text: "Inline plugin update timed out. Details were written to OpenClaw logs under [inline-update]." }
    }
    return { text: "Inline plugin update failed. Details were written to OpenClaw logs under [inline-update]." }
  } catch (error) {
    const diagnostic = redactInlineUpdateLog(error)
    api.logger.error?.(
      `[inline-update] OpenClaw plugin updater crashed before completion\n${diagnostic}`,
    )
    return { text: "Inline plugin update failed. Details were written to OpenClaw logs under [inline-update]." }
  } finally {
    updateInFlight = false
  }
}

export function createInlineUpdateCommand(
  api: OpenClawPluginApi,
): OpenClawPluginCommandDefinition {
  return {
    ...INLINE_UPDATE_COMMAND_SPEC,
    handler: async (ctx) => await handleInlineUpdateCommand(api, ctx),
  }
}
