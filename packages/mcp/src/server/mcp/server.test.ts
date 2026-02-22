import { afterEach, describe, expect, it, vi } from "vitest"
import type { Transport } from "@modelcontextprotocol/sdk/shared/transport.js"
import type { JSONRPCMessage } from "@modelcontextprotocol/sdk/types.js"
import type { AuthInfo } from "@modelcontextprotocol/sdk/server/auth/types.js"
import { createInlineMcpServer } from "./server"
import type { McpGrant } from "./grant"
import type {
  InlineApi,
  InlineConversationResolution,
  InlineRecentMessagesResult,
  InlineSearchMessagesResult,
  InlineUnreadMessagesResult,
  InlineUploadFileResult,
} from "../inline/inline-api"

type Sent = { message: JSONRPCMessage }

function createFakeTransport(): { transport: Transport; sent: Sent[] } {
  const sent: Sent[] = []

  const transport: Transport = {
    async start() {},
    async close() {},
    async send(message) {
      sent.push({ message })
    },
  }

  return { transport, sent }
}

async function sendRequest(transport: Transport, message: JSONRPCMessage, extra?: { authInfo?: AuthInfo }) {
  // The server installs transport.onmessage during connect().
  transport.onmessage?.(message as any, extra as any)
}

async function waitForResponse(sent: Sent[], id: number, timeoutMs = 500): Promise<any> {
  const start = Date.now()
  while (Date.now() - start < timeoutMs) {
    const found = [...sent].reverse().find((s) => (s.message as any).id === id)
    if (found) return found.message as any
    await new Promise((r) => setTimeout(r, 1))
  }
  throw new Error("missing response")
}

function lastMessagesSendAuditRecord(infoSpy: ReturnType<typeof vi.spyOn>) {
  const serialized = infoSpy.mock.calls
    .map((call: unknown[]) => call[0])
    .filter((entry: unknown): entry is string => typeof entry === "string")
    .map((line: string) => {
      try {
        return JSON.parse(line) as unknown
      } catch {
        return null
      }
    })
    .reverse()
    .find((entry: unknown) => {
      if (!entry || typeof entry !== "object") return false
      const record = entry as Record<string, unknown>
      return record.event === "mcp.audit" && record.tool === "messages.send"
    })

  expect(serialized).toBeTruthy()
  return serialized as Record<string, unknown>
}

const grant: McpGrant = {
  id: "g1",
  clientId: "c1",
  inlineUserId: 1n,
  scope: "messages:read spaces:read messages:write",
  spaceIds: [10n],
  allowDms: false,
  allowHomeThreads: false,
}

function createInlineStub(overrides: Partial<InlineApi>): InlineApi {
  return {
    async close() {},
    async getEligibleChats() {
      return []
    },
    async resolveConversation(): Promise<InlineConversationResolution> {
      return { query: "", selected: null, candidates: [] }
    },
    async recentMessages(): Promise<InlineRecentMessagesResult> {
      return {
        chat: {
          chatId: 7n,
          title: "General",
          chatTitle: "General",
          kind: "space_chat",
          spaceId: 10n,
          spaceName: "Inline",
          peerUserId: null,
          peerDisplayName: null,
          peerUsername: null,
          archived: false,
          pinned: false,
          unreadCount: 0,
          readMaxId: null,
          lastMessageId: null,
          lastMessageDate: null,
        },
        direction: "all",
        scannedCount: 0,
        nextOffsetId: null,
        messages: [],
      }
    },
    async searchMessages(): Promise<InlineSearchMessagesResult> {
      return {
        chat: {
          chatId: 7n,
          title: "General",
          chatTitle: "General",
          kind: "space_chat",
          spaceId: 10n,
          spaceName: "Inline",
          peerUserId: null,
          peerDisplayName: null,
          peerUsername: null,
          archived: false,
          pinned: false,
          unreadCount: 0,
          readMaxId: null,
          lastMessageId: null,
          lastMessageDate: null,
        },
        query: null,
        content: "all",
        mode: "scan",
        messages: [],
      }
    },
    async unreadMessages(): Promise<InlineUnreadMessagesResult> {
      return {
        scannedChats: 0,
        items: [],
      }
    },
    async createChat() {
      return {
        chatId: 9n,
        title: "Created",
        chatTitle: "Created",
        kind: "space_chat",
        spaceId: 10n,
        spaceName: "Inline",
        peerUserId: null,
        peerDisplayName: null,
        peerUsername: null,
        archived: false,
        pinned: false,
        unreadCount: 0,
        readMaxId: null,
        lastMessageId: null,
        lastMessageDate: null,
      }
    },
    async uploadFile(): Promise<InlineUploadFileResult> {
      return {
        fileUniqueId: "file_1",
        media: { kind: "document", id: 99n },
      }
    },
    async sendMessage() {
      return { messageId: null, spaceId: null }
    },
    async sendMediaMessage() {
      return { messageId: null, spaceId: null }
    },
    ...overrides,
  }
}

