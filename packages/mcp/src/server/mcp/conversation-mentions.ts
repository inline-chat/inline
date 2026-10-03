import { Buffer } from "node:buffer"
import { McpServer, ResourceTemplate } from "@modelcontextprotocol/sdk/server/mcp.js"
import type { AuthInfo } from "@modelcontextprotocol/sdk/server/auth/types.js"
import { ErrorCode, McpError, type CallToolResult, type ResourceLink } from "@modelcontextprotocol/sdk/types.js"
import * as z from "zod/v4"
import type { Message } from "@inline-chat/protocol/core"
import type { InlineApi, InlineEligibleChat, InlineRecentMessagesResult } from "../inline/inline-api"
import type { McpGrant } from "./grant"

export const CONVERSATION_MENTION_LIMIT = 20
export const CONVERSATION_SNAPSHOT_MAX_BYTES = 32 * 1024
const MAX_METADATA_BYTES = 1024
const MAX_INLINE_ID = 9_223_372_036_854_775_807n

type RecentSnapshotMessage = {
  id: string
  fromId: string | null
  date: string | null
  text: string
  shortened: boolean
  replyToMsgId?: string
  mediaKind?: string
}

export type RecentConversationSnapshot = {
  chat: { chatId: string; title: string; context: string }
  capturedAt: string
  coverage: string
  messages: RecentSnapshotMessage[]
  truncated: boolean
  nextOffsetId: string | null
}

type MentionParams = { grant: McpGrant; inline: InlineApi; resourceMetadataUrl: string }

