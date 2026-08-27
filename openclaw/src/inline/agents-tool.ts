import type { AnyAgentTool, OpenClawConfig } from "openclaw/plugin-sdk/core"
import { resolveInlineAccount, resolveInlineToken } from "./accounts.js"
import { callInlineBotApi } from "./bot-commands-api.js"
import { jsonResult } from "../openclaw-compat.js"

type Args = {
  action: "create" | "get" | "list" | "update" | "delete"
  agent_id?: number
  name?: string
  handle?: string
  emoji?: string
  description?: string
  skill_key?: string
  instructions?: string
  accountId?: string
}

const parameters = {
  type: "object",
  additionalProperties: false,
  properties: {
    action: { type: "string", enum: ["create", "get", "list", "update", "delete"] },
    agent_id: { type: "number", description: "Globally unique Inline Agent ID for get, update, or delete." },
    name: { type: "string", description: "Required Agent name for create." },
    handle: { type: "string" },
    emoji: { type: "string" },
    description: { type: "string" },
    skill_key: { type: "string", description: "Optional OpenClaw skill key." },
    instructions: { type: "string", description: "Optional specialized instructions." },
    accountId: { type: "string" },
  },
  required: ["action"],
} as const

export function createInlineAgentsTool(ctx: { config?: OpenClawConfig; agentAccountId?: string }): AnyAgentTool | null {
  if (!ctx.config) return null
  return {
    name: "inline_agents",
    label: "Inline Agents",
    description: "Create, inspect, list, update, and delete named Inline Agents backed by this bot.",
    parameters,
    execute: async (_toolCallId, rawArgs) => {
      const args = (rawArgs ?? {}) as Args
      const account = resolveInlineAccount({
        cfg: ctx.config as OpenClawConfig,
        accountId: args.accountId ?? ctx.agentAccountId ?? null,
      })
      if (!account.configured || !account.baseUrl) throw new Error(`Inline not configured for account "${account.accountId}"`)
      const token = await resolveInlineToken(account)

      if (args.action === "create") {
        const name = args.name?.trim()
        if (!name) throw new Error("inline_agents: `name` is required for create")
        const result = await callInlineBotApi<{ agent?: unknown }>({
          baseUrl: account.baseUrl,
          token,
          methodName: "createAgent",
          method: "POST",
          body: {
            name,
            ...(args.handle?.trim() ? { handle: args.handle.trim() } : {}),
            ...(args.emoji?.trim() ? { emoji: args.emoji.trim() } : {}),
            ...(args.description?.trim() ? { description: args.description.trim() } : {}),
            ...(args.skill_key?.trim() ? { skill_key: args.skill_key.trim() } : {}),
            ...(args.instructions?.trim() ? { instructions: args.instructions.trim() } : {}),
          },
        })
        return jsonResult({ ok: true, action: args.action, accountId: account.accountId, agent: result.agent })
      }

      if (args.action === "get") {
        if (!Number.isSafeInteger(args.agent_id) || Number(args.agent_id) <= 0) {
          throw new Error("inline_agents: positive `agent_id` is required for get")
        }
        const result = await callInlineBotApi<{ bot?: unknown; agent?: unknown }>({
          baseUrl: account.baseUrl,
          token,
          methodName: "getAgent",
          method: "GET",
          query: { agent_id: args.agent_id },
        })
        return jsonResult({ ok: true, action: args.action, accountId: account.accountId, ...result })
      }

      if (args.action === "update") {
        if (!Number.isSafeInteger(args.agent_id) || Number(args.agent_id) <= 0) {
          throw new Error("inline_agents: positive `agent_id` is required for update")
        }
        const body: Record<string, unknown> = { agent_id: args.agent_id }
        if (args.name !== undefined) {
          const name = args.name.trim()
          if (!name) throw new Error("inline_agents: `name` cannot be empty")
          body.name = name
        }
        for (const key of ["handle", "emoji", "description", "skill_key", "instructions"] as const) {
          if (args[key] !== undefined) body[key] = args[key]?.trim() ?? ""
        }
        if (Object.keys(body).length === 1) {
          throw new Error("inline_agents: update requires at least one field")
        }
        const result = await callInlineBotApi<{ agent?: unknown }>({
          baseUrl: account.baseUrl,
          token,
          methodName: "updateAgent",
          method: "POST",
          body,
        })
        return jsonResult({ ok: true, action: args.action, accountId: account.accountId, agent: result.agent })
      }

      if (args.action === "delete") {
        if (!Number.isSafeInteger(args.agent_id) || Number(args.agent_id) <= 0) {
          throw new Error("inline_agents: positive `agent_id` is required for delete")
        }
        const result = await callInlineBotApi<{ agent_id?: number }>({
          baseUrl: account.baseUrl,
          token,
          methodName: "deleteAgent",
          method: "POST",
          body: { agent_id: args.agent_id },
        })
        return jsonResult({ ok: true, action: args.action, accountId: account.accountId, ...result })
      }

      const result = await callInlineBotApi<{ agents?: unknown[] }>({
        baseUrl: account.baseUrl,
        token,
        methodName: "getMyAgents",
        method: "GET",
      })
      return jsonResult({ ok: true, action: "list", accountId: account.accountId, agents: result.agents ?? [] })
    },
  } as AnyAgentTool
}
