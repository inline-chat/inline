/**
 * Temporary compatibility layer for native command arg menus.
 *
 * Why this exists:
 * - The published `openclaw/plugin-sdk` currently does not expose command-registry
 *   helpers (`findCommandByNativeName`, `parseCommandArgs`, `resolveCommandArgMenu`,
 *   `buildCommandTextFromArgs`) that Telegram uses for native command buttons.
 * - Inline needs equivalent behavior for command option pickers.
 *
 * Source inspiration:
 * - openclaw/src/auto-reply/commands-registry.ts
 * - openclaw/src/auto-reply/commands-registry.data.ts
 *
 * Remove this file once upstream exposes the command menu helpers.
 */

export type InlineCompatReplyMarkupButton = {
  text: string
  callback_data: string
}

type CommandArgChoice = string | { value: string; label: string }

type CommandArgDefinition = {
  name: string
  description?: string
  choices?: CommandArgChoice[]
}

type CommandArgValues = Record<string, string | number | boolean>

type CommandArgs = {
  raw?: string
  values?: CommandArgValues
}

type CommandArgsMenuSpec = "auto" | { arg: string; title?: string }

type CommandDefinition = {
  key: string
  nativeName: string
  args?: CommandArgDefinition[]
  argsParsing?: "none" | "positional"
  argsMenu?: CommandArgsMenuSpec
}

type ResolvedCommandArgChoice = { value: string; label: string }

const THINKING_LEVEL_CHOICES = ["off", "minimal", "low", "medium", "high", "xhigh"] as const

const COMPAT_COMMANDS: CommandDefinition[] = [
  {
    key: "tts",
    nativeName: "tts",
    args: [
      {
        name: "action",
        description: "TTS action",
        choices: [
          { value: "on", label: "On" },
          { value: "off", label: "Off" },
          { value: "status", label: "Status" },
          { value: "provider", label: "Provider" },
          { value: "limit", label: "Limit" },
          { value: "summary", label: "Summary" },
          { value: "audio", label: "Audio" },
          { value: "help", label: "Help" },
        ],
      },
      { name: "value", description: "Provider, limit, or text" },
    ],
    argsMenu: {
      arg: "action",
      title: "Choose TTS action:",
    },
  },
  {
    key: "session",
    nativeName: "session",
    args: [
      { name: "action", description: "idle | max-age", choices: ["idle", "max-age"] },
      { name: "value", description: "Duration or off" },
    ],
    argsMenu: "auto",
  },
  {
    key: "subagents",
    nativeName: "subagents",
    args: [
      {
        name: "action",
        description: "list | kill | log | info | send | steer | spawn",
        choices: ["list", "kill", "log", "info", "send", "steer", "spawn"],
      },
      { name: "target", description: "Run id, index, or session key" },
      { name: "value", description: "Additional input" },
    ],
    argsMenu: "auto",
  },
  {
    key: "acp",
    nativeName: "acp",
    args: [
      {
        name: "action",
        description: "Action to run",
        choices: [
          "spawn",
          "cancel",
          "steer",
          "close",
          "sessions",
          "status",
          "set-mode",
          "set",
          "cwd",
          "permissions",
          "timeout",
          "model",
          "reset-options",
          "doctor",
          "install",
          "help",
        ],
      },
      { name: "value", description: "Action arguments" },
    ],
    argsMenu: "auto",
  },
  {
    key: "usage",
    nativeName: "usage",
    args: [{ name: "mode", description: "off, tokens, full, or cost", choices: ["off", "tokens", "full", "cost"] }],
    argsMenu: "auto",
  },
  {
    key: "activation",
    nativeName: "activation",
    args: [{ name: "mode", description: "mention or always", choices: ["mention", "always"] }],
    argsMenu: "auto",
  },
  {
    key: "send",
    nativeName: "send",
    args: [{ name: "mode", description: "on, off, or inherit", choices: ["on", "off", "inherit"] }],
    argsMenu: "auto",
  },
  {
    key: "think",
    nativeName: "think",
    args: [{ name: "level", description: "thinking level", choices: [...THINKING_LEVEL_CHOICES] }],
    argsMenu: "auto",
  },
  {
    key: "verbose",
    nativeName: "verbose",
    args: [{ name: "mode", description: "on or off", choices: ["on", "off"] }],
    argsMenu: "auto",
  },
  {
    key: "fast",
    nativeName: "fast",
    args: [{ name: "mode", description: "status, on, or off", choices: ["status", "on", "off"] }],
    argsMenu: "auto",
  },
  {
    key: "reasoning",
    nativeName: "reasoning",
    args: [{ name: "mode", description: "on, off, or stream", choices: ["on", "off", "stream"] }],
    argsMenu: "auto",
  },
  {
    key: "elevated",
    nativeName: "elevated",
    args: [{ name: "mode", description: "on, off, ask, or full", choices: ["on", "off", "ask", "full"] }],
    argsMenu: "auto",
  },
]

