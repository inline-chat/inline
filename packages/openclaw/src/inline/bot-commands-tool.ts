import type { AnyAgentTool, OpenClawConfig } from "openclaw/plugin-sdk/core"
import { resolveInlineAccount, resolveInlineToken } from "./accounts.js"
import {
  callInlineBotApi,
  normalizeInlineBotCommandName,
  type InlineBotCommand,
} from "./bot-commands-api.js"
import { sanitizeInlineVisibleText } from "./outbound-sanitize.js"
import { jsonResult } from "../openclaw-compat.js"

type InlineBotCommandsToolArgs = {
  action: "get" | "set" | "delete"
  commands?: InlineBotCommand[]
  accountId?: string
}

const BOT_COMMAND_LIMIT = 100
const BOT_COMMAND_RE = /^[a-z0-9_]+$/

const InlineBotCommandsToolParameters = {
  type: "object",
  additionalProperties: false,
  properties: {
    action: {
      type: "string",
      enum: ["get", "set", "delete"],
      description: "Command operation to run (`get`, `set`, or `delete`).",
    },
    commands: {
      type: "array",
      description: "Required for `set`. Telegram-style command list to register.",
      items: {
        type: "object",
        additionalProperties: false,
        properties: {
          command: {
            type: "string",
            description: "Slash command name without leading slash (`a-z`, `0-9`, `_`, max 32).",
          },
          description: {
            type: "string",
            description: "Human-friendly command description (max 256).",
          },
          sort_order: {
            type: "number",
            description: "Optional command ordering hint.",
          },
        },
        required: ["command", "description"],
      },
    },
    accountId: {
      type: "string",
      description: "Optional Inline account id override.",
    },
  },
  required: ["action"],
} as const

function parseSortOrder(raw: unknown, fallback: number): number {
  if (typeof raw === "number" && Number.isFinite(raw)) {
    return Math.trunc(raw)
  }
  return fallback
}

function normalizeCommands(raw: unknown): InlineBotCommand[] {
  if (!Array.isArray(raw)) {
    throw new Error("inline_bot_commands: `commands` must be an array")
  }
  if (raw.length > BOT_COMMAND_LIMIT) {
    throw new Error(
      `inline_bot_commands: too many commands (${raw.length}); max is ${BOT_COMMAND_LIMIT}`,
    )
  }

  const seen = new Set<string>()
  return raw.map((entry, index) => {
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) {
      throw new Error(`inline_bot_commands: commands[${index}] must be an object`)
    }

    const row = entry as Record<string, unknown>
    const rawCommand = row.command
    const rawDescription = row.description
    const rawSortOrder = row.sort_order ?? row.sortOrder

    if (typeof rawCommand !== "string" || typeof rawDescription !== "string") {
      throw new Error(`inline_bot_commands: commands[${index}] requires string command and description`)
    }

    const command = normalizeInlineBotCommandName(rawCommand)
    const visibleDescription = sanitizeInlineVisibleText(rawDescription)
    if (visibleDescription.shouldSkip) {
      throw new Error(
        `inline_bot_commands: commands[${index}].description contains internal runtime text`,
      )
    }
    const description = visibleDescription.text.trim()

    if (command.length < 1 || command.length > 32 || !BOT_COMMAND_RE.test(command)) {
      throw new Error(
        `inline_bot_commands: commands[${index}].command must match /^[a-z0-9_]+$/ and be <= 32 chars`,
      )
    }
    if (description.length < 1 || description.length > 256) {
      throw new Error(`inline_bot_commands: commands[${index}].description must be 1..256 chars`)
    }
    if (seen.has(command)) {
      throw new Error(`inline_bot_commands: duplicate command "${command}"`)
    }
    seen.add(command)

    const sortOrder = parseSortOrder(rawSortOrder, index)
    return {
      command,
      description,
      ...(sortOrder !== index ? { sort_order: sortOrder } : {}),
    }
  })
}

export function createInlineBotCommandsTool(ctx: {
  config?: OpenClawConfig
  agentAccountId?: string
}): AnyAgentTool | null {
  if (!ctx.config) {
    return null
  }

  return {
    name: "inline_bot_commands",
    label: "Inline Bot Commands",
    description:
      "Manage Inline bot slash commands via Bot API (`getMyCommands`, `setMyCommands`, `deleteMyCommands`).",
    parameters: InlineBotCommandsToolParameters,
    execute: async (_toolCallId, rawArgs) => {
      const args = (rawArgs ?? {}) as InlineBotCommandsToolArgs
      const action = args.action
      if (!action) {
        throw new Error("inline_bot_commands: `action` is required")
      }

      const account = resolveInlineAccount({
        cfg: ctx.config as OpenClawConfig,
        accountId: args.accountId ?? ctx.agentAccountId ?? null,
      })
      if (!account.configured || !account.baseUrl) {
        throw new Error(`Inline not configured for account "${account.accountId}" (missing token or baseUrl)`)
      }
      const token = await resolveInlineToken(account)

      if (action === "get") {
        const result = await callInlineBotApi<{ commands?: InlineBotCommand[] }>({
          baseUrl: account.baseUrl,
          token,
          methodName: "getMyCommands",
          method: "GET",
        })
        const commands = Array.isArray(result.commands) ? result.commands : []
        return jsonResult({
          ok: true,
          action,
          accountId: account.accountId,
          count: commands.length,
          commands,
        })
      }

      if (action === "set") {
        const commands = normalizeCommands(args.commands)
        await callInlineBotApi<Record<string, never>>({
          baseUrl: account.baseUrl,
          token,
          methodName: "setMyCommands",
          method: "POST",
          body: { commands },
        })
        return jsonResult({
          ok: true,
          action,
          accountId: account.accountId,
          count: commands.length,
          commands,
        })
      }

      await callInlineBotApi<Record<string, never>>({
        baseUrl: account.baseUrl,
        token,
        methodName: "deleteMyCommands",
        method: "POST",
      })
      return jsonResult({
        ok: true,
        action,
        accountId: account.accountId,
      })
    },
  } as AnyAgentTool
}
