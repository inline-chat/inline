import * as z from "zod/v4"
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js"
import type { AuthInfo } from "@modelcontextprotocol/sdk/server/auth/types.js"
import type { Grant } from "../store/types"
import type { InlineApi } from "../inline/inline-api"
import { formatInlineMessageId, formatInlineMessageUrl, parseInlineMessageId } from "./ids"

function requireScope(scopes: string[], needed: string): void {
  if (!scopes.includes(needed)) {
    throw new Error(`insufficient scope: requires ${needed}`)
  }
}

function jsonText(obj: unknown): { type: "text"; text: string } {
  return { type: "text", text: JSON.stringify(obj) }
}

function snippetOf(text: string | null | undefined, max = 200): string | undefined {
  if (!text) return undefined
  const cleaned = text.replace(/\s+/g, " ").trim()
  if (!cleaned) return undefined
  return cleaned.length > max ? `${cleaned.slice(0, Math.max(0, max - 3))}...` : cleaned
}

export function createInlineMcpServer(params: {
  grant: Grant
  inline: InlineApi
}): McpServer {
  const server = new McpServer(
    {
      name: "inline",
      version: "0.1.0",
    },
    {
      capabilities: {
        tools: { listChanged: false },
      },
    },
  )

  server.registerTool(
    "search",
    {
      title: "Search Inline",
      description: "Search messages in the spaces you approved.",
      inputSchema: {
        query: z.string().min(1).describe("Search query"),
      },
      annotations: {
        title: "Search",
        readOnlyHint: true,
        openWorldHint: false,
      },
    },
    async ({ query }: { query: string }, extra: { authInfo?: AuthInfo }) => {
      const auth = extra.authInfo
      const scopes = auth?.scopes ?? params.grant.scope.split(/\s+/).filter(Boolean)
      requireScope(scopes, "messages:read")

      const hits = await params.inline.search(query, 20)
      const results = hits.map((hit) => {
        const id = formatInlineMessageId({ chatId: hit.chatId, messageId: hit.message.id })
        return {
          id,
          title: `${hit.chatTitle}`,
          url: formatInlineMessageUrl({ chatId: hit.chatId, messageId: hit.message.id }),
          ...(snippetOf(hit.message.message) ? { snippet: snippetOf(hit.message.message) } : {}),
        }
      })

      return {
        content: [jsonText({ results })],
      }
    },
  )

  server.registerTool(
    "fetch",
    {
      title: "Fetch Inline Message",
      description: "Fetch a message by ID from the spaces you approved.",
      inputSchema: {
        id: z.string().min(1).describe("Message ID returned by search"),
      },
      annotations: {
        title: "Fetch",
        readOnlyHint: true,
        openWorldHint: false,
      },
    },
    async ({ id }: { id: string }, extra: { authInfo?: AuthInfo }) => {
      const auth = extra.authInfo
      const scopes = auth?.scopes ?? params.grant.scope.split(/\s+/).filter(Boolean)
      requireScope(scopes, "messages:read")

      const ref = parseInlineMessageId(id)
      const fetched = await params.inline.fetchMessage(ref.chatId, ref.messageId)

      const text = fetched.message?.message ?? ""
      return {
        content: [
          jsonText({
            id,
            title: fetched.chat.title,
            text,
            url: formatInlineMessageUrl(ref),
            metadata: {
              chatId: ref.chatId.toString(),
              messageId: ref.messageId.toString(),
              spaceId: fetched.chat.spaceId?.toString() ?? null,
              fromId: fetched.message?.fromId?.toString?.() ?? null,
              date: fetched.message?.date?.toString?.() ?? null,
            },
          }),
        ],
      }
    },
  )

  server.registerTool(
    "messages.send",
    {
      title: "Send Inline Message",
      description: "Send a message to a chat in one of the spaces you approved.",
      inputSchema: {
        chatId: z.string().min(1).describe("Inline chat id"),
        text: z.string().min(1).max(8000).describe("Message text"),
        sendMode: z.enum(["normal", "silent"]).default("normal").describe("Whether to notify recipients"),
        parseMarkdown: z.boolean().default(true).describe("Whether to parse markdown formatting"),
      },
      annotations: {
        title: "Send Message",
        readOnlyHint: false,
        openWorldHint: false,
      },
    },
    async (
      { chatId, text, sendMode, parseMarkdown }: { chatId: string; text: string; sendMode: "normal" | "silent"; parseMarkdown: boolean },
      extra: { authInfo?: AuthInfo },
    ) => {
      const auth = extra.authInfo
      const scopes = auth?.scopes ?? params.grant.scope.split(/\s+/).filter(Boolean)
      requireScope(scopes, "messages:write")

      const id = BigInt(chatId)
      const res = await params.inline.sendMessage({ chatId: id, text, sendMode, parseMarkdown })
      return {
        content: [
          jsonText({
            ok: true,
            chatId,
            messageId: res.messageId?.toString() ?? null,
          }),
        ],
      }
    },
  )

  return server
}