function parsePositionalArgs(definitions: CommandArgDefinition[], raw: string): CommandArgValues {
  const values: CommandArgValues = {}
  const trimmed = raw.trim()
  if (!trimmed) return values

  const tokens = trimmed.split(/\s+/).filter(Boolean)
  let index = 0
  for (const definition of definitions) {
    if (index >= tokens.length) break
    const token = tokens[index]
    if (!token) break
    values[definition.name] = token
    index += 1
  }
  return values
}

function parseCommandArgs(command: CommandDefinition, raw?: string): CommandArgs | undefined {
  const trimmed = raw?.trim()
  if (!trimmed) return undefined
  if (!command.args || command.argsParsing === "none") {
    return { raw: trimmed }
  }
  return {
    raw: trimmed,
    values: parsePositionalArgs(command.args, trimmed),
  }
}

function findCommandByNativeName(name: string): CommandDefinition | undefined {
  const normalized = name.trim().toLowerCase()
  return COMPAT_COMMANDS.find((command) => command.nativeName.toLowerCase() === normalized)
}

function resolveCommandArgChoices(arg: CommandArgDefinition): ResolvedCommandArgChoice[] {
  const raw = arg.choices ?? []
  return raw.map((choice) =>
    typeof choice === "string" ? { value: choice, label: choice } : choice,
  )
}

function resolveCommandArgMenu(params: {
  command: CommandDefinition
  args?: CommandArgs
}): { arg: CommandArgDefinition; choices: ResolvedCommandArgChoice[]; title?: string } | null {
  const { command, args } = params
  if (!command.args || !command.argsMenu) return null
  if (command.argsParsing === "none") return null

  const argName =
    command.argsMenu === "auto"
      ? command.args.find((arg) => resolveCommandArgChoices(arg).length > 0)?.name
      : command.argsMenu.arg
  if (!argName) return null

  if (args?.values && args.values[argName] != null) return null
  if (args?.raw && !args.values) return null

  const arg = command.args.find((entry) => entry.name === argName)
  if (!arg) return null
  const choices = resolveCommandArgChoices(arg)
  if (choices.length === 0) return null

  const title = command.argsMenu !== "auto" ? command.argsMenu.title : undefined
  return {
    arg,
    choices,
    ...(title ? { title } : {}),
  }
}

function buildCommandTextFromArgs(command: CommandDefinition, args?: CommandArgs): string {
  const values = args?.values ?? {}
  const argDefs = command.args ?? []
  const renderedArgs: string[] = []
  for (const argDef of argDefs) {
    const value = values[argDef.name]
    if (value == null) continue
    const normalized = typeof value === "string" ? value.trim() : String(value)
    if (!normalized) continue
    renderedArgs.push(normalized)
  }
  return renderedArgs.length > 0
    ? `/${command.nativeName} ${renderedArgs.join(" ")}`
    : `/${command.nativeName}`
}

export function resolveInlineCompatNativeCommandMenu(commandBody: string): {
  title: string
  buttons: InlineCompatReplyMarkupButton[][]
} | null {
  const normalized = commandBody.trim()
  const match = normalized.match(/^\/([^\s]+)(?:\s+([\s\S]+))?$/)
  if (!match?.[1]) return null

  const command = findCommandByNativeName(match[1])
  if (!command) return null

  const args = parseCommandArgs(command, match[2])
  const menu = resolveCommandArgMenu({
    command,
    ...(args ? { args } : {}),
  })
  if (!menu) return null

  const title = menu.title ?? `Choose ${menu.arg.description || menu.arg.name} for /${command.nativeName}.`
  const rows: InlineCompatReplyMarkupButton[][] = []
  for (let index = 0; index < menu.choices.length; index += 2) {
    const slice = menu.choices.slice(index, index + 2)
    rows.push(
      slice.map((choice) => ({
        text: choice.label,
        callback_data: buildCommandTextFromArgs(command, {
          values: { [menu.arg.name]: choice.value },
        }),
      })),
    )
  }

  return { title, buttons: rows }
}
