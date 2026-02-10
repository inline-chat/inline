import { InlineSdkClient } from "@inline-chat/sdk"
import {
  GetChatHistoryInput,
  GetChatsInput,
  GetChatInput,
  InputPeer,
  Method,
  SearchMessagesInput,
  type Chat,
  type GetChatHistoryResult,
  type GetChatsResult,
  type Message,
} from "@inline-chat/protocol/core"

export type InlineAllowedContext = {
  allowedSpaceIds: bigint[]
}

export type InlineEligibleChat = {
  chatId: bigint
  title: string
  spaceId: bigint
}

export type InlineSearchHit = {
  chatId: bigint
  chatTitle: string
  spaceId: bigint
  message: Message
}

export type InlineFetchResult = {
  chat: Chat
  message: Message | null
}

export type InlineApi = {
  close(): Promise<void>
  getEligibleChats(): Promise<InlineEligibleChat[]>
  search(query: string, limit: number): Promise<InlineSearchHit[]>
  fetchMessage(chatId: bigint, messageId: bigint): Promise<InlineFetchResult>
  sendMessage(params: { chatId: bigint; text: string; sendMode: "normal" | "silent"; parseMarkdown: boolean }): Promise<{ messageId: bigint | null }>
}

export function createInlineApi(params: {
  baseUrl: string
  token: string
  allowed: InlineAllowedContext
}): InlineApi {
  const client = new InlineSdkClient({ baseUrl: params.baseUrl, token: params.token })
  let connected: Promise<void> | null = null

  const ensureConnected = async () => {
    if (!connected) {
      connected = client.connect().catch((e) => {
        connected = null
        throw e
      })
    }
    await connected
  }

  const allowedSpaceSet = () => new Set(params.allowed.allowedSpaceIds.map((id) => id.toString()))

  const ensureChatAllowed = async (chat: Chat) => {
    const spaceId = chat.spaceId
    if (!spaceId) throw new Error("chat is not in a space")
    if (!allowedSpaceSet().has(spaceId.toString())) throw new Error("chat is not in an allowed space")
  }

  const getChats = async (): Promise<GetChatsResult> => {
    await ensureConnected()
    const result = await client.invoke(Method.GET_CHATS, { oneofKind: "getChats", getChats: GetChatsInput.create({}) })
    return result.getChats
  }

  const getChatById = async (chatId: bigint): Promise<Chat> => {
    await ensureConnected()
    const peerId = InputPeer.create({ type: { oneofKind: "chat", chat: { chatId } } })
    const result = await client.invoke(Method.GET_CHAT, { oneofKind: "getChat", getChat: GetChatInput.create({ peerId }) })
    const chat = result.getChat.chat
    if (!chat) throw new Error("missing chat")
    return chat
  }

  const getEligibleChats = async (): Promise<InlineEligibleChat[]> => {
    const allowed = allowedSpaceSet()
    const payload = await getChats()

    // Only chats explicitly in allowed spaces.
    const eligible: InlineEligibleChat[] = []
    for (const chat of payload.chats) {
      const spaceId = chat.spaceId
      if (!spaceId) continue
      if (!allowed.has(spaceId.toString())) continue
      eligible.push({ chatId: chat.id, title: chat.title, spaceId })
    }

    // Prefer chats with a last message (best-effort ordering).
    eligible.sort((a, b) => (a.chatId === b.chatId ? 0 : Number(b.chatId - a.chatId)))
    return eligible
  }

  return {
    async close() {
      await client.close()
    },

    async getEligibleChats() {
      return await getEligibleChats()
    },

    async search(query, limit) {
      if (!query.trim()) return []
      const eligibleChats = await getEligibleChats()

      const out: InlineSearchHit[] = []
      const maxChatsToScan = 50

      for (const chat of eligibleChats.slice(0, maxChatsToScan)) {
        if (out.length >= limit) break

        await ensureConnected()
        const peerId = InputPeer.create({ type: { oneofKind: "chat", chat: { chatId: chat.chatId } } })
        const result = await client.invoke(Method.SEARCH_MESSAGES, {
          oneofKind: "searchMessages",
          searchMessages: SearchMessagesInput.create({
            peerId,
            queries: [query],
            limit: Math.max(1, Math.min(10, limit - out.length)),
          }),
        })

        for (const message of result.searchMessages.messages) {
          out.push({ chatId: chat.chatId, chatTitle: chat.title, spaceId: chat.spaceId, message })
          if (out.length >= limit) break
        }
      }

      return out
    },

    async fetchMessage(chatId, messageId) {
      const chat = await getChatById(chatId)
      await ensureChatAllowed(chat)

      await ensureConnected()
      const peerId = InputPeer.create({ type: { oneofKind: "chat", chat: { chatId } } })
      const result = await client.invoke(Method.GET_CHAT_HISTORY, {
        oneofKind: "getChatHistory",
        getChatHistory: GetChatHistoryInput.create({
          peerId,
          // Server semantics: message_id < offset_id (descending). Fetch a single message.
          offsetId: messageId + 1n,
          limit: 1,
        }),
      })

      const first = (result.getChatHistory as GetChatHistoryResult).messages[0] ?? null
      const message = first && first.id === messageId ? first : null
      return { chat, message }
    },

    async sendMessage({ chatId, text, sendMode, parseMarkdown }) {
      const chat = await getChatById(chatId)
      await ensureChatAllowed(chat)

      await ensureConnected()
      const res = await client.sendMessage({
        chatId,
        text,
        sendMode: sendMode === "silent" ? "silent" : undefined,
        parseMarkdown,
      })
      return { messageId: res.messageId }
    },
  }
}
