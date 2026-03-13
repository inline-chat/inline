import type { AnyAgentTool, OpenClawConfig } from "openclaw/plugin-sdk"
import { InlineSdkClient } from "@inline-chat/realtime-sdk"
import { resolveInlineAccount, resolveInlineToken } from "./accounts.js"
import { getSpaceMembersWithUsers, type InlineSpaceMemberRecord } from "./space-members.js"

type InlineMembersToolArgs = {
  spaceId: string
  query?: string
  userId?: string
  limit?: number
  accountId?: string
}

type InlineMembersToolResult = {
  content: Array<{ type: "text"; text: string }>
  details: unknown
}

const InlineMembersToolParameters = {
  type: "object",
  additionalProperties: false,
  properties: {
    spaceId: {
      type: "string",
      description: "Inline space id whose members should be listed.",
    },
    query: {
      type: "string",
      description: "Optional case-insensitive filter by member id, name, or username.",
    },
    userId: {
      type: "string",
      description: "Optional exact user id filter.",
    },
    limit: {
      type: "number",
      description: "Maximum members to return (default 100, max 200).",
    },
    accountId: {
      type: "string",
      description: "Optional Inline account id override.",
    },
  },
  required: ["spaceId"],
} as const

function parseRequiredId(raw: string, label: string): bigint {
  const trimmed = raw.trim()
  if (!trimmed) {
    throw new Error(`inline_members: missing ${label}`)
  }
  if (!/^[0-9]+$/.test(trimmed)) {
    throw new Error(`inline_members: invalid ${label} "${raw}"`)
  }
  return BigInt(trimmed)
}

function resolveLimit(raw: number | undefined): number {
  const parsed = typeof raw === "number" && Number.isFinite(raw) ? Math.trunc(raw) : 100
  return Math.max(1, Math.min(200, parsed))
}

function filterSpaceMembers(params: {
  members: InlineSpaceMemberRecord[]
  query: string | undefined
  userId: bigint | undefined
  limit: number
}) {
  const normalizedQuery = params.query?.trim().toLowerCase() ?? ""
  const filtered = params.members.filter((member) => {
    if (params.userId != null && member.userId !== String(params.userId)) {
      return false
    }
    if (!normalizedQuery) {
      return true
    }
    const haystack = [
      member.userId,
      member.user?.id ?? "",
      member.user?.name ?? "",
      member.user?.username ?? "",
    ]
      .join("\n")
      .toLowerCase()
    return haystack.includes(normalizedQuery)
  })

  return filtered.slice(0, params.limit).map((member) => ({
    ...member,
    target: `user:${member.userId}`,
  }))
}

function jsonResult(payload: unknown): InlineMembersToolResult {
  return {
    content: [{ type: "text", text: JSON.stringify(payload, null, 2) }],
    details: payload,
  }
}

async function withInlineClient<T>(params: {
  cfg: OpenClawConfig
  accountId?: string | null
  fn: (client: InlineSdkClient, resolvedAccountId: string) => Promise<T>
}): Promise<T> {
  const account = resolveInlineAccount({ cfg: params.cfg, accountId: params.accountId ?? null })
  if (!account.configured || !account.baseUrl) {
    throw new Error(`Inline not configured for account "${account.accountId}" (missing token or baseUrl)`)
  }
  const token = await resolveInlineToken(account)
  const client = new InlineSdkClient({
    baseUrl: account.baseUrl,
    token,
  })
  await client.connect()
  try {
    return await params.fn(client, account.accountId)
  } finally {
    await client.close().catch(() => {})
  }
}

export function createInlineMembersTool(ctx: {
  config?: OpenClawConfig
  agentAccountId?: string
}): AnyAgentTool | null {
  if (!ctx.config) {
    return null
  }

  return {
    name: "inline_members",
    label: "Inline Members",
    description:
      "List or search Inline space members by space id so the agent can identify who to DM or manage.",
    parameters: InlineMembersToolParameters,
    execute: async (_toolCallId, rawArgs) => {
      const args = rawArgs as InlineMembersToolArgs
      const spaceId = parseRequiredId(args.spaceId, "spaceId")
      const userId = args.userId ? parseRequiredId(args.userId, "userId") : undefined
      const limit = resolveLimit(args.limit)

      return await withInlineClient({
        cfg: ctx.config as OpenClawConfig,
        accountId: args.accountId ?? ctx.agentAccountId ?? null,
        fn: async (client, resolvedAccountId) => {
          const members = await getSpaceMembersWithUsers({
            client,
            spaceId,
          })
          const filteredMembers = filterSpaceMembers({
            members,
            query: args.query,
            userId,
            limit,
          })

          return jsonResult({
            ok: true,
            accountId: resolvedAccountId,
            spaceId: String(spaceId),
            query: args.query ?? null,
            userId: userId != null ? String(userId) : null,
            count: filteredMembers.length,
            members: filteredMembers,
          })
        },
      })
    },
  } as AnyAgentTool
}