function authChallenge(resourceMetadataUrl: string, error: "invalid_token" | "insufficient_scope"): string {
  const escapedUrl = resourceMetadataUrl.replace(/\\/g, "\\\\").replace(/"/g, '\\"')
  return `Bearer resource_metadata="${escapedUrl}", error="${error}", scope="messages:read"`
}

function requireReadAccess(params: MentionParams, auth: AuthInfo | undefined): AuthInfo {
  if (!auth || auth.clientId !== params.grant.clientId || (auth.expiresAt != null && auth.expiresAt <= Date.now() / 1000) ||
    (auth.extra?.grantId != null && auth.extra.grantId !== params.grant.id) ||
    (auth.extra?.inlineUserId != null && auth.extra.inlineUserId !== params.grant.inlineUserId.toString())) {
    throw new McpError(ErrorCode.InvalidRequest, "Inline MCP authorization is missing, expired, or belongs to another grant.", {
      "mcp/www_authenticate": [authChallenge(params.resourceMetadataUrl, "invalid_token")],
    })
  }
  if (!auth.scopes.includes("messages:read") || !params.grant.scope.split(/\s+/).includes("messages:read")) {
    throw new McpError(ErrorCode.InvalidRequest, "Authorization scope missing: this operation requires messages:read. Re-authorize Inline MCP with that scope.", {
      "mcp/www_authenticate": [authChallenge(params.resourceMetadataUrl, "insufficient_scope")],
    })
  }
  return auth
}

function isInCurrentContext(chat: InlineEligibleChat, grant: McpGrant, auth: AuthInfo): boolean {
  // HTTP introspection supplies the current context on every request. Intersect
  // it with the session's original grant so a changed grant cannot broaden this API instance.
  if (chat.kind === "dm") return grant.allowDms && auth.extra?.allowDms !== false
  if (chat.kind === "home_thread") return grant.allowHomeThreads && auth.extra?.allowHomeThreads !== false
  if (chat.spaceId == null || !grant.spaceIds.includes(chat.spaceId)) return false
  const currentSpaceIds = auth.extra?.spaceIds
  return !Array.isArray(currentSpaceIds) || currentSpaceIds.includes(chat.spaceId.toString())
}

function encodedStringBytes(value: string): number {
  return Buffer.byteLength(JSON.stringify(value), "utf8")
}

/** Bound JSON-encoded bytes, including escaping, without splitting a surrogate pair. */
function shortenString(value: string, maxBytes: number): { text: string; shortened: boolean } {
  if (encodedStringBytes(value) <= maxBytes) return { text: value, shortened: false }
  let low = 0
  let high = value.length
  while (low < high) {
    const middle = Math.ceil((low + high) / 2)
    if (encodedStringBytes(value.slice(0, middle)) <= maxBytes) low = middle
    else high = middle - 1
  }
  if (low > 0 && low < value.length && /[\uD800-\uDBFF]/.test(value[low - 1]) && /[\uDC00-\uDFFF]/.test(value[low])) low -= 1
  return { text: value.slice(0, low), shortened: true }
}

function conversationContext(chat: InlineEligibleChat): string {
  if (chat.kind === "dm") return "Direct message"
  if (chat.kind === "home_thread") return "Home thread"
  return `${chat.spaceName?.trim() || "Workspace"} (space ${chat.spaceId?.toString() ?? "unknown"})`
}

function resourceLink(chat: InlineEligibleChat): ResourceLink {
  const title = shortenString(chat.title.trim() || `chat ${chat.chatId}`, MAX_METADATA_BYTES).text
  const context = shortenString(conversationContext(chat), MAX_METADATA_BYTES).text
  const name = `${title} · ${context} · chat ${chat.chatId}`
  return {
    type: "resource_link",
    uri: `inline://chat/${chat.chatId}`,
    name,
    title: name,
    description: "Recent text from this conversation, up to 20 messages.",
    mimeType: "application/json",
  }
}

function snapshotMessage(message: Message): RecentSnapshotMessage {
  const mediaKind = message.media?.media.oneofKind
  return {
    id: message.id.toString(),
    fromId: message.fromId?.toString() ?? null,
    date: message.date?.toString() ?? null,
    text: message.message ?? "",
    shortened: false,
    ...(message.replyToMsgId != null ? { replyToMsgId: message.replyToMsgId.toString() } : {}),
    ...(mediaKind ? { mediaKind } : {}),
  }
}

/** Keep newest rows; a budget-induced omission resumes before the oldest retained row. */
export function serializeRecentConversationSnapshot(result: InlineRecentMessagesResult, capturedAt = new Date().toISOString()): string {
  const title = shortenString(result.chat.title.trim() || `chat ${result.chat.chatId}`, MAX_METADATA_BYTES)
  const context = shortenString(conversationContext(result.chat), MAX_METADATA_BYTES)
  const newestFirst = [...result.messages].sort((left, right) => left.id === right.id ? 0 : left.id > right.id ? -1 : 1)
  const retained = newestFirst.slice(0, CONVERSATION_MENTION_LIMIT).map(snapshotMessage)
  let omitted = newestFirst.length > retained.length
  const snapshot: RecentConversationSnapshot = {
    chat: { chatId: result.chat.chatId.toString(), title: title.text, context: context.text },
    capturedAt,
    coverage: "Recent text captured at capturedAt; not complete history or interpreted media. Use messages.list with nextOffsetId for older messages, or messages.get for shortened text. Reads may return a newer snapshot; no automatic refresh.",
    messages: [],
    truncated: omitted || title.shortened || context.shortened,
    nextOffsetId: result.nextOffsetId?.toString() ?? null,
  }
  const serialize = () => {
    snapshot.messages = [...retained].reverse()
    snapshot.nextOffsetId = omitted && retained.length > 0 ? retained[retained.length - 1].id : result.nextOffsetId?.toString() ?? null
    return JSON.stringify(snapshot)
  }
  let text = serialize()
  if (Buffer.byteLength(text, "utf8") <= CONVERSATION_SNAPSHOT_MAX_BYTES) return text

  // Only shorten when the overall budget binds. Half the snapshot budget leaves
  // space for at least one complete row plus the bounded envelope and metadata.
  for (const message of retained) {
    const shortened = shortenString(message.text, CONVERSATION_SNAPSHOT_MAX_BYTES / 2)
    message.text = shortened.text
    message.shortened = shortened.shortened
  }
  snapshot.truncated = true
  text = serialize()
  while (Buffer.byteLength(text, "utf8") > CONVERSATION_SNAPSHOT_MAX_BYTES && retained.length > 1) {
    retained.pop()
    omitted = true
    text = serialize()
  }
  if (Buffer.byteLength(text, "utf8") > CONVERSATION_SNAPSHOT_MAX_BYTES) throw new Error("Conversation snapshot metadata exceeds its byte budget")
  return text
}

export function registerConversationMentions(server: McpServer, params: MentionParams): void {
  // Wire shape from OpenAI MCP Extensions' Composer At-Mentions specification.
  // No extension SDK is needed for this descriptor-only server feature.
  server.registerTool("conversations.mentions", {
    title: "Find Inline Conversation Mentions",
    description: "Search approved conversation titles and contacts for the composer picker. Returns up to 20 recent or ranked resource links without fetching message bodies.",
    inputSchema: { query: z.string().describe("Search text; may be empty for recent approved conversations") },
    outputSchema: {
      items: z.array(z.object({
        type: z.literal("resource_link"), uri: z.string(), name: z.string(), title: z.string(),
        description: z.string(), mimeType: z.literal("application/json"),
      })),
    },
    annotations: { title: "Find Conversation Mentions", readOnlyHint: true, destructiveHint: false, openWorldHint: false },
    _meta: {
      securitySchemes: [{ type: "oauth2", scopes: ["messages:read"] }],
      ui: { visibility: ["app"] },
      "openai/extensions": { "mentions/search": {} },
    },
  }, async ({ query }, extra): Promise<CallToolResult> => {
    try {
      const auth = requireReadAccess(params, extra.authInfo)
      const trimmedQuery = query.trim()
      const candidates = trimmedQuery
        ? (await params.inline.resolveConversation(trimmedQuery, CONVERSATION_MENTION_LIMIT, { sort: "relevance" })).candidates
        : await params.inline.getEligibleChats()
      const items = candidates.filter((chat) => isInCurrentContext(chat, params.grant, auth)).slice(0, CONVERSATION_MENTION_LIMIT).map(resourceLink)
      return { content: [], structuredContent: { items } }
    } catch (error) {
      return {
        isError: true,
        content: [{ type: "text", text: error instanceof Error ? error.message : String(error) }],
        ...(error instanceof McpError && error.data ? { _meta: error.data as Record<string, unknown> } : {}),
      }
    }
  })
}

export function registerConversationSnapshot(server: McpServer, params: MentionParams): void {
  server.registerResource("inline-conversation-recent", new ResourceTemplate("inline://chat/{chatId}", { list: undefined }), {
    title: "Inline Conversation Recent Text",
    description: "Authorized recent-text snapshot: up to 20 messages and 32 KiB, with older-read continuation when available.",
    mimeType: "application/json",
  }, async (uri, _variables, extra) => {
    const auth = requireReadAccess(params, extra.authInfo)
    const match = /^inline:\/\/chat\/([1-9]\d*)$/.exec(uri.href)
    if (!match || BigInt(match[1]) > MAX_INLINE_ID) throw new McpError(ErrorCode.InvalidParams, "Invalid Inline conversation resource URI")
    // Fresh GET_CHAT checks the grant context before GET_CHAT_HISTORY checks
    // actor access. Neither decision comes from discovery's cached metadata.
    // Do not serve content from the picker/catalog or treat a selection as a grant.
    const result = await params.inline.recentMessages({ chatId: BigInt(match[1]), limit: CONVERSATION_MENTION_LIMIT, freshChatAuthorization: true })
    if (!isInCurrentContext(result.chat, params.grant, auth)) throw new McpError(ErrorCode.InvalidRequest, "Conversation is not in the current allowed context")
    return { contents: [{ uri: uri.href, mimeType: "application/json", text: serializeRecentConversationSnapshot(result) }] }
  })
}