describe("mcp tool server", () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("conversations.list returns ranked candidates and best match for query", async () => {
    const inline = createInlineStub({
      async resolveConversation(query) {
        expect(query).toBe("dena")
        return {
          query: "dena",
          selected: {
            chatId: 7n,
            title: "Dena",
            chatTitle: "Dena",
            kind: "dm",
            spaceId: null,
            spaceName: null,
            peerUserId: 2n,
            peerDisplayName: "Dena",
            peerUsername: "dena",
            archived: false,
            pinned: true,
            unreadCount: 1,
            readMaxId: 80n,
            lastMessageId: 88n,
            lastMessageDate: 1000n,
            score: 410,
            matchReasons: ["peer_name_exact", "dm_preference"],
          },
          candidates: [
            {
              chatId: 7n,
              title: "Dena",
              chatTitle: "Dena",
              kind: "dm",
              spaceId: null,
              spaceName: null,
              peerUserId: 2n,
              peerDisplayName: "Dena",
              peerUsername: "dena",
              archived: false,
              pinned: true,
              unreadCount: 1,
              readMaxId: 80n,
              lastMessageId: 88n,
              lastMessageDate: 1000n,
              score: 410,
              matchReasons: ["peer_name_exact", "dm_preference"],
            },
            {
              chatId: 12n,
              title: "Dena Design Notes",
              chatTitle: "Dena Design Notes",
              kind: "space_chat",
              spaceId: 10n,
              spaceName: "Inline",
              peerUserId: null,
              peerDisplayName: null,
              peerUsername: null,
              archived: false,
              pinned: false,
              unreadCount: 0,
              readMaxId: null,
              lastMessageId: 70n,
              lastMessageDate: 900n,
              score: 220,
              matchReasons: ["title_prefix"],
            },
          ],
        }
      },
    })

    const server = createInlineMcpServer({ grant, inline })
    const { transport, sent } = createFakeTransport()
    await server.connect(transport as any)

    const authInfo: AuthInfo = { token: "t", clientId: "c1", scopes: ["messages:read"], expiresAt: Math.floor(Date.now() / 1000) + 3600 }

    await sendRequest(
      transport,
      {
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "0" } },
      } as any,
      { authInfo },
    )

    await sendRequest(
      transport,
      {
        jsonrpc: "2.0",
        method: "notifications/initialized",
        params: {},
      } as any,
      { authInfo },
    )

    await sendRequest(
      transport,
      {
        jsonrpc: "2.0",
        id: 2,
        method: "tools/call",
        params: { name: "conversations.list", arguments: { query: "dena", limit: 5 } },
      } as any,
      { authInfo },
    )

    const res = await waitForResponse(sent, 2)
    expect(res.result.isError).toBeUndefined()
    const text = res.result.content?.[0]?.text
    expect(typeof text).toBe("string")
    const payload = JSON.parse(text)
    expect(payload.query).toBe("dena")
    expect(payload.bestMatch.chatId).toBe("7")
    expect(payload.bestMatch.kind).toBe("dm")
    expect(payload.bestMatch.match.score).toBe(410)
    expect(payload.items).toHaveLength(2)
    expect(payload.items[0].rank).toBe(1)
    expect(payload.items[1].rank).toBe(2)
  })

  it("messages.list returns messages with metadata", async () => {
    const inline = createInlineStub({
      async recentMessages({ chatId, direction, limit, offsetId, since, until, unreadOnly, content }) {
        expect(chatId).toBe(7n)
        expect(direction).toBe("all")
        expect(limit).toBe(5)
        expect(offsetId).toBe(99n)
        expect(typeof since).toBe("bigint")
        expect(typeof until).toBe("bigint")
        expect((since ?? 0n) <= (until ?? 0n)).toBe(true)
        expect(unreadOnly).toBe(true)
        expect(content).toBe("links")
        const resolvedChatId = chatId ?? 7n
        return {
          chat: {
            chatId: resolvedChatId,
            title: "General",
            chatTitle: "General",
            kind: "space_chat",
            spaceId: 10n,
            spaceName: "Inline",
            peerUserId: null,
            peerDisplayName: null,
            peerUsername: null,
            archived: false,
            pinned: false,
            unreadCount: 0,
            readMaxId: 20n,
            lastMessageId: 9n,
            lastMessageDate: 5n,
          },
          direction: "all",
          scannedCount: 3,
          nextOffsetId: 8n,
          messages: [{ id: 9n, fromId: 2n, chatId: resolvedChatId, message: "hello from me", out: true, date: 5n } as any],
        }
      },
    })

    const server = createInlineMcpServer({ grant, inline })
    const { transport, sent } = createFakeTransport()
    await server.connect(transport as any)

    const authInfo: AuthInfo = { token: "t", clientId: "c1", scopes: ["messages:read"], expiresAt: Math.floor(Date.now() / 1000) + 3600 }

    await sendRequest(
      transport,
      {
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "0" } },
      } as any,
      { authInfo },
    )

    await sendRequest(transport, { jsonrpc: "2.0", method: "notifications/initialized", params: {} } as any, { authInfo })

    await sendRequest(
      transport,
      {
        jsonrpc: "2.0",
        id: 2,
        method: "tools/call",
        params: {
          name: "messages.list",
          arguments: { chatId: "7", direction: "all", limit: 5, offsetId: "99", since: "2024-12-31", until: "2024-12-31", unreadOnly: true, content: "links" },
        },
      } as any,
      { authInfo },
    )

    const res = await waitForResponse(sent, 2)
    const payload = JSON.parse(res.result.content?.[0]?.text)
    expect(payload.chat.chatId).toBe("7")
    expect(payload.direction).toBe("all")
    expect(payload.scannedCount).toBe(3)
    expect(payload.nextOffsetId).toBe("8")
    expect(payload.unreadOnly).toBe(true)
    expect(payload.content).toBe("links")
    expect(payload.messages).toHaveLength(1)
    expect(payload.messages[0].id).toBe("9")
    expect(payload.messages[0].text).toBe("hello from me")
    expect(payload.messages[0].metadata.chatId).toBe("7")
  })

  it("messages.search searches messages only in the selected chat", async () => {
    const inline = createInlineStub({
      async searchMessages({ chatId, query, limit, content }) {
        expect(chatId).toBe(7n)
        expect(query).toBe("invoice")
        expect(limit).toBe(3)
        expect(content).toBe("documents")
        const resolvedChatId = chatId ?? 7n
        return {
          chat: {
            chatId: resolvedChatId,
            title: "Dena",
            chatTitle: "Dena",
            kind: "dm",
            spaceId: null,
            spaceName: null,
            peerUserId: 2n,
            peerDisplayName: "Dena",
            peerUsername: "dena",
            archived: false,
            pinned: false,
            unreadCount: 0,
            readMaxId: null,
            lastMessageId: 15n,
            lastMessageDate: 1000n,
          },
          query: query ?? null,
          content: "documents",
          mode: "search",
          messages: [{ id: 14n, fromId: 2n, chatId: resolvedChatId, message: "invoice is sent", out: false, date: 999n } as any],
        }
      },
    })

    const server = createInlineMcpServer({ grant, inline })
    const { transport, sent } = createFakeTransport()
    await server.connect(transport as any)

    const authInfo: AuthInfo = { token: "t", clientId: "c1", scopes: ["messages:read"], expiresAt: Math.floor(Date.now() / 1000) + 3600 }

    await sendRequest(
      transport,
      {
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "0" } },
      } as any,
      { authInfo },
    )

    await sendRequest(transport, { jsonrpc: "2.0", method: "notifications/initialized", params: {} } as any, { authInfo })

    await sendRequest(
      transport,
      {
        jsonrpc: "2.0",
        id: 2,
        method: "tools/call",
        params: { name: "messages.search", arguments: { chatId: "7", query: "invoice", limit: 3, content: "documents" } },
      } as any,
      { authInfo },
    )

    const res = await waitForResponse(sent, 2)
    const payload = JSON.parse(res.result.content?.[0]?.text)
    expect(payload.query).toBe("invoice")
    expect(payload.mode).toBe("search")
    expect(payload.content).toBe("documents")
    expect(payload.chat.chatId).toBe("7")
    expect(payload.messages).toHaveLength(1)
    expect(payload.messages[0].id).toBe("14")
    expect(payload.messages[0].text).toBe("invoice is sent")
  })

  it("messages.list includes media download metadata when present", async () => {
    const inline = createInlineStub({
      async recentMessages({ chatId }) {
        return {
          chat: {
            chatId: chatId ?? 7n,
            title: "Files",
            chatTitle: "Files",
            kind: "space_chat",
            spaceId: 10n,
            spaceName: "Inline",
            peerUserId: null,
            peerDisplayName: null,
            peerUsername: null,
            archived: false,
            pinned: false,
            unreadCount: 0,
            readMaxId: null,
            lastMessageId: 100n,
            lastMessageDate: 1000n,
          },
          direction: "all",
          scannedCount: 1,
          nextOffsetId: null,
          messages: [
            {
              id: 100n,
              fromId: 2n,
              chatId: chatId ?? 7n,
              message: "file",
              out: false,
              date: 1000n,
              media: {
                media: {
                  oneofKind: "document",
                  document: {
                    document: {
                      id: 44n,
                      fileName: "spec.pdf",
                      mimeType: "application/pdf",
                      size: 12345,
                      cdnUrl: "https://cdn.example/spec.pdf",
                      date: 1000n,
                    },
                  },
                },
              },
            } as any,
          ],
        }
      },
    })

    const server = createInlineMcpServer({ grant, inline })
    const { transport, sent } = createFakeTransport()
    await server.connect(transport as any)
    const authInfo: AuthInfo = { token: "t", clientId: "c1", scopes: ["messages:read"], expiresAt: Math.floor(Date.now() / 1000) + 3600 }

    await sendRequest(
      transport,
      {
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "0" } },
      } as any,
      { authInfo },
    )
    await sendRequest(transport, { jsonrpc: "2.0", method: "notifications/initialized", params: {} } as any, { authInfo })
    await sendRequest(
      transport,
      {
        jsonrpc: "2.0",
        id: 2,
        method: "tools/call",
        params: { name: "messages.list", arguments: { chatId: "7", limit: 1 } },
      } as any,
      { authInfo },
    )

    const res = await waitForResponse(sent, 2)
    const payload = JSON.parse(res.result.content?.[0]?.text)
    expect(payload.messages[0].media).toEqual({
      kind: "document",
      id: "44",
      url: "https://cdn.example/spec.pdf",
      fileName: "spec.pdf",
      mimeType: "application/pdf",
      sizeBytes: 12345,
    })
  })

  it("messages.unread returns unread messages across chats", async () => {
    const inline = createInlineStub({
      async unreadMessages({ limit, since, until, content }) {
        expect(limit).toBe(10)
        expect(content).toBe("all")
        expect(typeof since).toBe("bigint")
        expect(typeof until).toBe("bigint")
        expect((since ?? 0n) <= (until ?? 0n)).toBe(true)
        return {
          scannedChats: 2,
          items: [
            {
              chat: {
                chatId: 7n,
                title: "General",
                chatTitle: "General",
                kind: "space_chat",
                spaceId: 10n,
                spaceName: "Inline",
                peerUserId: null,
                peerDisplayName: null,
                peerUsername: null,
                archived: false,
                pinned: false,
                unreadCount: 3,
                readMaxId: 20n,
                lastMessageId: 30n,
                lastMessageDate: 1000n,
              },
              message: { id: 30n, fromId: 2n, chatId: 7n, message: "unread", out: false, date: 1000n } as any,
            },
          ],
        }
      },
    })

    const server = createInlineMcpServer({ grant, inline })
    const { transport, sent } = createFakeTransport()
    await server.connect(transport as any)
    const authInfo: AuthInfo = { token: "t", clientId: "c1", scopes: ["messages:read"], expiresAt: Math.floor(Date.now() / 1000) + 3600 }

    await sendRequest(
      transport,
      {
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "0" } },
      } as any,
      { authInfo },
    )
    await sendRequest(transport, { jsonrpc: "2.0", method: "notifications/initialized", params: {} } as any, { authInfo })
    await sendRequest(
      transport,
      {
        jsonrpc: "2.0",
        id: 2,
        method: "tools/call",
        params: { name: "messages.unread", arguments: { limit: 10, since: "2024-12-31", until: "2024-12-31" } },
      } as any,
      { authInfo },
    )

    const res = await waitForResponse(sent, 2)
    const payload = JSON.parse(res.result.content?.[0]?.text)
    expect(payload.scannedChats).toBe(2)
    expect(payload.items).toHaveLength(1)
    expect(payload.items[0].chat.chatId).toBe("7")
    expect(payload.items[0].message.id).toBe("30")
  })

  it("conversations.create creates a new chat", async () => {
    const inline = createInlineStub({
      async createChat({ title, spaceId, participantUserIds }) {
        expect(title).toBe("Roadmap")
        expect(spaceId).toBe(10n)
        expect(participantUserIds).toEqual([2n, 3n])
        return {
          chatId: 77n,
          title: "Roadmap",
          chatTitle: "Roadmap",
          kind: "space_chat",
          spaceId: 10n,
          spaceName: "Inline",
          peerUserId: null,
          peerDisplayName: null,
          peerUsername: null,
          archived: false,
          pinned: false,
          unreadCount: 0,
          readMaxId: null,
          lastMessageId: null,
          lastMessageDate: null,
        }
      },
    })

    const server = createInlineMcpServer({ grant, inline })
    const { transport, sent } = createFakeTransport()
    await server.connect(transport as any)
    const authInfo: AuthInfo = { token: "t", clientId: "c1", scopes: ["messages:write"], expiresAt: Math.floor(Date.now() / 1000) + 3600 }

    await sendRequest(
      transport,
      {
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "0" } },
      } as any,
      { authInfo },
    )
    await sendRequest(transport, { jsonrpc: "2.0", method: "notifications/initialized", params: {} } as any, { authInfo })
    await sendRequest(
      transport,
      {
        jsonrpc: "2.0",
        id: 2,
        method: "tools/call",
        params: { name: "conversations.create", arguments: { title: "Roadmap", spaceId: "10", participantUserIds: ["2", "3"] } },
      } as any,
      { authInfo },
    )

    const res = await waitForResponse(sent, 2)
    const payload = JSON.parse(res.result.content?.[0]?.text)
    expect(payload.chat.chatId).toBe("77")
    expect(payload.chat.title).toBe("Roadmap")
  })

  it("files.upload uploads base64 media and returns uploaded ids", async () => {
    const inline = createInlineStub({
      async uploadFile({ type, file, fileName, contentType }) {
        expect(type).toBe("photo")
        expect(fileName).toBe("photo.png")
        expect(contentType).toBe("image/png")
        expect(file).toBeInstanceOf(Uint8Array)
        expect((file as Uint8Array).byteLength).toBeGreaterThan(0)
        return {
          fileUniqueId: "INP_1",
          media: { kind: "photo", id: 501n },
        }
      },
    })

    const server = createInlineMcpServer({ grant, inline })
    const { transport, sent } = createFakeTransport()
    await server.connect(transport as any)
    const authInfo: AuthInfo = { token: "t", clientId: "c1", scopes: ["messages:write"], expiresAt: Math.floor(Date.now() / 1000) + 3600 }

    await sendRequest(
      transport,
      {
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "0" } },
      } as any,
      { authInfo },
    )
    await sendRequest(transport, { jsonrpc: "2.0", method: "notifications/initialized", params: {} } as any, { authInfo })

    await sendRequest(
      transport,
      {
        jsonrpc: "2.0",
        id: 2,
        method: "tools/call",
        params: {
          name: "files.upload",
          arguments: {
            kind: "auto",
            base64: "data:image/png;base64,aGVsbG8=",
            fileName: "photo.png",
          },
        },
      } as any,
      { authInfo },
    )

    const res = await waitForResponse(sent, 2)
    const payload = JSON.parse(res.result.content?.[0]?.text)
    expect(payload.ok).toBe(true)
    expect(payload.source).toBe("base64")
    expect(payload.upload.fileUniqueId).toBe("INP_1")
    expect(payload.upload.media.kind).toBe("photo")
    expect(payload.upload.media.id).toBe("501")
    expect(payload.upload.fileName).toBe("photo.png")
    expect(payload.upload.contentType).toBe("image/png")
  })

  it("files.upload rejects non-https urls", async () => {
    const inline = createInlineStub({})
    const server = createInlineMcpServer({ grant, inline })
    const { transport, sent } = createFakeTransport()
    await server.connect(transport as any)
    const authInfo: AuthInfo = { token: "t", clientId: "c1", scopes: ["messages:write"], expiresAt: Math.floor(Date.now() / 1000) + 3600 }

    await sendRequest(
      transport,
      {
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "0" } },
      } as any,
      { authInfo },
    )
    await sendRequest(transport, { jsonrpc: "2.0", method: "notifications/initialized", params: {} } as any, { authInfo })

    await sendRequest(
      transport,
      {
        jsonrpc: "2.0",
        id: 2,
        method: "tools/call",
        params: {
          name: "files.upload",
          arguments: {
            url: "http://example.com/file.png",
          },
        },
      } as any,
      { authInfo },
    )

    const res = await waitForResponse(sent, 2)
    expect(res.result.isError).toBe(true)
    expect(res.result.content?.[0]?.text).toContain("https")
  })

  it("messages.send_media sends uploaded media", async () => {
    const inline = createInlineStub({
      async sendMediaMessage({ userId, media, text, replyToMsgId, sendMode, parseMarkdown }) {
        expect(userId).toBe(2n)
        expect(media).toEqual({ kind: "photo", id: 501n })
        expect(text).toBe("caption")
        expect(replyToMsgId).toBe(9n)
        expect(sendMode).toBe("silent")
        expect(parseMarkdown).toBe(true)
        return { messageId: 300n, spaceId: null }
      },
    })
    const server = createInlineMcpServer({ grant, inline })
    const { transport, sent } = createFakeTransport()
    await server.connect(transport as any)
    const authInfo: AuthInfo = { token: "t", clientId: "c1", scopes: ["messages:write"], expiresAt: Math.floor(Date.now() / 1000) + 3600 }

    await sendRequest(
      transport,
      {
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "0" } },
      } as any,
      { authInfo },
    )
    await sendRequest(transport, { jsonrpc: "2.0", method: "notifications/initialized", params: {} } as any, { authInfo })

    await sendRequest(
      transport,
      {
        jsonrpc: "2.0",
        id: 2,
        method: "tools/call",
        params: {
          name: "messages.send_media",
          arguments: {
            userId: "2",
            mediaKind: "photo",
            mediaId: "501",
            text: "caption",
            replyToMsgId: "9",
            sendMode: "silent",
            parseMarkdown: true,
          },
        },
      } as any,
      { authInfo },
    )

    const res = await waitForResponse(sent, 2)
    const payload = JSON.parse(res.result.content?.[0]?.text)
    expect(payload.ok).toBe(true)
    expect(payload.userId).toBe("2")
    expect(payload.messageId).toBe("300")
    expect(payload.media).toEqual({ kind: "photo", id: "501" })
    expect(payload.metadata).toEqual({ sendMode: "silent", parseMarkdown: true, replyToMsgId: "9" })
  })

  it("messages.send_batch sends mixed text/media items in order", async () => {
    let messageCounter = 900n
    const inline = createInlineStub({
      async sendMessage({ chatId, text, sendMode, parseMarkdown }) {
        expect(chatId).toBe(7n)
        expect(text).toBe("hello")
        expect(sendMode).toBe("normal")
        expect(parseMarkdown).toBe(true)
        messageCounter += 1n
        return { messageId: messageCounter, spaceId: 10n }
      },
      async sendMediaMessage({ chatId, media, text, sendMode, parseMarkdown }) {
        expect(chatId).toBe(7n)
        expect(media).toEqual({ kind: "document", id: 44n })
        expect(text).toBe("spec file")
        expect(sendMode).toBe("silent")
        expect(parseMarkdown).toBe(false)
        messageCounter += 1n
        return { messageId: messageCounter, spaceId: 10n }
      },
    })

    const server = createInlineMcpServer({ grant, inline })
    const { transport, sent } = createFakeTransport()
    await server.connect(transport as any)
    const authInfo: AuthInfo = { token: "t", clientId: "c1", scopes: ["messages:write"], expiresAt: Math.floor(Date.now() / 1000) + 3600 }

    await sendRequest(
      transport,
      {
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "0" } },
      } as any,
      { authInfo },
    )
    await sendRequest(transport, { jsonrpc: "2.0", method: "notifications/initialized", params: {} } as any, { authInfo })
    await sendRequest(
      transport,
      {
        jsonrpc: "2.0",
        id: 2,
        method: "tools/call",
        params: {
          name: "messages.send_batch",
          arguments: {
            chatId: "7",
            items: [
              { type: "text", text: "hello" },
              { type: "media", mediaKind: "document", mediaId: "44", text: "spec file", sendMode: "silent", parseMarkdown: false },
            ],
          },
        },
      } as any,
      { authInfo },
    )

    const res = await waitForResponse(sent, 2)
    const payload = JSON.parse(res.result.content?.[0]?.text)
    expect(payload.ok).toBe(true)
    expect(payload.chatId).toBe("7")
    expect(payload.total).toBe(2)
    expect(payload.sentCount).toBe(2)
    expect(payload.failedCount).toBe(0)
    expect(payload.results).toHaveLength(2)
    expect(payload.results[0].status).toBe("sent")
    expect(payload.results[0].type).toBe("text")
    expect(payload.results[1].status).toBe("sent")
    expect(payload.results[1].type).toBe("media")
    expect(payload.results[1].media).toEqual({ kind: "document", id: "44" })
  })

  it("messages.send requires messages:write", async () => {
    const infoSpy = vi.spyOn(console, "info").mockImplementation(() => {})

    const inline = createInlineStub({
      async sendMessage() {
        return { messageId: 123n }
      },
    })

    const server = createInlineMcpServer({ grant, inline })
    const { transport, sent } = createFakeTransport()
    await server.connect(transport as any)

    const authInfo: AuthInfo = { token: "t", clientId: "c1", scopes: ["messages:read"], expiresAt: Math.floor(Date.now() / 1000) + 3600 }

    await sendRequest(
      transport,
      {
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "0" } },
      } as any,
      { authInfo },
    )

    await sendRequest(
      transport,
      {
        jsonrpc: "2.0",
        method: "notifications/initialized",
        params: {},
      } as any,
      { authInfo },
    )

    await sendRequest(
      transport,
      {
        jsonrpc: "2.0",
        id: 2,
        method: "tools/call",
        params: { name: "messages.send", arguments: { chatId: "7", text: "hi", sendMode: "normal", parseMarkdown: true, replyToMsgId: "9" } },
      } as any,
      { authInfo },
    )

    const res = await waitForResponse(sent, 2)
    expect(res.result.isError).toBe(true)
    expect(res.result.content?.[0]?.text).toContain("messages:write")

    const audit = lastMessagesSendAuditRecord(infoSpy)
    expect(audit.outcome).toBe("failure")
    expect(audit.grantId).toBe("g1")
    expect(audit.inlineUserId).toBe("1")
    expect(audit.chatId).toBe("7")
    expect(audit.spaceId).toBeNull()
    expect(audit.messageId).toBeNull()
    expect(typeof audit.timestamp).toBe("string")
    expect(audit).not.toHaveProperty("text")
    expect(audit).not.toHaveProperty("token")
    expect(JSON.stringify(audit)).not.toContain("hi")
  })

  it("messages.send succeeds with messages:write", async () => {
    const infoSpy = vi.spyOn(console, "info").mockImplementation(() => {})

    const inline = createInlineStub({
      async sendMessage({ userId, replyToMsgId }) {
        expect(userId).toBe(2n)
        expect(replyToMsgId).toBe(10n)
        return { messageId: 123n, spaceId: 10n }
      },
    })

    const server = createInlineMcpServer({ grant, inline })
    const { transport, sent } = createFakeTransport()
    await server.connect(transport as any)

    const authInfo: AuthInfo = { token: "t", clientId: "c1", scopes: ["messages:write"], expiresAt: Math.floor(Date.now() / 1000) + 3600 }

    await sendRequest(
      transport,
      {
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "0" } },
      } as any,
      { authInfo },
    )

    await sendRequest(transport, { jsonrpc: "2.0", method: "notifications/initialized", params: {} } as any, { authInfo })

    await sendRequest(
      transport,
      {
        jsonrpc: "2.0",
        id: 2,
        method: "tools/call",
        params: { name: "messages.send", arguments: { userId: "2", text: "hi", replyToMsgId: "10" } },
      } as any,
      { authInfo },
    )

    const res = await waitForResponse(sent, 2)
    const payload = JSON.parse(res.result.content?.[0]?.text)
    expect(payload.ok).toBe(true)
    expect(payload.messageId).toBe("123")
    expect(payload.userId).toBe("2")
    expect(payload.metadata).toEqual({ sendMode: "normal", parseMarkdown: true, replyToMsgId: "10" })

    const audit = lastMessagesSendAuditRecord(infoSpy)
    expect(audit.outcome).toBe("success")
    expect(audit.grantId).toBe("g1")
    expect(audit.inlineUserId).toBe("1")
    expect(audit.chatId).toBeNull()
    expect(audit.spaceId).toBe("10")
    expect(audit.messageId).toBe("123")
    expect(typeof audit.timestamp).toBe("string")
    expect(audit).not.toHaveProperty("text")
    expect(audit).not.toHaveProperty("token")
    expect(JSON.stringify(audit)).not.toContain("hi")
  })
})
