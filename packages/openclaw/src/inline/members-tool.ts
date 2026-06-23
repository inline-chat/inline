import type { AnyAgentTool, OpenClawConfig } from "openclaw/plugin-sdk/core"
import { InlineSdkClient, Method } from "@inline-chat/realtime-sdk"
import { resolveInlineAccount, resolveInlineToken } from "./accounts.js"
import { getSpaceMembersWithUsers, type InlineSpaceMemberRecord } from "./space-members.js"
import { parseCurrentInlineSession } from "./tool-targets.js"

type InlineMembersToolArgs = {
  spaceId?: string
  space?: string
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
      description: "Inline space id whose members should be listed. Optional inside an Inline space chat/reply thread.",
    },
    space: {
      type: "string",
      description: "Alias for spaceId.",
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
} as const

const GET_CHAT_METHOD =
  typeof (Method as Record<string, unknown>).GET_CHAT === "number" &&
  Number.isInteger((Method as Record<string, unknown>).GET_CHAT) &&
  ((Method as Record<string, unknown>).GET_CHAT as number) > 0
    ? ((Method as Record<string, unknown>).GET_CHAT as Method)
    : (25 as Method)

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

function parseOptionalId(raw: string | undefined, label: string): bigint | undefined {
  if (raw == null || !raw.trim()) return undefined
  return parseRequiredId(raw, label)
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

function buildChatPeer(chatId: bigint) {
  return {
    type: {
      oneofKind: "chat" as const,
      chat: { chatId },
    },
  }
}

async function loadChatSpaceId(params: {
  client: InlineSdkClient
  chatId: bigint
}): Promise<bigint | undefined> {
  const result = await params.client.invokeRaw(GET_CHAT_METHOD, {
    oneofKind: "getChat",
    getChat: {
      peerId: buildChatPeer(params.chatId),
    },
  })
  if (result.oneofKind !== "getChat") {
    throw new Error(`inline_members: expected getChat result, got ${String(result.oneofKind)}`)
  }
  return result.getChat.chat?.spaceId ?? result.getChat.dialog?.spaceId
}

async function resolveMembersSpaceId(params: {
  args: InlineMembersToolArgs
  client: InlineSdkClient
  ctx: {
    messageChannel?: string
    sessionKey?: string
  }
}): Promise<{
  spaceId: bigint
  inferred: boolean
  source: "explicit" | "current-chat" | "parent-chat"
  chatId: string | null
}> {
  const explicitSpaceId = parseOptionalId(
    params.args.spaceId?.trim() ? params.args.spaceId : params.args.space,
    "spaceId",
  )
  if (explicitSpaceId != null) {
    return {
      spaceId: explicitSpaceId,
      inferred: false,
      source: "explicit",
      chatId: null,
    }
  }

  const session = parseCurrentInlineSession(params.ctx)
  const peer = session?.target.peerId.type
  if (peer?.oneofKind !== "chat") {
    throw new Error("inline_members: spaceId is required outside an Inline space chat or reply thread")
  }

  const currentChatId = peer.chat.chatId
  const currentSpaceId = await loadChatSpaceId({
    client: params.client,
    chatId: currentChatId,
  })
  if (currentSpaceId != null) {
    return {
      spaceId: currentSpaceId,
      inferred: true,
      source: "current-chat",
      chatId: String(currentChatId),
    }
  }

  if (session?.parentChatId != null && session.parentChatId !== currentChatId) {
    const parentSpaceId = await loadChatSpaceId({
      client: params.client,
      chatId: session.parentChatId,
    })
    if (parentSpaceId != null) {
      return {
        spaceId: parentSpaceId,
        inferred: true,
        source: "parent-chat",
        chatId: String(session.parentChatId),
      }
    }
  }

  throw new Error("inline_members: current Inline chat is not part of a space; pass spaceId explicitly")
}

export function createInlineMembersTool(ctx: {
  config?: OpenClawConfig
  agentAccountId?: string
  sessionKey?: string
  messageChannel?: string
}): AnyAgentTool | null {
  if (!ctx.config) {
    return null
  }

  return {
    name: "inline_members",
    label: "Inline Members",
    description:
      "List or search Inline space members by space id, or infer the current space when invoked from an Inline space chat/reply thread.",
    parameters: InlineMembersToolParameters,
    execute: async (_toolCallId, rawArgs) => {
      const args = rawArgs as InlineMembersToolArgs
      const userId = args.userId ? parseRequiredId(args.userId, "userId") : undefined
      const limit = resolveLimit(args.limit)

      return await withInlineClient({
        cfg: ctx.config as OpenClawConfig,
        accountId: args.accountId ?? ctx.agentAccountId ?? null,
        fn: async (client, resolvedAccountId) => {
          const resolvedSpace = await resolveMembersSpaceId({
            args,
            client,
            ctx,
          })
          const members = await getSpaceMembersWithUsers({
            client,
            spaceId: resolvedSpace.spaceId,
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
            spaceId: String(resolvedSpace.spaceId),
            inferredSpaceId: resolvedSpace.inferred,
            spaceIdSource: resolvedSpace.source,
            sourceChatId: resolvedSpace.chatId,
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
